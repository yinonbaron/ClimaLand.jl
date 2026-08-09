module ClassicTrajectoryGenerator

using Dates
import SHA
import TOML
using ..ClassicTrajectoryBundle

export generate_trajectory_bundle

const SAFE_SITE = r"^[A-Z0-9]{2,3}-[A-Za-z0-9]{2,3}$"

const REQUIRED_CAPTURE_HASHES = (
    "source_archive_sha256",
    "source_tree_sha256",
    "executable_sha256",
    "parameter_namelist_sha256",
    "job_options_sha256",
    "initial_condition_sha256",
    "instrumentation_patch_sha256",
    "snapshot_schema_sha256",
    "time_index_sha256",
    "completion_ledger_sha256",
    "execution_receipt_sha256",
    "nonperturbation_receipt_sha256",
    "netcdf_time_receipt_sha256",
)


file_sha256(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

function load_snapshot_schema(path)
    schema = TOML.parsefile(path)
    get(schema, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported snapshot schema"))
    length(get(schema, "field", Any[])) == 66 ||
        throw(ArgumentError("snapshot schema is not the 66-field v5 contract"))
    return schema
end

function capture_provenance(
    capture_root,
    receipt_path,
    snapshot_schema_path,
    time_index_path,
)
    receipt = TOML.parsefile(receipt_path)
    get(receipt, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported capture receipt"))
    get(receipt, "capture_mode", nothing) == "all_daily" ||
        throw(ArgumentError("capture receipt is not all_daily"))
    provenance = get(receipt, "provenance", Dict())
    all(
        key ->
            ClassicTrajectoryBundle.valid_sha256(get(provenance, key, nothing)),
        REQUIRED_CAPTURE_HASHES,
    ) ||
        throw(ArgumentError("capture receipt has incomplete provenance hashes"))
    ClassicTrajectoryBundle.valid_commit(
        get(provenance, "source_commit", nothing),
    ) || throw(ArgumentError("capture receipt has an invalid source commit"))
    provenance["snapshot_schema_sha256"] == file_sha256(snapshot_schema_path) ||
        throw(ArgumentError("capture receipt snapshot schema hash is stale"))
    provenance["time_index_sha256"] == file_sha256(time_index_path) ||
        throw(ArgumentError("capture receipt time-index hash is stale"))
    for (path_key, hash_key) in (
        ("execution_receipt_path", "execution_receipt_sha256"),
        ("nonperturbation_receipt_path", "nonperturbation_receipt_sha256"),
        ("netcdf_time_receipt_path", "netcdf_time_receipt_sha256"),
    )
        relative = get(provenance, path_key, nothing)
        path = ClassicTrajectoryBundle.safe_payload_path(capture_root, relative)
        isnothing(path) &&
            throw(ArgumentError("capture evidence path escapes capture root"))
        isfile(path) || throw(ArgumentError("capture evidence file is missing"))
        file_sha256(path) == provenance[hash_key] ||
            throw(ArgumentError("capture evidence hash is stale"))
        evidence = TOML.parsefile(path)
        get(evidence, "schema_version", nothing) == 1 ||
            throw(ArgumentError("capture evidence schema is unsupported"))
        if path_key == "execution_receipt_path"
            get(evidence, "status", nothing) == "pass" ||
                throw(ArgumentError("capture execution receipt is not pass"))
        elseif path_key == "nonperturbation_receipt_path"
            exact =
                get(evidence, "result", nothing) == "pass" &&
                get(evidence, "criteria", nothing) ==
                "exact values, coordinates, masks, dimensions, types, and units" &&
                get(evidence, "compared_files", nothing) == 57 &&
                get(evidence, "failed_files", nothing) == 0 &&
                get(evidence, "record_count_per_daily_file", 0) isa Integer &&
                get(evidence, "record_count_per_daily_file", 0) >=
                get(receipt, "event_count", typemax(Int))
            exact || throw(
                ArgumentError(
                    "capture nonperturbation receipt is not an exact pass",
                ),
            )
        else
            get(evidence, "status", nothing) == "pass" ||
                throw(ArgumentError("capture NetCDF time receipt is not pass"))
        end
    end
    ledger_path = ClassicTrajectoryBundle.safe_payload_path(
        capture_root,
        get(provenance, "completion_ledger_path", nothing),
    )
    isnothing(ledger_path) &&
        throw(ArgumentError("completion ledger path escapes capture root"))
    isfile(ledger_path) || throw(ArgumentError("completion ledger is missing"))
    file_sha256(ledger_path) == provenance["completion_ledger_sha256"] ||
        throw(ArgumentError("completion ledger hash is stale"))
    return receipt, provenance
end

function raw_field(event_root, field)
    name = field["name"]
    payload = joinpath(event_root, name * ".bin")
    shape_path = joinpath(event_root, name * ".shape")
    isfile(payload) ||
        throw(ArgumentError("raw event is missing $name payload"))
    isfile(shape_path) ||
        throw(ArgumentError("raw event is missing $name shape"))
    shape = parse.(Int, split(strip(read(shape_path, String))))
    shape == field["shape"] ||
        throw(ArgumentError("raw event $name shape does not match v5 schema"))
    dtype = field["dtype"]
    bytes_per_value = dtype == "int32" ? 4 : dtype == "float64" ? 8 : 0
    bytes_per_value > 0 || throw(ArgumentError("unsupported raw event dtype"))
    filesize(payload) == prod(shape; init = 1) * bytes_per_value ||
        throw(ArgumentError("raw event $name byte count is inconsistent"))
    return (; payload, shape, dtype)
end

function read_raw(field)
    type = field.dtype == "int32" ? Int32 : Float64
    storage = type == Int32 ? UInt32 : UInt64
    count = prod(field.shape; init = 1)
    raw = open(field.payload, "r") do io
        read!(io, Vector{storage}(undef, count))
    end
    values = if type == Int32
        map(value -> reinterpret(Int32, ltoh(value)), raw)
    else
        map(value -> reinterpret(Float64, ltoh(value)), raw)
    end
    return reshape(values, Tuple(field.shape))
end

function validate_event(event_root, snapshot_schema)
    expected =
        Dict(field["name"] => field for field in snapshot_schema["field"])
    payload_names = Set(
        name[1:(end - 4)] for
        name in readdir(event_root) if endswith(name, ".bin")
    )
    payload_names == Set(keys(expected)) || throw(
        ArgumentError("raw event field inventory does not match v5 schema"),
    )
    return Dict(
        name => raw_field(event_root, field) for (name, field) in expected
    )
end

function raw_event_sha256(fields)
    io = IOBuffer()
    for name in sort!(collect(keys(fields)))
        field = fields[name]
        println(
            io,
            name,
            " ",
            file_sha256(field.payload),
            " ",
            join(field.shape, ","),
            " ",
            field.dtype,
        )
    end
    return bytes2hex(SHA.sha256(take!(io)))
end

function validate_time_index(capture_root, path, event_count, site)
    index = TOML.parsefile(path)
    get(index, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported daily time index"))
    get(index, "source", nothing) == "netcdf_daily_time" ||
        throw(ArgumentError("daily time index is not bound to NetCDF time"))
    get(index, "site", nothing) == site || throw(
        ArgumentError("daily time index site differs from capture receipt"),
    )
    get(index, "source_calendar", nothing) == "standard" ||
        throw(ArgumentError("daily time index source calendar is unsupported"))
    get(index, "normalized_calendar", nothing) == "proleptic_gregorian" ||
        throw(
            ArgumentError(
                "daily time index normalized calendar is unsupported",
            ),
        )
    get(index, "calendar", nothing) == index["normalized_calendar"] || throw(
        ArgumentError(
            "daily time index calendar normalization is inconsistent",
        ),
    )
    ClassicTrajectoryBundle.valid_sha256(
        get(index, "netcdf_time_receipt_sha256", nothing),
    ) || throw(ArgumentError("daily time index lacks its NetCDF receipt hash"))
    events = get(index, "event", Any[])
    length(events) == event_count ||
        throw(ArgumentError("capture and time-index event counts differ"))
    previous_end = nothing
    for (position, event) in enumerate(events)
        get(event, "index", nothing) == position ||
            throw(ArgumentError("daily event ordinals are not gap-free"))
        expected_path = joinpath("daily", "event_$(lpad(position, 8, '0')).raw")
        get(event, "path", nothing) == expected_path ||
            throw(ArgumentError("daily event path does not match its ordinal"))
        event_root = ClassicTrajectoryBundle.safe_payload_path(
            capture_root,
            expected_path,
        )
        isnothing(event_root) &&
            throw(ArgumentError("daily event path escapes capture root"))
        isdir(event_root) ||
            throw(ArgumentError("daily event directory is missing"))
        start = DateTime(event["time_start"])
        stop = DateTime(event["time_end"])
        start >= DateTime(1582, 10, 15) ||
            throw(ArgumentError("daily event precedes the Gregorian cutover"))
        stop - start == Day(1) ||
            throw(ArgumentError("daily event duration is not one day"))
        get(event, "duration_days", nothing) == 1.0 ||
            throw(ArgumentError("daily event duration metadata is invalid"))
        !isnothing(previous_end) &&
            start != previous_end &&
            throw(ArgumentError("daily events are not contiguous"))
        previous_end = stop
    end
    return index, events
end

function validate_completion_ledger(
    capture_root,
    provenance,
    time_index,
    events,
)
    path = joinpath(capture_root, provenance["completion_ledger_path"])
    lines = filter(!isempty, strip.(readlines(path)))
    length(lines) == length(events) + 2 ||
        throw(ArgumentError("completion ledger event count differs"))
    header = match(
        r"^schema_version=1 capture_mode=all_daily max_events=(\d+)$",
        first(lines),
    )
    isnothing(header) &&
        throw(ArgumentError("completion ledger header is malformed"))
    parse(Int, only(header.captures)) == length(events) ||
        throw(ArgumentError("completion ledger maximum event count differs"))
    footer =
        match(r"^capture_complete events=(\d+) max_events=(\d+)$", last(lines))
    isnothing(footer) &&
        throw(ArgumentError("completion ledger completion marker is malformed"))
    parse.(Int, footer.captures) == fill(length(events), 2) ||
        throw(ArgumentError("completion ledger completion count differs"))
    rows = lines[2:(end - 1)]
    for (position, (line, event)) in enumerate(zip(rows, events))
        columns = split(line)
        length(columns) == 3 ||
            throw(ArgumentError("completion ledger row is malformed"))
        parse(Int, columns[1]) == position ||
            throw(ArgumentError("completion ledger ordinals are not gap-free"))
        parse(Int, columns[2]) == event["iday"] || throw(
            ArgumentError("completion ledger iday differs from time index"),
        )
        columns[3] == event["path"] || throw(
            ArgumentError("completion ledger path differs from time index"),
        )
    end
    get(time_index, "completion_ledger_sha256", nothing) ==
    provenance["completion_ledger_sha256"] ||
        throw(ArgumentError("time index is not bound to the completion ledger"))
    get(time_index, "netcdf_time_receipt_sha256", nothing) ==
    provenance["netcdf_time_receipt_sha256"] || throw(
        ArgumentError("time index is not bound to the NetCDF time receipt"),
    )
    return nothing
end

function source_name(target)
    startswith(target, "initial.") &&
        return replace(target, "initial." => "pre.")
    startswith(target, "driver.") &&
        return replace(target, "driver." => "forcing.")
    startswith(target, "reference.after_pool_update_") && return replace(
        target,
        "reference.after_pool_update_" => "intermediate.after_pool_update_",
    )
    startswith(target, "reference.before_turbation_") && return replace(
        target,
        "reference.before_turbation_" => "intermediate.before_turbation_",
    )
    startswith(target, "reference.post_") &&
        return replace(target, "reference.post_" => "post.")
    startswith(target, "audit.") && return target
    startswith(target, "static.") && return target
    startswith(target, "parameter.") || return nothing
    suffix = replace(target, "parameter." => "")
    return "static." * (suffix == "deltat_days" ? "deltat" : suffix)
end

function clamp_corrections(fields)
    litter = read_raw(fields["pre.litrmass"])
    soil = read_raw(fields["pre.soilcmas"])
    for process in ("competition", "land_use", "harvest")
        litter .+= read_raw(fields["forcing.pre_resp_$(process)_delta_litter"])
        soil .+= read_raw(fields["forcing.pre_resp_$(process)_delta_soil"])
    end
    deltat = only(read_raw(fields["static.deltat"]))
    conversion = deltat / 963.62
    litter_rate = read_raw(fields["audit.ltresveg"])
    soil_rate = read_raw(fields["audit.scresveg"])
    humification_rate = read_raw(fields["audit.humtrsvg"])
    sort_index = read_raw(fields["static.sort"])
    humicfac = read_raw(fields["static.humicfac"])
    humicfac_bg = only(read_raw(fields["static.humicfac_bg"]))
    spinfast = only(read_raw(fields["static.spinfast"]))
    litter_raw = similar(litter)
    for category in axes(litter, 2), layer in axes(litter, 3)
        humic =
            category < size(litter, 2) ? humicfac[sort_index[category]] :
            humicfac_bg
        litter_raw[1, category, layer] =
            litter[1, category, layer] -
            litter_rate[1, category, layer] * conversion * (1 + humic)
    end
    soil_raw =
        soil .+ spinfast .* conversion .* (humification_rate .- soil_rate)
    return max.(0.0, .-litter_raw), max.(0.0, .-soil_raw)
end

function derived_field(name, fields)
    if name in ("audit.litter_clamp_correction", "audit.soil_clamp_correction")
        litter, soil = clamp_corrections(fields)
        return name == "audit.litter_clamp_correction" ? litter : soil
    end
    if name in (
        "audit.turbation_litter_column_residual",
        "audit.turbation_soil_column_residual",
    )
        pool = occursin("litter", name) ? "litter" : "soil"
        delta = read_raw(fields["audit.turbation_delta_$pool"])
        return dropdims(sum(delta; dims = 3); dims = 3)
    end
    return nothing
end

function write_little_endian(path, values)
    open(path, "w") do io
        for value in values
            if value isa Float64
                write(io, htol(reinterpret(UInt64, value)))
            elseif value isa Int32
                write(io, htol(reinterpret(UInt32, value)))
            else
                throw(ArgumentError("unsupported derived payload type"))
            end
        end
    end
end

function write_record(root, target_field, raw_fields, suffix, dimensions)
    name = target_field["name"]
    source = source_name(name)
    derived =
        isnothing(source) || !haskey(raw_fields, source) ?
        derived_field(name, raw_fields) : nothing
    isnothing(derived) &&
        (isnothing(source) || !haskey(raw_fields, source)) &&
        throw(
            ArgumentError(
                "trajectory field $name has no v5 source or derivation",
            ),
        )
    relative = joinpath("payloads", suffix, replace(name, "." => "_") * ".bin")
    path = joinpath(root, relative)
    mkpath(dirname(path))
    if isnothing(derived)
        cp(raw_fields[source].payload, path)
    else
        write_little_endian(path, derived)
    end
    shape = [dimensions[dimension] for dimension in target_field["dimensions"]]
    return Dict(
        "name" => name,
        "section" => target_field["section"],
        "role" => target_field["role"],
        "units" => target_field["units"],
        "dtype" => target_field["dtype"],
        "dimensions" => target_field["dimensions"],
        "shape" => shape,
        "sampling" => target_field["sampling"],
        "application_phase" => target_field["application_phase"],
        "path" => relative,
        "bytes" => filesize(path),
        "sha256" => file_sha256(path),
    )
end

function generate_trajectory_bundle(
    output_root,
    capture_root,
    trajectory_schema_path,
    snapshot_schema_path,
    time_index_path,
    capture_receipt_path,
)
    ispath(output_root) &&
        throw(ArgumentError("trajectory bundle already exists"))
    trajectory_schema = load_bundle_schema(trajectory_schema_path)
    snapshot_schema = load_snapshot_schema(snapshot_schema_path)
    receipt, capture = capture_provenance(
        capture_root,
        capture_receipt_path,
        snapshot_schema_path,
        time_index_path,
    )
    site = get(receipt, "site", nothing)
    site isa AbstractString && occursin(SAFE_SITE, site) ||
        throw(ArgumentError("capture receipt has an invalid site"))
    event_count = get(receipt, "event_count", nothing)
    event_count isa Integer && event_count > 0 ||
        throw(ArgumentError("capture receipt has invalid event_count"))
    time_index, events =
        validate_time_index(capture_root, time_index_path, event_count, site)
    validate_completion_ledger(capture_root, capture, time_index, events)
    if get(receipt, "status", nothing) == "complete"
        get(time_index, "complete_seasonal_cycle", false) === true || throw(
            ArgumentError("complete evidence lacks a declared seasonal cycle"),
        )
        length(events) >= 365 || throw(
            ArgumentError(
                "complete seasonal evidence has fewer than 365 daily steps",
            ),
        )
    end
    event_fields = Dict{String, Any}[]
    event_hashes = String[]
    previous_post = nothing
    first_static = nothing
    for event in events
        root = joinpath(capture_root, event["path"])
        fields = validate_event(root, snapshot_schema)
        pre =
            (read_raw(fields["pre.litrmass"]), read_raw(fields["pre.soilcmas"]))
        if !isnothing(previous_post) && pre != previous_post
            throw(
                ArgumentError(
                    "owned state is discontinuous between daily events",
                ),
            )
        end
        previous_post = (
            read_raw(fields["post.litrmass"]),
            read_raw(fields["post.soilcmas"]),
        )
        static_names = sort!(
            filter(name -> startswith(name, "static."), collect(keys(fields))),
        )
        static_values = map(name -> read_raw(fields[name]), static_names)
        if isnothing(first_static)
            first_static = static_values
        elseif static_values != first_static
            throw(ArgumentError("static data change within the daily capture"))
        end
        push!(event_fields, fields)
        push!(event_hashes, raw_event_sha256(fields))
    end

    parent = dirname(abspath(output_root))
    mkpath(parent)
    temporary = mktempdir(parent; prefix = ".classic-trajectory-")
    try
        fixed_expected = filter(
            field -> field["section"] in ("static_data", "initial_state"),
            trajectory_schema["field"],
        )
        fixed_records = [
            write_record(
                temporary,
                field,
                first(event_fields),
                "fixed",
                trajectory_schema["dimensions"],
            ) for field in fixed_expected
        ]
        step_expected = filter(
            field -> field["section"] in
            ("drivers", "reference_state", "audit_diagnostics"),
            trajectory_schema["field"],
        )
        steps = Dict{String, Any}[]
        for (position, event) in enumerate(events)
            records = [
                write_record(
                    temporary,
                    field,
                    event_fields[position],
                    "step_$(lpad(position, 8, '0'))",
                    trajectory_schema["dimensions"],
                ) for field in step_expected
            ]
            push!(
                steps,
                Dict(
                    "index" => position,
                    "time_start" => event["time_start"],
                    "time_end" => event["time_end"],
                    "duration_days" => event["duration_days"],
                    "raw_event_sha256" => event_hashes[position],
                    "field" => records,
                ),
            )
        end
        evidence_root = joinpath(temporary, "evidence")
        mkpath(evidence_root)
        sealed_event_index_path =
            joinpath(evidence_root, "sealed_event_index.toml")
        sealed_event_index = Dict(
            "schema_version" => 1,
            "site" => site,
            "event" => [
                Dict(
                    "index" => position,
                    "path" => events[position]["path"],
                    "time_start" => events[position]["time_start"],
                    "time_end" => events[position]["time_end"],
                    "raw_event_sha256" => event_hashes[position],
                ) for position in eachindex(events)
            ],
        )
        open(sealed_event_index_path, "w") do io
            TOML.print(io, sealed_event_index; sorted = true)
        end
        copied = Dict{String, String}()
        for (label, source) in (
            ("capture_receipt", capture_receipt_path),
            ("snapshot_index", time_index_path),
            (
                "completion_ledger",
                joinpath(capture_root, capture["completion_ledger_path"]),
            ),
            (
                "execution_receipt",
                joinpath(capture_root, capture["execution_receipt_path"]),
            ),
            (
                "nonperturbation_receipt",
                joinpath(capture_root, capture["nonperturbation_receipt_path"]),
            ),
            (
                "netcdf_time_receipt",
                joinpath(capture_root, capture["netcdf_time_receipt_path"]),
            ),
        )
            destination = joinpath(evidence_root, label * splitext(source)[2])
            cp(source, destination)
            copied[label] = relpath(destination, temporary)
        end
        status = get(receipt, "status", "incomplete")
        evidence = Dict(
            "status" => status,
            "source" => "issue_101_stage_b_call_snapshots",
            "snapshot_count" => event_count,
            "contiguous" => true,
            "complete_seasonal_cycle" =>
                get(time_index, "complete_seasonal_cycle", false),
            "replay_result" => "not_run",
            "recurrent_state_replacement" => false,
            "nonperturbation_result" =>
                status == "complete" ? "pass" : status,
            "instrumentation_receipt_path" => copied["capture_receipt"],
            "instrumentation_receipt_sha256" =>
                file_sha256(capture_receipt_path),
            "nonperturbation_receipt_path" =>
                copied["nonperturbation_receipt"],
            "nonperturbation_receipt_sha256" => file_sha256(
                joinpath(capture_root, capture["nonperturbation_receipt_path"]),
            ),
            "snapshot_index_path" => copied["snapshot_index"],
            "snapshot_index_sha256" => file_sha256(time_index_path),
            "sealed_event_index_path" =>
                relpath(sealed_event_index_path, temporary),
            "sealed_event_index_sha256" =>
                file_sha256(sealed_event_index_path),
            "completion_ledger_path" => copied["completion_ledger"],
            "completion_ledger_sha256" => file_sha256(
                joinpath(capture_root, capture["completion_ledger_path"]),
            ),
            "execution_receipt_path" => copied["execution_receipt"],
            "execution_receipt_sha256" => file_sha256(
                joinpath(capture_root, capture["execution_receipt_path"]),
            ),
            "netcdf_time_receipt_path" => copied["netcdf_time_receipt"],
            "netcdf_time_receipt_sha256" => file_sha256(
                joinpath(capture_root, capture["netcdf_time_receipt_path"]),
            ),
        )
        provenance = Dict(
            key => capture[key] for key in (
                "source_archive_sha256",
                "source_tree_sha256",
                "source_commit",
                "executable_sha256",
                "parameter_namelist_sha256",
                "job_options_sha256",
                "initial_condition_sha256",
                "instrumentation_patch_sha256",
                "snapshot_schema_sha256",
                "time_index_sha256",
                "completion_ledger_sha256",
            )
        )
        provenance["schema_sha256"] = file_sha256(trajectory_schema_path)
        provenance["capture_receipt_sha256"] = file_sha256(capture_receipt_path)
        manifest = Dict(
            "schema_version" => 1,
            "storage_order" => trajectory_schema["storage_order"],
            "endianness" => trajectory_schema["endianness"],
            "trajectory" => Dict(
                "site" => site,
                "calendar" => time_index["calendar"],
                "time_standard" => time_index["time_standard"],
                "timestamp_format" => "ISO-8601",
                "evidence_status" => status,
            ),
            "provenance" => provenance,
            "dimensions" => trajectory_schema["dimensions"],
            "evidence" => evidence,
            "field" => fixed_records,
            "step" => steps,
        )
        open(joinpath(temporary, "manifest.toml"), "w") do io
            TOML.print(io, manifest; sorted = true)
        end
        mv(temporary, output_root)
    catch
        ispath(temporary) && rm(temporary; recursive = true)
        rethrow()
    end
    return output_root
end

end
