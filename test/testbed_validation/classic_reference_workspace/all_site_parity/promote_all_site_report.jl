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
include("all_site_parity.jl")
include("all_site_report.jl")

using .ClassicAllSiteReport: write_all_site_acceptance_report

function promote_all_site_report_main(args)
    length(args) == 4 || throw(
        ArgumentError(
            "usage: promote_all_site_report.jl DRAFT_REPORT EXTERNAL_ACCEPTANCE_REPORT APPROVED_DRAFT_SHA256 APPROVAL_REFERENCE",
        ),
    )
    draft_path, output_path = abspath.(args[1:2])
    result = write_all_site_acceptance_report(
        output_path,
        draft_path;
        repository_root = normpath(joinpath(@__DIR__, "../../../..")),
        approved_draft_sha256 = args[3],
        approval_reference = args[4],
    )
    status = result.report["status"]
    site_count = result.report["site_count"]
    println("status=$status sites=$site_count sha256=$(result.sha256)")
    return result
end

abspath(PROGRAM_FILE) == (@__FILE__) && promote_all_site_report_main(ARGS)
