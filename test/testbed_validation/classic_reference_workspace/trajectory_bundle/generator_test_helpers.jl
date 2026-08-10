const CAPTURE_HASH = repeat("c", 64)

trajectory_test_sha256_file(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

function write_raw_values(path, values)
    open(path, "w") do io
        for value in values
            if value isa Float64
                write(io, htol(reinterpret(UInt64, value)))
            elseif value isa Int32
                write(io, htol(reinterpret(UInt32, value)))
            else
                error("unsupported synthetic raw value")
            end
        end
    end
end

function snapshot_values(field, dimensions, step)
    shape = Tuple(dimensions[name] for name in field["dimensions"])
    dtype = field["dtype"] == "int32" ? Int32 : Float64
    value = dtype == Int32 ? Int32(1) : 1.0
    if startswith(field["name"], "forcing.") ||
       startswith(field["name"], "audit.")
        value = zero(dtype)
    end
    return fill(value, shape)
end

function write_synthetic_daily_capture(root, snapshot_schema_path; step_count)
    schema = TOML.parsefile(snapshot_schema_path)
    dimensions = schema["dimensions"]
    mkpath(joinpath(root, "daily"))
    index_events = Dict{String, Any}[]
    start = DateTime(2000, 1, 1)
    for index in 1:step_count
        relative = joinpath("daily", "event_$(lpad(index, 8, '0')).raw")
        event_root = joinpath(root, relative)
        mkpath(event_root)
        for field in schema["field"]
            values = snapshot_values(field, dimensions, index)
            write_raw_values(
                joinpath(event_root, field["name"] * ".bin"),
                values,
            )
            open(joinpath(event_root, field["name"] * ".shape"), "w") do io
                print(io, join(size(values), " "))
            end
        end
        stop = start + Day(1)
        push!(
            index_events,
            Dict(
                "index" => index,
                "iday" => index,
                "path" => relative,
                "time_start" =>
                    Dates.format(start, dateformat"yyyy-mm-ddTHH:MM:SS"),
                "time_end" =>
                    Dates.format(stop, dateformat"yyyy-mm-ddTHH:MM:SS"),
                "duration_days" => 1.0,
            ),
        )
        start = stop
    end

    evidence_root = joinpath(root, "evidence")
    mkpath(evidence_root)
    evidence_paths = Dict{String, String}()
    for name in
        ("execution_receipt", "nonperturbation_receipt", "netcdf_time_receipt")
        path = joinpath(evidence_root, name * ".toml")
        open(path, "w") do io
            if name == "execution_receipt"
                TOML.print(
                    io,
                    Dict("schema_version" => 1, "status" => "pass");
                    sorted = true,
                )
            elseif name == "nonperturbation_receipt"
                TOML.print(
                    io,
                    Dict(
                        "schema_version" => 1,
                        "result" => "pass",
                        "criteria" => "exact values, coordinates, masks, dimensions, types, and units",
                        "compared_files" => 57,
                        "failed_files" => 0,
                        "record_count_per_daily_file" => 4749,
                    );
                    sorted = true,
                )
            else
                TOML.print(
                    io,
                    Dict("schema_version" => 1, "status" => "pass");
                    sorted = true,
                )
            end
        end
        evidence_paths[name] = path
    end
    completion_ledger_path = joinpath(root, "daily_completion_ledger.txt")
    open(completion_ledger_path, "w") do io
        println(
            io,
            "schema_version=1 capture_mode=all_daily max_events=$(step_count)",
        )
        for event in index_events
            println(io, event["index"], " ", event["iday"], " ", event["path"])
        end
        println(
            io,
            "capture_complete events=$(step_count) max_events=$(step_count)",
        )
    end
    time_index_path = joinpath(root, "daily_time_index.toml")
    time_index = Dict(
        "schema_version" => 1,
        "site" => "DE-Hai",
        "calendar" => "proleptic_gregorian",
        "source_calendar" => "standard",
        "normalized_calendar" => "proleptic_gregorian",
        "time_standard" => "UTC",
        "source" => "netcdf_daily_time",
        "netcdf_time_receipt_sha256" => trajectory_test_sha256_file(
            evidence_paths["netcdf_time_receipt"],
        ),
        "completion_ledger_sha256" =>
            trajectory_test_sha256_file(completion_ledger_path),
        "event" => index_events,
    )
    open(time_index_path, "w") do io
        TOML.print(io, time_index; sorted = true)
    end
    receipt_path = joinpath(root, "capture_receipt.toml")
    provenance = Dict(
        "source_archive_sha256" => CAPTURE_HASH,
        "source_tree_sha256" => CAPTURE_HASH,
        "source_commit" => repeat("d", 40),
        "executable_sha256" => CAPTURE_HASH,
        "parameter_namelist_sha256" => CAPTURE_HASH,
        "job_options_sha256" => CAPTURE_HASH,
        "initial_condition_sha256" => CAPTURE_HASH,
        "instrumentation_patch_sha256" => CAPTURE_HASH,
        "snapshot_schema_sha256" =>
            trajectory_test_sha256_file(snapshot_schema_path),
        "time_index_sha256" => trajectory_test_sha256_file(time_index_path),
        "completion_ledger_path" => relpath(completion_ledger_path, root),
        "completion_ledger_sha256" =>
            trajectory_test_sha256_file(completion_ledger_path),
        "execution_receipt_path" =>
            relpath(evidence_paths["execution_receipt"], root),
        "execution_receipt_sha256" => trajectory_test_sha256_file(
            evidence_paths["execution_receipt"],
        ),
        "nonperturbation_receipt_path" =>
            relpath(evidence_paths["nonperturbation_receipt"], root),
        "nonperturbation_receipt_sha256" => trajectory_test_sha256_file(
            evidence_paths["nonperturbation_receipt"],
        ),
        "netcdf_time_receipt_path" =>
            relpath(evidence_paths["netcdf_time_receipt"], root),
        "netcdf_time_receipt_sha256" => trajectory_test_sha256_file(
            evidence_paths["netcdf_time_receipt"],
        ),
    )
    receipt = Dict(
        "schema_version" => 1,
        "site" => "DE-Hai",
        "status" => "synthetic",
        "capture_mode" => "all_daily",
        "event_count" => step_count,
        "provenance" => provenance,
    )
    open(receipt_path, "w") do io
        TOML.print(io, receipt; sorted = true)
    end
    return (; root, receipt = receipt_path, time_index = time_index_path)
end
