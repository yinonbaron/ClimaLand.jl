#!/usr/bin/env julia

import TOML

const WORKSPACE_ROOT = normpath(joinpath(@__DIR__, ".."))
include(joinpath(WORKSPACE_ROOT, "trajectory_bundle", "trajectory_bundle.jl"))
include(joinpath(WORKSPACE_ROOT, "trajectory_bundle", "tolerance_contract.jl"))
include(joinpath(WORKSPACE_ROOT, "trajectory_bundle", "free_replay.jl"))
include(
    joinpath(
        WORKSPACE_ROOT,
        "trajectory_bundle",
        "classic_callback_adapter.jl",
    ),
)
include(joinpath(WORKSPACE_ROOT, "all_site_parity", "all_site_parity.jl"))
include("run_real_campaign.jl")

using .ClassicAllSiteParity:
    consume_site_archive, load_campaign_inventory, load_expanded_schema
using .ClassicAllSitesExtraction: prepare_extraction_resume, run_extraction_plan
using .ClassicCallbackAdapter: classic_callback_transition
using .ClassicFreeReplay: free_replay
using .ClassicToleranceContract: load_tolerance_contract
using .ClassicTrajectoryBundle: verify_replay_acceptance

function strict_validator(config)
    policy_path = joinpath(@__DIR__, "site_policy_inventory.toml")
    metrics_path =
        joinpath(WORKSPACE_ROOT, "process_stress_matrix", "site_metrics.toml")
    schema_path = required_string(config, "trajectory_schema_path")
    evidence_root = required_string(config, "tolerance_evidence_root")
    tolerance_path =
        joinpath(WORKSPACE_ROOT, "process_stress_matrix", "tolerances.toml")
    inventory = load_campaign_inventory(policy_path, metrics_path)
    schema = load_expanded_schema(schema_path)
    tolerances = load_tolerance_contract(tolerance_path, schema; evidence_root)
    return function (site, archive, receipt)
        package = (; site, archive, receipt)
        return consume_site_archive(
            package,
            inventory,
            schema_path,
            verify_replay_acceptance,
            classic_callback_transition,
            free_replay;
            tolerances,
        )
    end
end

function resume_main(args)
    length(args) == 3 || error(
        "usage: run_real_campaign_resume.jl CONFIG EXPECTED_CONFIG_SHA256 EXPECTED_PLAN_SHA256",
    )
    config_path, expected_config_sha256, expected_plan_sha256 = args
    config = TOML.parsefile(config_path)
    get(config, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported campaign configuration"))
    get(config, "stop_on_failure", nothing) === true ||
        throw(ArgumentError("resumed campaign must stop on failure"))
    plan_path = required_string(config, "plan_path")
    work_root = required_string(config, "work_root")
    archive_root = required_string(config, "archive_root")
    repository_root = required_string(config, "repository_root")
    validate_existing! = strict_validator(config)
    resume = prepare_extraction_resume(
        plan_path,
        config_path,
        work_root,
        archive_root,
        validate_existing!;
        repository_root,
        expected_plan_sha256,
        expected_config_sha256,
    )
    report = run_extraction_plan(
        plan_path,
        work_root,
        archive_root,
        capture_callback(config);
        repository_root,
        stop_on_failure = true,
        resume,
    )
    println(
        "sites=$(report.site_count) packed=$(report.packed_count) failed=$(report.failed_count)",
    )
    report.failed_count == 0 || exit(1)
end

abspath(PROGRAM_FILE) == (@__FILE__) && resume_main(ARGS)
