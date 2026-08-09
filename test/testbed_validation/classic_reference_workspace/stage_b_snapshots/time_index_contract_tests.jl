using Test
import NCDatasets
import TOML

include("snapshots.jl")
include("time_index_receipt.jl")
using .StageBSnapshots
using .StageBTimeIndexReceipt

const TIME_HEX_A = repeat("a", 64)
const TIME_HEX_B = repeat("b", 64)

function write_time_snapshot(directory, transition, time_end, tbar, thice)
    fields = [
        snapshot_field(
            "forcing.tbar",
            :forcing,
            :external_forcing,
            "K",
            reshape(Float64.(tbar), 1, :),
        ),
        snapshot_field(
            "forcing.thice",
            :forcing,
            :external_forcing,
            "m3 m-3",
            reshape(Float64.(thice), 1, :),
        ),
        snapshot_field(
            "static.delzw",
            :forcing,
            :parameter,
            "m",
            reshape(Float64[0.1, 0.2], 1, :),
        ),
    ]
    write_snapshot(
        directory,
        fields;
        transition,
        site = "DE-Hai",
        source_sha256 = TIME_HEX_A,
        patch_sha256 = TIME_HEX_B,
    )
    path = joinpath(directory, "manifest.toml")
    manifest = TOML.parsefile(path)
    manifest["snapshot"]["time_end"] = time_end
    open(path, "w") do io
        TOML.print(io, manifest; sorted = true)
    end
end

function write_daily_outputs(directory)
    mkpath(directory)
    temperatures = reshape(Float64[274.0, 275.0, 271.0, 273.0], 1, 1, 2, 2)
    ice_mass = reshape(Float64[0.0, 0.0, 50.0, 25.0], 1, 1, 2, 2)
    for (filename, variable_name, units, values) in (
        ("tsl_daily.nc", "tsl", "K", temperatures),
        ("mrsfl_daily.nc", "mrsfl", "kg m-2", ice_mass),
    )
        NCDatasets.NCDataset(joinpath(directory, filename), "c") do dataset
            NCDatasets.defDim(dataset, "lon", 1)
            NCDatasets.defDim(dataset, "lat", 1)
            NCDatasets.defDim(dataset, "layer", 2)
            NCDatasets.defDim(dataset, "time", 2)
            time = NCDatasets.defVar(dataset, "time", Float64, ("time",))
            time.attrib["units"] = "days since 1999-12-31 00:00"
            time.attrib["calendar"] = "standard"
            time[:] = [1.0, 2.0]
            variable = NCDatasets.defVar(
                dataset,
                variable_name,
                Float64,
                ("lon", "lat", "layer", "time"),
            )
            variable.attrib["units"] = units
            variable[:, :, :, :] = values
        end
    end
end

@testset "time-index receipt binds snapshot dates to daily outputs" begin
    mktempdir() do directory
        ordinary = joinpath(directory, "ordinary")
        frozen = joinpath(directory, "frozen")
        output = joinpath(directory, "output")
        receipt = joinpath(directory, "time-index.toml")
        write_time_snapshot(
            ordinary,
            "ordinary",
            "2000-01-01",
            [274, 275],
            [0, 0],
        )
        write_time_snapshot(
            frozen,
            "frozen_soil",
            "2000-01-02",
            [271, 273],
            [0.5, 0.125],
        )
        write_daily_outputs(output)

        recorded = record_time_index_receipt(receipt, ordinary, frozen, output)
        @test recorded["status"] == "pass"
        @test recorded["ordinary"]["netcdf_index"] == 1
        @test recorded["frozen_soil"]["netcdf_index"] == 2
        @test recorded["ordinary"]["tbar_bit_exact"]
        @test recorded["frozen_soil"]["thice_mass_max_ulp"] == 0
        @test verify_time_index_receipt(receipt, ordinary, frozen, output).ok

        parsed = TOML.parsefile(receipt)
        parsed["calendar"] = "noleap"
        open(receipt, "w") do io
            TOML.print(io, parsed; sorted = true)
        end
        report = verify_time_index_receipt(receipt, ordinary, frozen, output)
        @test !report.ok
        @test "time calendar differs" in report.issues
    end
end

@testset "time-index receipt fails closed on non-exact temperatures" begin
    mktempdir() do directory
        ordinary = joinpath(directory, "ordinary")
        frozen = joinpath(directory, "frozen")
        output = joinpath(directory, "output")
        write_time_snapshot(
            ordinary,
            "ordinary",
            "2000-01-01",
            [274, 275],
            [0, 0],
        )
        write_time_snapshot(
            frozen,
            "frozen_soil",
            "2000-01-02",
            [271, 273.1],
            [0.5, 0.125],
        )
        write_daily_outputs(output)
        @test_throws ErrorException record_time_index_receipt(
            joinpath(directory, "time-index.toml"),
            ordinary,
            frozen,
            output,
        )
    end
end
