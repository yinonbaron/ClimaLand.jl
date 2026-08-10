module ClassicSiteExecution

using Dates
import NCDatasets
import SHA
import TOML
include("semantic_time.jl")

include(joinpath(@__DIR__, "..", "de_hai", "compare_de_hai_output.jl"))
using .DEHaiOutputComparison: compare_de_hai_directories

export execute_site!, sha256_file

const SHA256_PATTERN = r"^[0-9a-f]{64}$"
const SOURCE_COMMIT_PATTERN = r"^[0-9a-f]{40}$"
const EXACT_COMPARISON_CRITERIA = "exact values, coordinates, masks, dimensions, types, and units"
const EXPECTED_OUTPUT_COUNT = 57
const EXPECTED_SNAPSHOT_FIELD_COUNT = 66
const SEMANTIC_ERROR_PATTERNS = (
    r"NetCDF:",
    r"ERROR STOP"i,
    r"\bfatal\b"i,
    r"segmentation fault"i,
    r"\bsegfault\b"i,
)

sha256_file(path) = bytes2hex(open(SHA.sha256, path))

function required_file(path, label)
    isfile(path) || throw(ArgumentError("missing $label: $path"))
    islink(path) && throw(ArgumentError("$label must not be a symlink: $path"))
    return realpath(path)
end

function valid_sha256(value)
    return value isa AbstractString && occursin(SHA256_PATTERN, value)
end

function validate_config(config)
    for property in (
        :promoted_source_root,
        :oracle_root,
        :parameter_namelist_path,
        :executable_path,
        :container_path,
        :max_events,
        :source_archive_sha256,
        :source_tree_sha256,
        :source_commit,
        :instrumentation_patch_sha256,
        :snapshot_schema_sha256,
    )
        hasproperty(config, property) ||
            throw(ArgumentError("site execution config lacks $property"))
    end
    source_root = realpath(config.promoted_source_root)
    isdir(source_root) ||
        throw(ArgumentError("promoted source root is not a directory"))
    executable =
        required_file(config.executable_path, "instrumented executable")
    (
        executable == source_root ||
        startswith(executable, source_root * Base.Filesystem.path_separator)
    ) || throw(
        ArgumentError("instrumented executable is outside promoted source"),
    )
    required_file(config.container_path, "CLASSIC container")
    required_file(config.parameter_namelist_path, "parameter namelist")
    config.max_events isa Integer && config.max_events > 0 ||
        throw(ArgumentError("max_events must be a positive integer"))
    for property in (
        :source_archive_sha256,
        :source_tree_sha256,
        :instrumentation_patch_sha256,
        :snapshot_schema_sha256,
    )
        valid_sha256(getproperty(config, property)) ||
            throw(ArgumentError("site execution config has invalid $property"))
    end
    config.source_commit isa AbstractString &&
    occursin(SOURCE_COMMIT_PATTERN, config.source_commit) ||
        throw(ArgumentError("site execution config has invalid source_commit"))
    return nothing
end

function validate_oracle(site, config)
    oracle_root = realpath(config.oracle_root)
    site_root = joinpath(oracle_root, site)
    netcdf_root = joinpath(oracle_root, "outputFiles", site, "netCDF")
    receipt_path = required_file(
        joinpath(oracle_root, "site-evidence", site, "receipt.toml"),
        "$site oracle receipt",
    )
    isdir(site_root) ||
        throw(ArgumentError("$site oracle configuration is missing"))
    isdir(netcdf_root) ||
        throw(ArgumentError("$site oracle NetCDF output is missing"))
    receipt = TOML.parsefile(receipt_path)
    gates = (
        get(receipt, "schema_version", nothing) == 1,
        get(receipt, "site", nothing) == site,
        get(receipt, "local_oracle_status", nothing) == "available",
        get(receipt, "run_exit_code", nothing) == 0,
    )
    all(gates) ||
        throw(ArgumentError("$site oracle receipt is not a successful #98 run"))
    hashes = get(receipt, "evidence_sha256", Dict())
    job_options = required_file(
        joinpath(site_root, "job_options_file.txt"),
        "$site oracle job options",
    )
    initialization = required_file(
        joinpath(site_root, "$(site)_init.nc"),
        "$site initialization",
    )
    for path in (job_options, initialization)
        get(hashes, basename(path), nothing) == sha256_file(path) || throw(
            ArgumentError(
                "$site oracle receipt hash differs for $(basename(path))",
            ),
        )
    end
    return (;
        oracle_root,
        site_root,
        netcdf_root,
        receipt_path,
        job_options,
        initialization,
    )
end

function oracle_first_cycle(oracle)
    time_path = required_file(
        joinpath(oracle.netcdf_root, "tsl_daily.nc"),
        "oracle daily time source",
    )
    times, source_calendar, time_units =
        NCDatasets.NCDataset(time_path) do dataset
            time = dataset["time"]
            (
                collect(DateTime.(time[:])),
                String(time.attrib["calendar"]),
                String(time.attrib["units"]),
            )
        end
    source_calendar == "standard" ||
        throw(ArgumentError("oracle daily time calendar is not standard"))
    isempty(times) &&
        throw(ArgumentError("oracle daily time coordinate is empty"))
    capture_year = year(first(times))
    first(times) == DateTime(capture_year, 1, 1) || throw(
        ArgumentError("oracle first daily interval does not start January 1"),
    )
    event_count = daysinyear(capture_year)
    length(times) >= event_count ||
        throw(ArgumentError("oracle daily time lacks a complete first year"))
    captured = times[1:event_count]
    all(
        captured[index] - captured[index - 1] == Day(1) for
        index in 2:event_count
    ) || throw(ArgumentError("oracle first-year daily time is not gap-free"))
    last(captured) + Day(1) == DateTime(capture_year + 1, 1, 1) || throw(
        ArgumentError(
            "oracle first-year daily time does not reach next January 1",
        ),
    )
    first(captured) >= DateTime(1582, 10, 15) || throw(
        ArgumentError(
            "oracle first-year daily time precedes Gregorian cutover",
        ),
    )
    return (;
        time_path,
        time_file_sha256 = sha256_file(time_path),
        time_sha256 = semantic_time_sha256(times, source_calendar, time_units),
        source_calendar,
        capture_year,
        event_count,
        first_time = first(captured),
        last_time = last(captured),
        next_year_start = last(captured) + Day(1),
    )
end

function write_toml(path, table)
    ispath(path) && throw(ArgumentError("refusing to overwrite $path"))
    mkpath(dirname(path))
    open(path, "w") do io
        TOML.print(io, table; sorted = true)
    end
    return path
end

function parse_run_end_year(path)
    text = join(
        (first(split(line, '!'; limit = 2)) for line in eachline(path)),
        "\n",
    )
    matches = collect(eachmatch(r"(?im)\brunEndYear\s*=\s*(\d+)", text))
    length(matches) == 1 ||
        throw(ArgumentError("job options must assign runEndYear exactly once"))
    return parse(Int, only(matches).captures[1])
end

function prepare_workspace(site, workspace, config, oracle)
    ispath(workspace) &&
        throw(ArgumentError("refusing to overwrite workspace: $workspace"))
    run_root = joinpath(abspath(workspace), "run")
    site_root = joinpath(run_root, site)
    netcdf_root = joinpath(run_root, "outputFiles", site, "netCDF")
    evidence_root = joinpath(abspath(workspace), "execution_evidence")
    mkpath.((site_root, netcdf_root, evidence_root))
    job_options_path = joinpath(site_root, "job_options_file.txt")
    initial_condition_path = joinpath(site_root, "$(site)_init.nc")
    cp(oracle.job_options, job_options_path)
    cp(oracle.initialization, initial_condition_path)
    cp(initial_condition_path, joinpath(site_root, "rsfile.nc"))
    cp(config.parameter_namelist_path, joinpath(run_root, "model_params.nml"))
    return (;
        run_root,
        site_root,
        netcdf_root,
        evidence_root,
        job_options_path,
        initial_condition_path,
        raw_root = joinpath(run_root, "stage_b_snapshots"),
    )
end

function command_specification(site, prepared, config)
    environment = [
        "CLASSIC_STAGE_B_CAPTURE_MODE=all_daily",
        "CLASSIC_STAGE_B_CAPTURE_MAX_EVENTS=$(config.max_events)",
        "CLASSIC_STAGE_B_SNAPSHOT_ROOT=/work_zone/run_tmp/stage_b_snapshots",
    ]
    arguments = [
        "apptainer",
        "exec",
        "--no-mount",
        "bind-paths",
        "--bind",
        "$(abspath(config.promoted_source_root)):/work_zone/classic_tmp",
        "--bind",
        "$(prepared.run_root):/work_zone/run_tmp",
        abspath(config.container_path),
        "/work_zone/classic_tmp/bin/CLASSIC_serial",
        "/work_zone/run_tmp/$site/job_options_file.txt",
        "0/0",
    ]
    command = addenv(
        Cmd(arguments),
        Pair.(
            first.(split.(environment, "="; limit = 2)),
            last.(split.(environment, "="; limit = 2)),
        )...,
    )
    return (; command, text = join(vcat(environment, arguments), " "))
end

function runner_exit_code(result)
    hasproperty(result, :exit_code) && return Int(result.exit_code)
    result isa Base.Process && return result.exitcode
    return success(result) ? 0 : 1
end

function semantic_log_issues(path, run_end_year)
    lines = readlines(path)
    issues = String[]
    for line in lines
        for pattern in SEMANTIC_ERROR_PATTERNS
            occursin(pattern, line) &&
                push!(issues, "semantic log error: $(strip(line))")
        end
    end
    nonempty = filter(!isempty, strip.(lines))
    final_pattern = Regex(
        "done:\\s*met year\\s*=\\s*$run_end_year\\s+runyr\\s*=\\s*$run_end_year",
        "i",
    )
    isempty(nonempty) ||
        occursin(final_pattern, last(nonempty)) ||
        push!(
            issues,
            "semantic completion marker is absent for runEndYear=$run_end_year",
        )
    isempty(nonempty) && push!(
        issues,
        "semantic completion marker is absent because the run log is empty",
    )
    return unique(issues)
end

function validate_event_payload(path, index)
    isdir(path) ||
        throw(ArgumentError("snapshot event $index directory is missing"))
    entries = readdir(path)
    all(
        isfile(joinpath(path, name)) && !islink(joinpath(path, name)) for
        name in entries
    ) ||
        throw(ArgumentError("snapshot event $index contains non-file payloads"))
    binaries = sort!(filter(name -> endswith(name, ".bin"), entries))
    shapes = sort!(filter(name -> endswith(name, ".shape"), entries))
    length(binaries) == EXPECTED_SNAPSHOT_FIELD_COUNT || throw(
        ArgumentError(
            "snapshot event $index does not contain 66 binary fields",
        ),
    )
    length(shapes) == EXPECTED_SNAPSHOT_FIELD_COUNT || throw(
        ArgumentError("snapshot event $index does not contain 66 shape fields"),
    )
    Set(first.(splitext.(binaries))) == Set(first.(splitext.(shapes))) ||
        throw(ArgumentError("snapshot event $index binary/shape names differ"))
    length(entries) == 2 * EXPECTED_SNAPSHOT_FIELD_COUNT || throw(
        ArgumentError("snapshot event $index contains unexpected payloads"),
    )
    return nothing
end

function validate_ledger(raw_root, expected_count)
    ledger_path = required_file(
        joinpath(raw_root, "daily", "event_ledger.raw"),
        "Stage B completion ledger",
    )
    lines = readlines(ledger_path)
    length(lines) == expected_count + 2 ||
        throw(ArgumentError("completion ledger must contain exactly N+2 lines"))
    first(lines) ==
    "schema_version=1 capture_mode=all_daily max_events=$expected_count" ||
        throw(ArgumentError("completion ledger header differs"))
    last(lines) ==
    "capture_complete events=$expected_count max_events=$expected_count" ||
        throw(ArgumentError("completion ledger footer differs"))
    for index in 1:expected_count
        columns = split(lines[index + 1])
        length(columns) == 3 ||
            throw(ArgumentError("completion ledger row $index is malformed"))
        parse(Int, columns[1]) == index ||
            throw(ArgumentError("completion ledger rows are not gap-free"))
        parse(Int, columns[2])
        event = "event_$(lpad(index, 8, '0')).raw"
        columns[3] == "daily/$event" || throw(
            ArgumentError("completion ledger event path differs at row $index"),
        )
        validate_event_payload(joinpath(raw_root, "daily", event), index)
    end
    return (; ledger_path, event_count = expected_count)
end

function netcdf_files(root)
    return sort!([
        relpath(joinpath(directory, name), root) for
        (directory, _, names) in walkdir(root) for
        name in names if endswith(lowercase(name), ".nc")
    ])
end

function write_manifest(path, root)
    files = netcdf_files(root)
    open(path, "w") do io
        for relative in files
            println(io, sha256_file(joinpath(root, relative)), "  ", relative)
        end
    end
    return files
end

function compare_outputs!(site, prepared, oracle, evidence_root)
    oracle_manifest_path = joinpath(evidence_root, "oracle_outputs.sha256")
    candidate_manifest_path =
        joinpath(evidence_root, "candidate_outputs.sha256")
    oracle_files = write_manifest(oracle_manifest_path, oracle.netcdf_root)
    candidate_files =
        write_manifest(candidate_manifest_path, prepared.netcdf_root)
    length(oracle_files) == EXPECTED_OUTPUT_COUNT ||
        throw(ArgumentError("$site oracle output inventory is not 57 files"))
    candidate_files == oracle_files || throw(
        ArgumentError("$site instrumented output inventory differs from #98"),
    )
    report =
        compare_de_hai_directories(oracle.netcdf_root, prepared.netcdf_root)
    failed_comparisons =
        filter(comparison -> !comparison.ok, report.file_comparisons)
    comparison_issues = if isempty(failed_comparisons)
        String[]
    else
        failure = first(failed_comparisons)
        [
            "$(failure.filename): metadata=$(join(failure.metadata_mismatches, ", ")); " *
            "record_count=$(failure.overlap.record_count); " *
            "variable_values_ok=$(isnothing(failure.variable) ? false : failure.variable.values.ok)",
        ]
    end
    daily_comparisons = filter(
        comparison -> endswith(comparison.filename, "_daily.nc"),
        report.file_comparisons,
    )
    isempty(daily_comparisons) &&
        throw(ArgumentError("$site comparison has no daily NetCDF outputs"))
    record_counts =
        [comparison.overlap.record_count for comparison in daily_comparisons]
    unique_record_counts = unique(record_counts)
    length(unique_record_counts) == 1 || throw(
        ArgumentError("$site daily NetCDF outputs have unequal record counts"),
    )
    record_count = only(unique_record_counts)
    receipt = Dict(
        "schema_version" => 1,
        "site" => site,
        "status" => report.ok ? "pass" : "failed",
        "result" => report.ok ? "pass" : "fail",
        "reference_kind" => "fresh_local_fortran",
        "candidate_kind" => "instrumented_stage_b_v5",
        "synthetic_data_used" => false,
        "criteria" => EXACT_COMPARISON_CRITERIA,
        "compared_files" => length(report.compared_files),
        "failed_files" =>
            count(comparison -> !comparison.ok, report.file_comparisons),
        "record_count_per_daily_file" => record_count,
        "oracle_output_manifest_sha256" =>
            sha256_file(oracle_manifest_path),
        "candidate_output_manifest_sha256" =>
            sha256_file(candidate_manifest_path),
        "oracle_receipt_sha256" => sha256_file(oracle.receipt_path),
        "issue" => comparison_issues,
    )
    receipt_path = joinpath(evidence_root, "nonperturbation_receipt.toml")
    write_toml(receipt_path, receipt)
    report.ok &&
    length(report.compared_files) == EXPECTED_OUTPUT_COUNT &&
    receipt["failed_files"] == 0 || throw(
        ArgumentError(
            "$site exact 57-file nonperturbation comparison failed: " *
            join(comparison_issues, "; "),
        ),
    )
    return (; receipt_path, oracle_manifest_path, record_count)
end

function execution_receipt(
    site,
    status,
    issues,
    prepared,
    config,
    oracle,
    command_path,
    run_log_path,
    resource_time_path,
    exit_code,
    ledger = nothing,
)
    cycle = oracle_first_cycle(oracle)
    table = Dict(
        "schema_version" => 1,
        "site" => site,
        "status" => status,
        "issue" => issues,
        "exit_code" => exit_code,
        "reference_kind" => "fresh_local_fortran",
        "candidate_kind" => "instrumented_stage_b_v5",
        "capture_mode" => "all_daily",
        "capture_year" => cycle.capture_year,
        "capture_event_count" => cycle.event_count,
        "capture_source_calendar" => cycle.source_calendar,
        "capture_first_time" => string(cycle.first_time),
        "capture_last_time" => string(cycle.last_time),
        "capture_next_year_start" => string(cycle.next_year_start),
        "oracle_daily_time_file_sha256" => cycle.time_file_sha256,
        "oracle_daily_time_sha256" => cycle.time_sha256,
        "max_events" => config.max_events,
        "source_archive_sha256" => config.source_archive_sha256,
        "source_tree_sha256" => config.source_tree_sha256,
        "source_commit" => config.source_commit,
        "instrumentation_patch_sha256" =>
            config.instrumentation_patch_sha256,
        "snapshot_schema_sha256" => config.snapshot_schema_sha256,
        "instrumented_executable_sha256" =>
            sha256_file(config.executable_path),
        "container_sha256" => sha256_file(config.container_path),
        "parameter_namelist_sha256" =>
            sha256_file(config.parameter_namelist_path),
        "job_options_sha256" => sha256_file(prepared.job_options_path),
        "initial_condition_sha256" =>
            sha256_file(prepared.initial_condition_path),
        "oracle_receipt_sha256" => sha256_file(oracle.receipt_path),
        "command_sha256" => sha256_file(command_path),
        "run_log_sha256" => sha256_file(run_log_path),
        "resource_time_sha256" => sha256_file(resource_time_path),
    )
    if !isnothing(ledger)
        table["completion_ledger_sha256"] = sha256_file(ledger.ledger_path)
        table["event_count"] = ledger.event_count
    end
    return table
end

"""
    execute_site!(site, workspace, config; command_runner = run)

Prepare one isolated CLASSIC v2 site run, execute the instrumented Stage B v5
binary with bounded all-daily capture, reject semantic failures, verify the
single append-only completion ledger and every event payload, and compare all
57 daily NetCDF outputs exactly with the pinned fresh-local #98 oracle.
"""
function execute_site!(site, workspace, config; command_runner = run)
    site isa AbstractString && !isempty(site) ||
        throw(ArgumentError("site must be a nonempty string"))
    validate_config(config)
    oracle = validate_oracle(site, config)
    cycle = oracle_first_cycle(oracle)
    config.max_events == cycle.event_count ||
        throw(ArgumentError("max_events differs from oracle first-year length"))
    prepared = prepare_workspace(site, workspace, config, oracle)
    run_end_year = parse_run_end_year(prepared.job_options_path)

    command = command_specification(site, prepared, config)
    command_path = joinpath(prepared.evidence_root, "command.txt")
    run_log_path = joinpath(prepared.evidence_root, "run.log")
    resource_time_path = joinpath(prepared.evidence_root, "resource_time.txt")
    write(command_path, command.text * "\n")
    write(run_log_path, "")
    started = time_ns()
    exit_code = try
        result = command_runner(
            pipeline(
                command.command;
                stdout = run_log_path,
                stderr = run_log_path,
            ),
        )
        runner_exit_code(result)
    catch error
        write(
            resource_time_path,
            "elapsed_seconds=$(1.0e-9 * (time_ns() - started))\n",
        )
        issues = ["execution error: $(sprint(showerror, error))"]
        receipt_path =
            joinpath(prepared.evidence_root, "execution_receipt.toml")
        write_toml(
            receipt_path,
            execution_receipt(
                site,
                "failed",
                issues,
                prepared,
                config,
                oracle,
                command_path,
                run_log_path,
                resource_time_path,
                1,
            ),
        )
        throw(ArgumentError(join(issues, "; ")))
    end
    write(
        resource_time_path,
        "elapsed_seconds=$(1.0e-9 * (time_ns() - started))\n",
    )

    issues = String[]
    exit_code == 0 || push!(issues, "execution exited with status $exit_code")
    append!(issues, semantic_log_issues(run_log_path, run_end_year))
    execution_receipt_path =
        joinpath(prepared.evidence_root, "execution_receipt.toml")
    if !isempty(issues)
        write_toml(
            execution_receipt_path,
            execution_receipt(
                site,
                "failed",
                issues,
                prepared,
                config,
                oracle,
                command_path,
                run_log_path,
                resource_time_path,
                exit_code,
            ),
        )
        throw(
            ArgumentError(
                "semantic CLASSIC execution failure: $(join(issues, "; "))",
            ),
        )
    end

    ledger = validate_ledger(prepared.raw_root, config.max_events)
    write_toml(
        execution_receipt_path,
        execution_receipt(
            site,
            "pass",
            String[],
            prepared,
            config,
            oracle,
            command_path,
            run_log_path,
            resource_time_path,
            exit_code,
            ledger,
        ),
    )
    comparison =
        compare_outputs!(site, prepared, oracle, prepared.evidence_root)
    return (;
        site,
        run_root = prepared.run_root,
        site_root = prepared.site_root,
        raw_root = prepared.raw_root,
        netcdf_root = prepared.netcdf_root,
        oracle_netcdf_root = oracle.netcdf_root,
        job_options_path = prepared.job_options_path,
        initial_condition_path = prepared.initial_condition_path,
        execution_receipt_path,
        nonperturbation_receipt_path = comparison.receipt_path,
        command_path,
        run_log_path,
        resource_time_path,
        oracle_manifest_path = comparison.oracle_manifest_path,
        oracle_receipt_path = oracle.receipt_path,
        oracle_time_path = cycle.time_path,
        oracle_time_file_sha256 = cycle.time_file_sha256,
        oracle_time_sha256 = cycle.time_sha256,
        capture_year = cycle.capture_year,
        capture_source_calendar = cycle.source_calendar,
        capture_first_time = cycle.first_time,
        capture_last_time = cycle.last_time,
        capture_next_year_start = cycle.next_year_start,
        event_count = ledger.event_count,
        record_count_per_daily_file = comparison.record_count,
    )
end

end
