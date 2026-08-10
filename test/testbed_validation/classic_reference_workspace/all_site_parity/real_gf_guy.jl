using Test

const WORKSPACE_ROOT = normpath(joinpath(@__DIR__, ".."))
include("real_gf_guy_root.jl")
using .RealGFGuyRoot: required_archive_root

const ARCHIVE_ROOT = required_archive_root()
const GF_GUY_ARCHIVE_SHA256 = "c7569a189b0246d49457e2b59f2d895700acee46349ed21c2092eedcd856ec64"
const GF_GUY_RECEIPT_SHA256 = "fdb43650aad00d2b90fdb0420279c84439cbbf9f0875931698da1c16bd69ffcf"

include(joinpath(WORKSPACE_ROOT, "trajectory_bundle", "trajectory_bundle.jl"))
include(joinpath(WORKSPACE_ROOT, "trajectory_bundle", "tolerance_contract.jl"))
using .ClassicToleranceContract
using .ClassicTrajectoryBundle
include(joinpath(WORKSPACE_ROOT, "trajectory_bundle", "free_replay.jl"))
using .ClassicFreeReplay
include(
    joinpath(
        WORKSPACE_ROOT,
        "trajectory_bundle",
        "classic_callback_adapter.jl",
    ),
)
using .ClassicCallbackAdapter
include("all_site_parity.jl")
using .ClassicAllSiteParity

const POLICY_INVENTORY =
    joinpath(WORKSPACE_ROOT, "all_sites", "site_policy_inventory.toml")
const SITE_METRICS =
    joinpath(WORKSPACE_ROOT, "process_stress_matrix", "site_metrics.toml")
const TOLERANCE_CONTRACT =
    joinpath(WORKSPACE_ROOT, "process_stress_matrix", "tolerances.toml")
const TRAJECTORY_SCHEMA =
    joinpath(WORKSPACE_ROOT, "trajectory_bundle", "schema.toml")

@testset "real GF-Guy seasonal archive parity" begin
    archive = joinpath(ARCHIVE_ROOT, "GF-Guy.tar")
    receipt = joinpath(ARCHIVE_ROOT, "GF-Guy.receipt.toml")
    @test sha256_file(archive) == GF_GUY_ARCHIVE_SHA256
    @test sha256_file(receipt) == GF_GUY_RECEIPT_SHA256

    inventory = load_campaign_inventory(POLICY_INVENTORY, SITE_METRICS)
    schema = load_expanded_schema(TRAJECTORY_SCHEMA)
    tolerances = load_tolerance_contract(
        TOLERANCE_CONTRACT,
        schema;
        evidence_root = evidence_root_from_env(),
    )
    package = (; site = "GF-Guy", archive, receipt)
    result = consume_site_archive(
        package,
        inventory,
        TRAJECTORY_SCHEMA,
        verify_replay_acceptance,
        classic_callback_transition,
        free_replay;
        tolerances,
    )

    @test result.ok
    @test result.replay.day_one_state_exact
    @test result.replay.day_one_flux_within_tolerance
    @test result.tolerance_contract_sha256 == tolerances.sha256
    @test result.evaluation.state_ok
    @test result.evaluation.flux_ok
    @test result.evaluation.budget_ok
    @test result.evaluation.drift_ok
    @test result.replay.initialization_count == 1
    @test result.replay.recurrent_state_replacements == 0
    @test length(result.steps) == 366
    @test result.replay.max_state_error ==
          maximum(values(result.achieved_errors.state); init = 0.0)
    @test result.replay.max_flux_error ==
          maximum(values(result.achieved_errors.flux); init = 0.0)
    @test all(
        result.achieved_errors.state[name] <= tolerances.state[name] for
        name in keys(tolerances.state)
    )
    @test all(
        result.achieved_errors.flux[name] <= tolerances.flux[name] for
        name in keys(tolerances.flux)
    )
    @test result.achieved_errors.budget["carbon_closure"] ==
          result.max_carbon_closure
    @test result.achieved_errors.drift["accumulated_drift"] ==
          abs(result.accumulated_drift)
    @test result.activity.inactive_pathways ==
          ["competition", "disturbance", "harvest", "land_use", "pool_clamping"]
    @test Set(keys(result.max_state_errors)) == Set((
        "reference.after_pool_update_litrmass",
        "reference.after_pool_update_soilcmas",
        "reference.before_turbation_litrmass",
        "reference.before_turbation_soilcmas",
        "reference.post_litrmass",
        "reference.post_soilcmas",
    ))
    @test Set(keys(result.max_flux_errors)) ==
          Set(first.(ClassicFreeReplay.FREE_REPLAY_AUDIT_SHAPES))
end
