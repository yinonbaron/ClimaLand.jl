#!/usr/bin/env julia

using Dates
import ClimaLand
import TOML

include("extraction.jl")
include("site_execution.jl")
include("real_capture.jl")

using .ClassicAllSitesExtraction: run_extraction_plan
using .ClassicRealSiteCapture: capture_real_site!
using .ClassicSiteExecution: execute_site!

function required_string(config, key)
    value = get(config, key, nothing)
    value isa AbstractString && !isempty(value) ||
        throw(ArgumentError("campaign configuration lacks $key"))
    return value
end

function execution_config(config, site)
    oracle_root = required_string(config, "oracle_root")
    oracle = ClassicSiteExecution.validate_oracle(site, (; oracle_root))
    cycle = ClassicSiteExecution.oracle_first_cycle(oracle)
    return (;
        promoted_source_root = required_string(config, "promoted_source_root"),
        oracle_root,
        parameter_namelist_path = required_string(
            config,
            "parameter_namelist_path",
        ),
        executable_path = required_string(config, "executable_path"),
        container_path = required_string(config, "container_path"),
        max_events = cycle.event_count,
        source_archive_sha256 = required_string(
            config,
            "source_archive_sha256",
        ),
        source_tree_sha256 = required_string(config, "source_tree_sha256"),
        source_commit = required_string(config, "source_commit"),
        instrumentation_patch_sha256 = required_string(
            config,
            "instrumentation_patch_sha256",
        ),
        snapshot_schema_sha256 = required_string(
            config,
            "snapshot_schema_sha256",
        ),
    )
end


function capture_in_child!(capture!, site, workspace, required_fields, config)
    execution_workspace = joinpath(workspace, "execution")
    ispath(execution_workspace) &&
        throw(ArgumentError("site execution workspace already exists"))
    result = capture!(site, execution_workspace, required_fields, config)
    source = joinpath(execution_workspace, "capture")
    destination = joinpath(workspace, "capture")
    isdir(source) || throw(ArgumentError("site callback lacks capture root"))
    ispath(destination) &&
        throw(ArgumentError("site packer capture root already exists"))
    mv(source, destination)
    return result
end
function capture_callback(config)
    trajectory_schema_path = required_string(config, "trajectory_schema_path")
    snapshot_schema_path = required_string(config, "snapshot_schema_path")
    tolerance_evidence_root = required_string(config, "tolerance_evidence_root")
    return function (site, workspace, required_fields)
        site_execution = execution_config(config, site)
        producer_config = (;
            execute_site!,
            execution_config = site_execution,
            trajectory_schema_path,
            snapshot_schema_path,
            tolerance_evidence_root,
            executable_path = site_execution.executable_path,
            parameter_namelist_path = site_execution.parameter_namelist_path,
            source_archive_sha256 = site_execution.source_archive_sha256,
            source_tree_sha256 = site_execution.source_tree_sha256,
            source_commit = site_execution.source_commit,
            instrumentation_patch_sha256 = site_execution.instrumentation_patch_sha256,
        )
        return capture_in_child!(
            capture_real_site!,
            site,
            workspace,
            required_fields,
            producer_config,
        )
    end
end

function main(args)
    length(args) == 1 ||
        error("usage: run_real_campaign.jl CAMPAIGN_CONFIGURATION.toml")
    config = TOML.parsefile(only(args))
    get(config, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported campaign configuration"))
    stop_on_failure = get(config, "stop_on_failure", false)
    stop_on_failure isa Bool ||
        throw(ArgumentError("campaign stop_on_failure must be Boolean"))
    result = run_extraction_plan(
        required_string(config, "plan_path"),
        required_string(config, "work_root"),
        required_string(config, "archive_root"),
        capture_callback(config);
        repository_root = required_string(config, "repository_root"),
        stop_on_failure,
    )
    println(
        "sites=$(result.site_count) packed=$(result.packed_count) failed=$(result.failed_count)",
    )
    result.failed_count == 0 || exit(1)
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
