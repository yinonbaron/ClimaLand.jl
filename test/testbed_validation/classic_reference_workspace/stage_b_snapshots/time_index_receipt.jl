module StageBTimeIndexReceipt

import NCDatasets
import SHA
import TOML

using ..StageBSnapshots

export record_time_index_receipt, verify_time_index_receipt

const SCHEMA_VERSION = 1
const THICE_MASS_ULP_CEILING = 8
const TSL_FILE = "tsl_daily.nc"
const MRSFL_FILE = "mrsfl_daily.nc"

sha256sum(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

sha256text(value) = bytes2hex(SHA.sha256(codeunits(value)))

function daily_values(variable, index)
    NCDatasets.dimnames(variable) == ("lon", "lat", "layer", "time") ||
        error("unexpected dimensions for $(NCDatasets.name(variable))")
    return Float64.(vec(variable[:, :, :, index]))
end

function unique_temperature_index(variable, expected)
    matches = [
        index for index in axes(variable, 4) if
        isequal(daily_values(variable, index), expected)
    ]
    length(matches) == 1 || error(
        "snapshot tbar does not have exactly one bit-exact daily NetCDF match",
    )
    return only(matches)
end

function ulp_distance(left, right)
    isfinite(left) && isfinite(right) && left >= 0 && right >= 0 ||
        return typemax(UInt64)
    left_bits = reinterpret(UInt64, left)
    right_bits = reinterpret(UInt64, right)
    return left_bits >= right_bits ? left_bits - right_bits :
           right_bits - left_bits
end

function transition_record(snapshot, transition, tsl, mrsfl, time)
    manifest = TOML.parsefile(joinpath(snapshot, "manifest.toml"))
    metadata = manifest["snapshot"]
    metadata["transition"] == transition || error("snapshot transition differs")
    tbar = vec(StageBSnapshots.read_field(snapshot, "forcing.tbar"))
    thice = vec(StageBSnapshots.read_field(snapshot, "forcing.thice"))
    delzw = vec(StageBSnapshots.read_field(snapshot, "static.delzw"))
    length(tbar) == length(thice) == length(delzw) ||
        error("snapshot layer extents differ")
    index = unique_temperature_index(tsl, tbar)
    decoded_time = string(time[index])
    time_end = metadata["time_end"]
    startswith(decoded_time, time_end) ||
        error("snapshot time_end differs from NetCDF time")
    frozen_mass = thice .* delzw .* 1000.0
    netcdf_mass = daily_values(mrsfl, index)
    ulp_errors = ulp_distance.(frozen_mass, netcdf_mass)
    maximum(ulp_errors) <= THICE_MASS_ULP_CEILING ||
        error("snapshot thice differs from the frozen-water mass diagnostic")
    return Dict(
        "transition" => transition,
        "snapshot_manifest_sha256" =>
            sha256sum(joinpath(snapshot, "manifest.toml")),
        "netcdf_index" => index,
        "netcdf_time" => decoded_time,
        "snapshot_time_end" => time_end,
        "tbar_bit_exact" => true,
        "thice_mass_max_abs_error" => maximum(abs.(frozen_mass .- netcdf_mass)),
        "thice_mass_max_ulp" => Int(maximum(ulp_errors)),
    )
end

function evidence_record(ordinary, frozen, output_directory)
    tsl_path = joinpath(output_directory, TSL_FILE)
    mrsfl_path = joinpath(output_directory, MRSFL_FILE)
    isfile(tsl_path) || error("missing $TSL_FILE")
    isfile(mrsfl_path) || error("missing $MRSFL_FILE")
    return NCDatasets.NCDataset(tsl_path) do tsl_dataset
        NCDatasets.NCDataset(mrsfl_path) do mrsfl_dataset
            tsl = tsl_dataset["tsl"]
            mrsfl = mrsfl_dataset["mrsfl"]
            tsl_dataset["time"][:] == mrsfl_dataset["time"][:] ||
                error("daily NetCDF time coordinates differ")
            time = tsl_dataset["time"]
            time_units = String(time.attrib["units"])
            calendar = String(time.attrib["calendar"])
            return Dict(
                "schema_version" => SCHEMA_VERSION,
                "status" => "pass",
                "calendar" => calendar,
                "calendar_sha256" => sha256text(calendar),
                "time_units" => time_units,
                "time_units_sha256" => sha256text(time_units),
                "temperature_file" => TSL_FILE,
                "temperature_file_sha256" => sha256sum(tsl_path),
                "frozen_water_file" => MRSFL_FILE,
                "frozen_water_file_sha256" => sha256sum(mrsfl_path),
                "thice_mass_transform" => "thice * delzw * 1000 kg m-3",
                "thice_mass_ulp_ceiling" => THICE_MASS_ULP_CEILING,
                "ordinary" =>
                    transition_record(ordinary, "ordinary", tsl, mrsfl, time),
                "frozen_soil" =>
                    transition_record(frozen, "frozen_soil", tsl, mrsfl, time),
            )
        end
    end
end

function record_time_index_receipt(
    destination,
    ordinary,
    frozen,
    output_directory,
)
    ispath(destination) && error("time-index receipt already exists")
    record = evidence_record(ordinary, frozen, output_directory)
    open(destination, "w") do io
        TOML.print(io, record; sorted = true)
    end
    return record
end

function verify_time_index_receipt(
    receipt_path,
    ordinary,
    frozen,
    output_directory,
)
    issues = String[]
    recorded = try
        TOML.parsefile(receipt_path)
    catch error
        return (;
            ok = false,
            issues = [
                "invalid time-index receipt: $(sprint(showerror, error))",
            ],
        )
    end
    expected = try
        evidence_record(ordinary, frozen, output_directory)
    catch error
        return (; ok = false, issues = [sprint(showerror, error)])
    end
    labels = Dict(
        "calendar" => "time calendar differs",
        "calendar_sha256" => "time calendar hash differs",
        "time_units" => "time units differ",
        "time_units_sha256" => "time units hash differs",
        "temperature_file_sha256" => "temperature file hash differs",
        "frozen_water_file_sha256" => "frozen-water file hash differs",
    )
    for key in keys(expected)
        if expected[key] isa Dict
            get(recorded, key, nothing) == expected[key] ||
                push!(issues, "$key time-index evidence differs")
        else
            get(recorded, key, nothing) == expected[key] ||
                push!(issues, get(labels, key, "$key differs"))
        end
    end
    return (; ok = isempty(issues), issues)
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 4 || error(
        "usage: time_index_receipt.jl RECEIPT ORDINARY_SNAPSHOT FROZEN_SNAPSHOT OUTPUT_DIRECTORY",
    )
    record_time_index_receipt(ARGS...)
end

end
