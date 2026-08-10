#!/usr/bin/env julia

const REPORT_WORKSPACE_ROOT = normpath(joinpath(@__DIR__, ".."))
include(
    joinpath(
        REPORT_WORKSPACE_ROOT,
        "trajectory_bundle",
        "trajectory_bundle.jl",
    ),
)
include(
    joinpath(
        REPORT_WORKSPACE_ROOT,
        "trajectory_bundle",
        "tolerance_contract.jl",
    ),
)
include(joinpath(REPORT_WORKSPACE_ROOT, "trajectory_bundle", "free_replay.jl"))
include(
    joinpath(
        REPORT_WORKSPACE_ROOT,
        "trajectory_bundle",
        "classic_callback_adapter.jl",
    ),
)
include("all_site_parity.jl")
include("all_site_report.jl")

using .ClassicAllSiteParity:
    consume_site_archive, load_campaign_inventory, run_all_site_parity
using .ClassicAllSiteReport: write_all_site_draft_report
using .ClassicCallbackAdapter: classic_callback_transition
using .ClassicFreeReplay: free_replay
using .ClassicToleranceContract: evidence_root_from_env, load_tolerance_contract
using .ClassicTrajectoryBundle: load_bundle_schema, verify_replay_acceptance

function all_site_report_main(args)
    length(args) == 2 || throw(
        ArgumentError(
            "usage: run_all_site_report.jl ARCHIVE_ROOT EXTERNAL_DRAFT_REPORT",
        ),
    )
    archive_root, output_path = abspath.(args)
    policy_path = joinpath(
        REPORT_WORKSPACE_ROOT,
        "all_sites",
        "site_policy_inventory.toml",
    )
    metrics_path = joinpath(
        REPORT_WORKSPACE_ROOT,
        "process_stress_matrix",
        "site_metrics.toml",
    )
    schema_path =
        joinpath(REPORT_WORKSPACE_ROOT, "trajectory_bundle", "schema.toml")
    tolerance_path = joinpath(
        REPORT_WORKSPACE_ROOT,
        "process_stress_matrix",
        "tolerances.toml",
    )
    inventory = load_campaign_inventory(policy_path, metrics_path)
    tolerances = load_tolerance_contract(
        tolerance_path,
        load_bundle_schema(schema_path);
        evidence_root = evidence_root_from_env(),
    )
    consume =
        package -> consume_site_archive(
            package,
            inventory,
            schema_path,
            verify_replay_acceptance,
            classic_callback_transition,
            free_replay;
            tolerances,
        )
    campaign = run_all_site_parity(consume, archive_root, inventory)
    result = write_all_site_draft_report(
        output_path,
        campaign,
        archive_root,
        inventory,
        tolerances;
        repository_root = normpath(joinpath(@__DIR__, "../../../..")),
    )
    status = result.report["status"]
    site_count = result.report["site_count"]
    println("status=$status sites=$site_count sha256=$(result.sha256)")
    return result
end

abspath(PROGRAM_FILE) == (@__FILE__) && all_site_report_main(ARGS)
