module ClassicRealSiteCapture

using Dates
import NCDatasets
import SHA
import TOML

include("inactive_stage_b.jl")
include("replay_failure.jl")
include("semantic_time.jl")
include(joinpath(@__DIR__, "..", "trajectory_bundle", "trajectory_bundle.jl"))
include(
    joinpath(@__DIR__, "..", "trajectory_bundle", "trajectory_generator.jl"),
)
include(joinpath(@__DIR__, "..", "trajectory_bundle", "free_replay.jl"))
if !isdefined(Main, :ClassicToleranceContract)
    Base.include(
        Main,
        joinpath(@__DIR__, "..", "trajectory_bundle", "tolerance_contract.jl"),
    )
end
include(
    joinpath(
        @__DIR__,
        "..",
        "trajectory_bundle",
        "classic_callback_adapter.jl",
    ),
)

using .ClassicInactiveStageB: write_inactive_stage_b_evidence!
using Main.ClassicToleranceContract: load_tolerance_contract
using .ClassicFreeReplay: free_replay, write_replay_receipt
using .ClassicCallbackAdapter: classic_callback_transition
using .ClassicTrajectoryBundle:
    load_bundle_schema, open_replay, verify_replay_acceptance
using .ClassicTrajectoryGenerator: generate_trajectory_bundle

export ReplayFailure,
    capture_real_site!, classify_stage_b_applicability, validate_capture_root

const DEFAULT_TOLERANCE_CONTRACT_PATH = normpath(
    joinpath(@__DIR__, "..", "process_stress_matrix", "tolerances.toml"),
)

const CAPTURE_ROOT_ENTRIES = Set((
    "manifest.toml",
    "capture_receipt.toml",
    "field_activity.toml",
    "evidence",
    "payloads",
))

file_sha256(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

function write_toml(path, table)
    ispath(path) && throw(ArgumentError("refusing to overwrite $path"))
    mkpath(dirname(path))
    open(path, "w") do io
        TOML.print(io, table; sorted = true)
    end
    return path
end

function validate_capture_root(capture_root)
    isdir(capture_root) || throw(ArgumentError("capture root does not exist"))
    Set(readdir(capture_root)) == CAPTURE_ROOT_ENTRIES || throw(
        ArgumentError("capture root inventory differs from canonical contract"),
    )
    all(
        isfile(joinpath(capture_root, name)) for
        name in ("manifest.toml", "capture_receipt.toml", "field_activity.toml")
    ) || throw(ArgumentError("capture root lacks canonical control files"))
    all(
        isdir(joinpath(capture_root, name)) for name in ("evidence", "payloads")
    ) ||
        throw(ArgumentError("capture root lacks canonical payload directories"))
    return true
end

function ledger_events(path, expected_count)
    lines = filter(!isempty, strip.(readlines(path)))
    length(lines) == expected_count + 2 ||
        throw(ArgumentError("completion ledger event count differs"))
    first(lines) ==
    "schema_version=1 capture_mode=all_daily max_events=$expected_count" ||
        throw(ArgumentError("completion ledger header differs"))
    last(lines) ==
    "capture_complete events=$expected_count max_events=$expected_count" ||
        throw(ArgumentError("completion ledger lacks its completion marker"))
    return map(enumerate(lines[2:(end - 1)])) do (index, line)
        columns = split(line)
        length(columns) == 3 ||
            throw(ArgumentError("completion ledger row is malformed"))
        parse(Int, columns[1]) == index ||
            throw(ArgumentError("completion ledger ordinals are not gap-free"))
        expected_path = joinpath("daily", "event_$(lpad(index, 8, '0')).raw")
        columns[3] == expected_path ||
            throw(ArgumentError("completion ledger event path differs"))
        (; index, iday = parse(Int, columns[2]), path = expected_path)
    end
end

function write_time_evidence!(site, execution)
    time_file = joinpath(execution.netcdf_root, "tsl_daily.nc")
    isfile(time_file) || throw(ArgumentError("site output lacks tsl_daily.nc"))
    times, source_calendar, time_units =
        NCDatasets.NCDataset(time_file) do dataset
            time = dataset["time"]
            source_calendar = String(time.attrib["calendar"])
            source_calendar == "standard" ||
                throw(ArgumentError("source calendar is not standard"))
            (
                collect(DateTime.(time[:])),
                source_calendar,
                String(time.attrib["units"]),
            )
        end
    source_calendar == "standard" ||
        throw(ArgumentError("source calendar is not standard"))
    event_count = execution.event_count
    length(times) >= event_count ||
        throw(ArgumentError("daily NetCDF contains fewer records than capture"))
    captured = times[1:event_count]
    time_sha256 = semantic_time_sha256(times, source_calendar, time_units)
    first_year = year(first(captured))
    first_year == execution.capture_year ||
        throw(ArgumentError("candidate capture year differs from oracle"))
    source_calendar == execution.capture_source_calendar ||
        throw(ArgumentError("candidate source calendar differs from oracle"))
    time_sha256 == execution.oracle_time_sha256 ||
        throw(ArgumentError("candidate daily time source differs from oracle"))
    event_count == daysinyear(first_year) ||
        throw(ArgumentError("capture does not span exactly one calendar year"))
    first(captured) == DateTime(first_year, 1, 1) ||
        throw(ArgumentError("capture first interval does not start January 1"))
    last(captured) + Day(1) == DateTime(first_year + 1, 1, 1) ||
        throw(ArgumentError("capture does not reach next January 1"))
    all(
        captured[index] - captured[index - 1] == Day(1) for
        index in 2:event_count
    ) || throw(ArgumentError("daily NetCDF time is not gap-free"))
    first(captured) >= DateTime(1582, 10, 15) ||
        throw(ArgumentError("daily interval precedes the Gregorian cutover"))

    ledger_path = joinpath(execution.raw_root, "daily", "event_ledger.raw")
    ledger = ledger_events(ledger_path, event_count)
    evidence_root = joinpath(execution.raw_root, "trajectory_evidence_v1")
    mkpath(evidence_root)
    netcdf_receipt_path =
        joinpath(evidence_root, "netcdf_daily_time_receipt.toml")
    write_toml(
        netcdf_receipt_path,
        Dict(
            "schema_version" => 1,
            "status" => "pass",
            "site" => site,
            "netcdf_file" => basename(time_file),
            "netcdf_file_sha256" => file_sha256(time_file),
            "semantic_time_sha256" => time_sha256,
            "coordinate_count" => length(times),
            "captured_event_count" => event_count,
            "capture_year" => first_year,
            "chosen_event_count" => event_count,
            "captured_first_start" => string(first(captured)),
            "captured_last_start" => string(last(captured)),
            "captured_next_year_start" => string(last(captured) + Day(1)),
            "source_calendar" => source_calendar,
            "normalized_calendar" => "proleptic_gregorian",
            "time_units" => time_units,
            "gap_free_daily" => true,
            "all_intervals_after_gregorian_cutover" => true,
        ),
    )
    index_path = joinpath(execution.raw_root, "daily_time_index.toml")
    write_toml(
        index_path,
        Dict(
            "schema_version" => 1,
            "site" => site,
            "source" => "netcdf_daily_time",
            "source_calendar" => source_calendar,
            "normalized_calendar" => "proleptic_gregorian",
            "calendar" => "proleptic_gregorian",
            "time_standard" => "UTC",
            "complete_seasonal_cycle" => true,
            "completion_ledger_sha256" => file_sha256(ledger_path),
            "netcdf_time_receipt_sha256" => file_sha256(netcdf_receipt_path),
            "event" => [
                Dict(
                    "index" => record.index,
                    "iday" => record.iday,
                    "path" => record.path,
                    "time_start" => string(captured[record.index]),
                    "time_end" => string(captured[record.index] + Day(1)),
                    "duration_days" => 1.0,
                ) for record in ledger
            ],
        ),
    )
    return (;
        index_path,
        netcdf_receipt_path,
        ledger_path,
        time_file_sha256 = file_sha256(time_file),
        time_sha256,
    )
end

function copy_execution_evidence!(execution)
    evidence_root = joinpath(execution.raw_root, "trajectory_evidence_v1")
    mkpath(evidence_root)
    copied = Dict{String, String}()
    for (name, source) in (
        "execution" => execution.execution_receipt_path,
        "comparison" => execution.nonperturbation_receipt_path,
    )
        destination = joinpath(evidence_root, name * ".toml")
        cp(source, destination)
        copied[name] = destination
    end
    return copied
end

function write_instrumentation_receipt!(site, execution, time, evidence, config)
    receipt_path = joinpath(execution.raw_root, "capture_receipt.toml")
    provenance = Dict(
        "source_archive_sha256" => config.source_archive_sha256,
        "source_tree_sha256" => config.source_tree_sha256,
        "source_commit" => config.source_commit,
        "executable_sha256" => file_sha256(config.executable_path),
        "parameter_namelist_sha256" =>
            file_sha256(config.parameter_namelist_path),
        "job_options_sha256" => file_sha256(execution.job_options_path),
        "initial_condition_sha256" =>
            file_sha256(execution.initial_condition_path),
        "instrumentation_patch_sha256" =>
            config.instrumentation_patch_sha256,
        "snapshot_schema_sha256" =>
            file_sha256(config.snapshot_schema_path),
        "time_index_sha256" => file_sha256(time.index_path),
        "completion_ledger_path" =>
            relpath(time.ledger_path, execution.raw_root),
        "completion_ledger_sha256" => file_sha256(time.ledger_path),
        "execution_receipt_path" =>
            relpath(evidence["execution"], execution.raw_root),
        "execution_receipt_sha256" => file_sha256(evidence["execution"]),
        "nonperturbation_receipt_path" =>
            relpath(evidence["comparison"], execution.raw_root),
        "nonperturbation_receipt_sha256" =>
            file_sha256(evidence["comparison"]),
        "netcdf_time_receipt_path" =>
            relpath(time.netcdf_receipt_path, execution.raw_root),
        "netcdf_time_receipt_sha256" =>
            file_sha256(time.netcdf_receipt_path),
    )
    write_toml(
        receipt_path,
        Dict(
            "schema_version" => 1,
            "status" => "complete",
            "site" => site,
            "capture_mode" => "all_daily",
            "event_count" => execution.event_count,
            "complete_seasonal_cycle" => true,
            "reference_kind" => "fresh_local_fortran",
            "oracle_contract" => "stage_b_v5",
            "synthetic_data_used" => false,
            "oracle_receipt_sha256" =>
                file_sha256(execution.oracle_receipt_path),
            "provenance" => provenance,
        ),
    )
    return receipt_path
end

activity_vector(value::AbstractArray) = Float64.(vec(collect(value)))
activity_vector(value) = Float64[Float64(value)]

function activity_values(replay)
    values = Dict{String, Vector{Float64}}()
    for collection in (replay.static_data, replay.initial_state)
        for (name, value) in collection
            values[name] = activity_vector(value)
        end
    end
    for step in replay.steps
        for collection in
            (step.drivers, step.reference_state, step.audit_diagnostics)
            for (name, value) in collection
                append!(get!(values, name, Float64[]), activity_vector(value))
            end
        end
    end
    return values
end

function write_activity!(path, site, replay)
    values = activity_values(replay)
    records = map(sort!(collect(keys(values)))) do name
        field_values = values[name]
        all(isfinite, field_values) ||
            throw(ArgumentError("$name contains non-finite values"))
        count_nonzero = count(!iszero, field_values)
        maximum_absolute_value = maximum(abs, field_values; init = 0.0)
        active = count_nonzero > 0
        Dict(
            "name" => name,
            "present" => true,
            "active" => active,
            "nonzero_count" => count_nonzero,
            "maximum_absolute_value" => maximum_absolute_value,
            "reason" => active ? "observed_nonzero" : "observed_zero",
        )
    end
    length(records) == 70 ||
        throw(ArgumentError("activity inventory is not the 70-field contract"))
    write_toml(
        path,
        Dict(
            "schema_version" => 1,
            "site" => site,
            "field_count" => length(records),
            "activity_definition" => "observed_nonzero",
            "field" => records,
        ),
    )
    return (
        names = [record["name"] for record in records],
        inactive = [record["name"] for record in records if !record["active"]],
    )
end

function seal_replay!(
    capture_root,
    trajectory_schema_path,
    tolerance_evidence_root,
    tolerance_contract_path = DEFAULT_TOLERANCE_CONTRACT_PATH,
)
    manifest_path = joinpath(capture_root, "manifest.toml")
    pre_replay_sha256 = file_sha256(manifest_path)
    replay = open_replay(capture_root, trajectory_schema_path)
    schema = load_bundle_schema(trajectory_schema_path)
    tolerances = load_tolerance_contract(
        tolerance_contract_path,
        schema;
        evidence_root = tolerance_evidence_root,
    )
    transition = classic_callback_transition(replay)
    report = free_replay(
        replay,
        transition;
        atol = 1.0e-13,
        rtol = 0.0,
        day_one_flux_tolerances = tolerances.flux,
        day_one_flux_tolerance_contract_sha256 = tolerances.sha256,
    )
    replay_name =
        report.ok ? "replay_receipt.toml" : "replay_failure_receipt.toml"
    replay_path = joinpath(capture_root, "evidence", replay_name)
    write_replay_receipt(
        replay_path,
        report,
        pre_replay_sha256;
        tolerance_rationale = "$(tolerances.rationale) Seasonal scalar ceiling is 1e-13 with rtol=0; day-one state is bit-exact and day-one flux uses the per-field contract.",
    )
    report.ok ||
        throw(ReplayFailure("seasonal free replay failed", replay_path, report))
    manifest = TOML.parsefile(manifest_path)
    evidence = manifest["evidence"]
    evidence["pre_replay_manifest_sha256"] = pre_replay_sha256
    evidence["replay_result"] = "pass"
    evidence["replay_receipt_path"] = relpath(replay_path, capture_root)
    evidence["replay_receipt_sha256"] = file_sha256(replay_path)
    evidence["replay_tolerance_contract_sha256"] = tolerances.sha256
    evidence["replay_day_one_state_gate"] = "bit_exact"
    evidence["replay_day_one_flux_gate"] = "hash_bound_per_field_absolute_tolerance"
    evidence["replay_tolerance_atol"] = 1.0e-13
    evidence["replay_tolerance_rtol"] = 0.0
    temporary = manifest_path * ".partial"
    open(temporary, "w") do io
        TOML.print(io, manifest; sorted = true)
    end
    mv(temporary, manifest_path; force = true)
    acceptance = verify_replay_acceptance(capture_root, trajectory_schema_path)
    acceptance.ok || throw(
        ArgumentError(
            "sealed replay evidence failed: $(join(acceptance.issues, "; "))",
        ),
    )
    return (; report, replay, replay_path)
end

function seal_inactive_stage_b!(capture_root, site, execution, config, replay)
    manifest_path = joinpath(capture_root, "manifest.toml")
    manifest = TOML.parsefile(manifest_path)
    path = joinpath(capture_root, "evidence", "inactive_stage_b.toml")
    result = write_inactive_stage_b_evidence!(
        path,
        site,
        capture_root,
        replay,
        manifest,
        execution.initial_condition_path,
        execution.job_options_path,
        config.execution_config.promoted_source_root,
        joinpath(
            @__DIR__,
            "..",
            "stage_b_snapshots",
            "generate_fortran_instrumentation.jl",
        );
        step_count = execution.event_count,
    )
    evidence = manifest["evidence"]
    evidence["stage_b_status"] = "inactive"
    evidence["replay_claimed"] = false
    evidence["replay_result"] = "not_applicable_inactive_path"
    evidence["inactive_stage_b_evidence_path"] = relpath(path, capture_root)
    evidence["inactive_stage_b_evidence_sha256"] = file_sha256(path)
    evidence["stage_c_semantics_excluded"] = true
    evidence["deferred_issue"] = 108
    temporary = manifest_path * ".partial"
    open(temporary, "w") do io
        TOML.print(io, manifest; sorted = true)
    end
    mv(temporary, manifest_path; force = true)
    return (;
        report = nothing,
        replay,
        evidence_path = path,
        stage_b_status = result.stage_b_status,
    )
end

function copy_extra_evidence!(capture_root, execution)
    evidence_root = joinpath(capture_root, "evidence")
    copied = Dict{String, String}()
    for (key, source, filename) in (
        ("command_sha256", execution.command_path, "command.txt"),
        ("run_log_sha256", execution.run_log_path, "run.log"),
        (
            "resource_time_sha256",
            execution.resource_time_path,
            "resource_time.txt",
        ),
        (
            "oracle_output_manifest_sha256",
            execution.oracle_manifest_path,
            "oracle_outputs.sha256",
        ),
        (
            "oracle_receipt_sha256",
            execution.oracle_receipt_path,
            "oracle_receipt.toml",
        ),
    )
        destination = joinpath(evidence_root, filename)
        ispath(destination) || cp(source, destination)
        copied[key] = file_sha256(destination)
    end
    return copied
end

function write_packed_capture_receipt!(
    site,
    capture_root,
    execution,
    time,
    applicability,
    inactive,
    config,
)
    evidence_root = joinpath(capture_root, "evidence")
    provenance = Dict(
        "source_archive_sha256" => config.source_archive_sha256,
        "source_tree_sha256" => config.source_tree_sha256,
        "source_commit" => config.source_commit,
        "instrumented_executable_sha256" =>
            file_sha256(config.executable_path),
        "instrumentation_patch_sha256" =>
            config.instrumentation_patch_sha256,
        "snapshot_schema_sha256" =>
            file_sha256(config.snapshot_schema_path),
        "parameter_namelist_sha256" =>
            file_sha256(config.parameter_namelist_path),
        "site_job_options_sha256" =>
            file_sha256(execution.job_options_path),
        "site_initial_condition_sha256" =>
            file_sha256(execution.initial_condition_path),
        "execution_receipt_sha256" =>
            file_sha256(execution.execution_receipt_path),
        "nonperturbation_receipt_sha256" =>
            file_sha256(execution.nonperturbation_receipt_path),
        "oracle_daily_time_file_sha256" =>
            execution.oracle_time_file_sha256,
        "candidate_daily_time_file_sha256" => time.time_file_sha256,
        "oracle_daily_time_sha256" => execution.oracle_time_sha256,
        "candidate_daily_time_sha256" => time.time_sha256,
        "completion_ledger_sha256" => file_sha256(time.ledger_path),
        "time_index_sha256" => file_sha256(time.index_path),
        "sealed_event_index_sha256" =>
            file_sha256(joinpath(evidence_root, "sealed_event_index.toml")),
    )
    if applicability.stage_b_status == "active"
        provenance["replay_receipt_sha256"] =
            file_sha256(applicability.replay_path)
    else
        provenance["inactive_stage_b_evidence_sha256"] =
            file_sha256(applicability.evidence_path)
    end
    merge!(provenance, copy_extra_evidence!(capture_root, execution))
    activity_path = joinpath(capture_root, "field_activity.toml")
    receipt = Dict(
        "schema_version" => 1,
        "site" => site,
        "status" => "complete",
        "reference_kind" => "fresh_local_fortran",
        "oracle_contract" => "stage_b_v5",
        "synthetic_data_used" => false,
        "capture_year" => execution.capture_year,
        "capture_event_count" => execution.event_count,
        "capture_source_calendar" => execution.capture_source_calendar,
        "capture_first_time" => string(execution.capture_first_time),
        "capture_last_time" => string(execution.capture_last_time),
        "capture_next_year_start" =>
            string(execution.capture_next_year_start),
        "oracle_daily_time_file_sha256" =>
            execution.oracle_time_file_sha256,
        "candidate_daily_time_file_sha256" => time.time_file_sha256,
        "oracle_daily_time_sha256" => execution.oracle_time_sha256,
        "candidate_daily_time_sha256" => time.time_sha256,
        "complete_seasonal_cycle" => true,
        "step_count" => execution.event_count,
        "trajectory_schema_sha256" =>
            file_sha256(config.trajectory_schema_path),
        "manifest_sha256" =>
            file_sha256(joinpath(capture_root, "manifest.toml")),
        "activity_report_sha256" => file_sha256(activity_path),
        "nonperturbation_result" => "pass",
        "stage_b_status" => applicability.stage_b_status,
        "replay_claimed" => applicability.stage_b_status == "active",
        "stage_c_semantics_excluded" =>
            applicability.stage_b_status == "inactive",
        "deferred_issue" =>
            applicability.stage_b_status == "inactive" ? 108 : 0,
        "missing_fields" => String[],
        "inactive_fields" => inactive,
        "provenance" => provenance,
    )
    write_toml(joinpath(capture_root, "capture_receipt.toml"), receipt)
    return receipt
end

function capture_real_site!(site, workspace, required_fields, config)
    if hasproperty(config, :site_runner)
        result = config.site_runner(site, workspace, required_fields, config)
        validate_capture_root(joinpath(workspace, "capture"))
        return result
    end
    hasproperty(config, :execute_site!) ||
        throw(ArgumentError("real site capture lacks execute_site!"))
    execution = config.execute_site!(site, workspace, config.execution_config)
    evidence = copy_execution_evidence!(execution)
    time = write_time_evidence!(site, execution)
    instrumentation_receipt =
        write_instrumentation_receipt!(site, execution, time, evidence, config)
    capture_root = joinpath(workspace, "capture")
    generate_trajectory_bundle(
        capture_root,
        execution.raw_root,
        config.trajectory_schema_path,
        config.snapshot_schema_path,
        time.index_path,
        instrumentation_receipt,
    )
    raw_replay = open_replay(capture_root, config.trajectory_schema_path)
    mineral_mask = vec(raw_replay.static_data["static.mineral_mask"])
    stage_b_status = classify_stage_b_applicability(mineral_mask)
    applicability = if stage_b_status == "inactive"
        seal_inactive_stage_b!(capture_root, site, execution, config, raw_replay)
    else
        active = seal_replay!(
            capture_root,
            config.trajectory_schema_path,
            config.tolerance_evidence_root,
        )
        (; active..., stage_b_status = "active")
    end
    activity = write_activity!(
        joinpath(capture_root, "field_activity.toml"),
        site,
        applicability.replay,
    )
    Set(required_fields) == Set(activity.names) ||
        throw(ArgumentError("extraction plan field inventory differs"))
    receipt = write_packed_capture_receipt!(
        site,
        capture_root,
        execution,
        time,
        applicability,
        activity.inactive,
        config,
    )
    validate_capture_root(capture_root)
    return (; execution, replay = applicability.report, receipt)
end

"""
    classify_stage_b_applicability(mineral_mask)

Classify a capture as mineral Stage B or inactive peat/moss. Mixed and
non-binary masks are rejected because one package cannot claim both scopes.
"""
function classify_stage_b_applicability(mineral_mask)
    isempty(mineral_mask) &&
        throw(ArgumentError("mineral mask must contain at least one tile"))
    all(value -> value == 0 || value == 1, mineral_mask) ||
        throw(ArgumentError("mineral mask contains a non-binary value"))
    all(iszero, mineral_mask) && return "inactive"
    all(isone, mineral_mask) && return "active"
    throw(ArgumentError("mixed mineral masks are outside one-site scope"))
end

end
