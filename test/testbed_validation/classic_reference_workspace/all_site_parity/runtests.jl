module ClassicAllSiteParityTests

using Test
import TOML
using Dates
import Tar

include(joinpath(@__DIR__, "..", "trajectory_bundle", "trajectory_bundle.jl"))
using .ClassicTrajectoryBundle
include(joinpath(@__DIR__, "..", "trajectory_bundle", "tolerance_contract.jl"))
using .ClassicToleranceContract
include(joinpath(@__DIR__, "..", "trajectory_bundle", "free_replay.jl"))
using .ClassicFreeReplay
include(
    joinpath(
        @__DIR__,
        "..",
        "trajectory_bundle",
        "classic_callback_adapter.jl",
    ),
)
using .ClassicCallbackAdapter
include("all_site_parity.jl")
using .ClassicAllSiteParity
include("all_site_report.jl")
using .ClassicAllSiteReport
include(joinpath(@__DIR__, "..", "trajectory_bundle", "test_helpers.jl"))

const WORKSPACE_ROOT = normpath(joinpath(@__DIR__, ".."))
const POLICY_INVENTORY =
    joinpath(WORKSPACE_ROOT, "all_sites", "site_policy_inventory.toml")
const SITE_METRICS =
    joinpath(WORKSPACE_ROOT, "process_stress_matrix", "site_metrics.toml")
const TRAJECTORY_SCHEMA =
    joinpath(WORKSPACE_ROOT, "trajectory_bundle", "schema.toml")
include("all_site_report_tests.jl")

include("compact_fixture_tests.jl")
include("real_gf_guy_root_tests.jl")
@testset "campaign inventory is exactly the canonical 59 sites" begin
    inventory = load_campaign_inventory(POLICY_INVENTORY, SITE_METRICS)
    @test length(inventory.sites) == 59
    @test length(unique(inventory.sites)) == 59
    @test inventory.policy_sha256 == sha256_file(POLICY_INVENTORY)
    @test inventory.metrics_sha256 == sha256_file(SITE_METRICS)

    mktempdir() do directory
        truncated = TOML.parsefile(POLICY_INVENTORY)
        pop!(truncated["site"])
        truncated["expected_site_count"] = 58
        truncated_path = joinpath(directory, "truncated.toml")
        open(truncated_path, "w") do io
            TOML.print(io, truncated; sorted = true)
        end
        @test_throws ArgumentError load_campaign_inventory(
            truncated_path,
            SITE_METRICS,
        )
    end
end

const VALID_SHA = repeat("a", 64)
const VALID_COMMIT = repeat("b", 40)
function real_provenance()
    return Dict(
        "reference_kind" => "fresh_local_fortran",
        "capture_schema" => "stage_b_v5",
        "synthetic" => false,
        "source_archive_sha256" => VALID_SHA,
        "source_tree_sha256" => VALID_SHA,
        "source_commit" => VALID_COMMIT,
        "instrumented_executable_sha256" => VALID_SHA,
        "instrumentation_patch_sha256" => VALID_SHA,
        "snapshot_schema_sha256" => VALID_SHA,
        "parameter_namelist_sha256" => VALID_SHA,
        "site_job_options_sha256" => VALID_SHA,
        "site_initial_condition_sha256" => VALID_SHA,
        "completion_ledger_sha256" => VALID_SHA,
        "time_index_sha256" => VALID_SHA,
        "nonperturbation_receipt_sha256" => VALID_SHA,
        "oracle_receipt_sha256" => VALID_SHA,
        "oracle_output_manifest_sha256" => VALID_SHA,
        "execution_receipt_sha256" => VALID_SHA,
        "sealed_event_index_sha256" => VALID_SHA,
        "replay_receipt_sha256" => VALID_SHA,
    )
end

@testset "real acceptance requires fresh-local-v5 provenance" begin
    @test validate_real_provenance(real_provenance())
    synthetic = real_provenance()
    synthetic["synthetic"] = true
    @test_throws ArgumentError validate_real_provenance(synthetic)
    incomplete = real_provenance()
    delete!(incomplete, "oracle_receipt_sha256")
    @test_throws ArgumentError validate_real_provenance(incomplete)
end

function activity_document()
    schema = load_expanded_schema(TRAJECTORY_SCHEMA)
    fields = schema["field"]
    records = [
        Dict(
            "name" => field["name"],
            "present" => true,
            "active" => false,
            "reason" => "observed_zero",
            "nonzero_count" => 0,
            "maximum_absolute_value" => 0.0,
        ) for field in fields
    ]
    by_name = Dict(record["name"] => record for record in records)
    for name in (
        "audit.ltresveg",
        "audit.scresveg",
        "audit.hetrsveg",
        "audit.litres",
        "audit.socres",
        "audit.hetrores",
        "audit.soilresp",
        "audit.humtrsvg",
        "audit.humiftrs",
    )
        by_name[name]["active"] = true
        by_name[name]["reason"] = "observed_nonzero"
        by_name[name]["nonzero_count"] = 1
        by_name[name]["maximum_absolute_value"] = 1.0
    end
    return Dict(
        "schema_version" => 1,
        "field_count" => length(records),
        "field" => records,
    )
end

@testset "inactive Stage B pathways are explicit evidence" begin
    report = classify_activity(activity_document(), TRAJECTORY_SCHEMA)
    @test "heterotrophic_respiration" in report.active_pathways
    @test "competition" in report.inactive_pathways
    @test "turbation" in report.inactive_pathways

    missing = activity_document()
    pop!(missing["field"])
    @test_throws ArgumentError classify_activity(missing, TRAJECTORY_SCHEMA)
    inconsistent = activity_document()
    record = only(
        filter(
            item -> item["name"] == "audit.turbation_delta_litter",
            inconsistent["field"],
        ),
    )
    record["nonzero_count"] = 1
    @test_throws ArgumentError classify_activity(
        inconsistent,
        TRAJECTORY_SCHEMA,
    )
end
@testset "accepted callback advances sequentially without reference replacement" begin
    replay = callback_replay()
    transition = classic_callback_transition(replay)
    report = free_replay(replay, transition; atol = 0.0, rtol = 0.0)
    @test report.ok
    @test report.initialization_count == 1
    @test report.recurrent_state_replacements == 0
    @test length(report.steps) == 2
    @test all(iszero, values(report.max_state_errors))
    @test all(iszero, values(report.max_flux_errors))
    @test report.max_carbon_closure == 0.0
    @test report.accumulated_drift == 0.0
end

@testset "archive inventory requires all and only 59 site packages" begin
    inventory = load_campaign_inventory(POLICY_INVENTORY, SITE_METRICS)
    mktempdir() do directory
        for site in inventory.sites
            write(joinpath(directory, site * ".tar"), "archive")
            write(joinpath(directory, site * ".receipt.toml"), "receipt")
        end
        packages = validate_archive_set(directory, inventory)
        @test length(packages) == 59
        @test getindex.(packages, :site) == inventory.sites

        missing = first(inventory.sites)
        rm(joinpath(directory, missing * ".tar"))
        @test_throws ArgumentError validate_archive_set(directory, inventory)
        write(joinpath(directory, missing * ".tar"), "archive")
        write(joinpath(directory, "EXTRA.tar"), "archive")
        @test_throws ArgumentError validate_archive_set(directory, inventory)
    end
end

@testset "archive inventory permits the exact campaign controls" begin
    inventory = load_campaign_inventory(POLICY_INVENTORY, SITE_METRICS)
    mktempdir() do directory
        for site in inventory.sites
            write(joinpath(directory, site * ".tar"), "archive")
            write(joinpath(directory, site * ".receipt.toml"), "receipt")
        end
        controls = (
            "campaign_completion_receipt.v2.toml",
            "campaign_extraction_receipt.toml",
            "campaign_package_inventory.v2.toml",
        )
        for control in controls
            write(joinpath(directory, control), "control")
        end
        @test length(validate_archive_set(directory, inventory)) == 59
        rm(joinpath(directory, first(controls)))
        @test_throws ArgumentError validate_archive_set(directory, inventory)
    end
end

@testset "site TAR members are safe and contract-scoped" begin
    mktempdir() do directory
        source = joinpath(directory, "source")
        mkpath(joinpath(source, "payloads", "fixed"))
        mkpath(joinpath(source, "evidence"))
        write(joinpath(source, "manifest.toml"), "schema_version = 1")
        write(joinpath(source, "field_activity.toml"), "schema_version = 1")
        write(joinpath(source, "capture_receipt.toml"), "schema_version = 1")
        write(joinpath(source, "payloads", "fixed", "field.bin"), "payload")
        write(joinpath(source, "evidence", "capture_receipt.toml"), "evidence")
        archive = joinpath(directory, "safe.tar")
        Tar.create(source, archive)
        headers = validate_archive_headers(archive)
        @test count(header -> header.type == :file, headers) == 5

        unsafe = joinpath(directory, "unsafe")
        mkpath(unsafe)
        write(joinpath(unsafe, "manifest.toml"), "schema_version = 1")
        symlink("../outside", joinpath(unsafe, "escape"))
        unsafe_archive = joinpath(directory, "unsafe.tar")
        Tar.create(unsafe, unsafe_archive)
        @test_throws ArgumentError validate_archive_headers(unsafe_archive)
    end
end

@testset "exact v5 nonperturbation evidence is SHA-bound" begin
    mktempdir() do directory
        path = joinpath(directory, "nonperturbation_receipt.toml")
        evidence = Dict(
            "schema_version" => 1,
            "site" => "GF-Guy",
            "reference_kind" => "fresh_local_fortran",
            "candidate_kind" => "instrumented_stage_b_v5",
            "synthetic_data_used" => false,
            "result" => "pass",
            "criteria" => "exact values, coordinates, masks, dimensions, types, and units",
            "compared_files" => 57,
            "failed_files" => 0,
            "record_count_per_daily_file" => 4018,
        )
        open(path, "w") do io
            TOML.print(io, evidence; sorted = true)
        end
        digest = sha256_file(path)
        @test validate_nonperturbation_evidence(path, "GF-Guy", digest, 366) ==
              evidence
        @test_throws ArgumentError validate_nonperturbation_evidence(
            path,
            "GF-Guy",
            VALID_SHA,
            366,
        )
        @test_throws ArgumentError validate_nonperturbation_evidence(
            path,
            "GF-Guy",
            digest,
            5000,
        )
    end
end

@testset "all 59 packages are consumed sequentially" begin
    inventory = load_campaign_inventory(POLICY_INVENTORY, SITE_METRICS)
    mktempdir() do directory
        for site in inventory.sites
            write(joinpath(directory, site * ".tar"), "archive")
            write(joinpath(directory, site * ".receipt.toml"), "receipt")
        end
        observed = String[]
        campaign = run_all_site_parity(directory, inventory) do package
            push!(observed, package.site)
            return (;
                site = package.site,
                ok = true,
                evidence_complete = true,
                stage_b_status = "active",
                stage_b_parity = true,
            )
        end
        @test campaign.ok
        @test campaign.evidence_complete
        @test campaign.active_stage_b_parity_complete
        @test campaign.active_site_count == 59
        @test campaign.inactive_site_count == 0
        @test campaign.active_stage_b_parity_pass_count == 59
        @test campaign.site_count == 59
        @test campaign.execution_order == "sequential"
        @test observed == inventory.sites
    end
end

@testset "inactive evidence is not counted as Stage-B parity" begin
    inventory = load_campaign_inventory(POLICY_INVENTORY, SITE_METRICS)
    inactive_site = first(inventory.sites)
    mktempdir() do directory
        for site in inventory.sites
            write(joinpath(directory, site * ".tar"), "archive")
            write(joinpath(directory, site * ".receipt.toml"), "receipt")
        end
        campaign = run_all_site_parity(directory, inventory) do package
            inactive = package.site == inactive_site
            return (;
                site = package.site,
                ok = true,
                evidence_complete = true,
                stage_b_status = inactive ? "inactive" : "active",
                stage_b_parity = !inactive,
            )
        end
        @test campaign.ok
        @test campaign.evidence_complete
        @test campaign.active_stage_b_parity_complete
        @test campaign.active_site_count == 58
        @test campaign.inactive_site_count == 1
        @test campaign.active_stage_b_parity_pass_count == 58
    end
end

@testset "structural trajectory binds gaps and seasonal shifts" begin
    mktempdir() do directory
        valid = joinpath(directory, "valid")
        write_synthetic_bundle(valid, TRAJECTORY_SCHEMA; step_count = 2)
        receipt = Dict(
            "step_count" => 2,
            "capture_year" => 2000,
            "capture_event_count" => 2,
            "capture_source_calendar" => "standard",
            "capture_first_time" => "2000-01-01T00:00:00",
            "capture_last_time" => "2000-01-02T00:00:00",
            "capture_next_year_start" => "2000-01-03T00:00:00",
        )
        @test_throws ArgumentError validate_structural_trajectory(
            valid,
            TRAJECTORY_SCHEMA,
            receipt,
            "DE-Hai",
        ).ok

        gap = joinpath(directory, "gap")
        cp(valid, gap)
        rewrite_manifest(gap) do manifest
            manifest["step"][2]["time_start"] = "2000-01-04T00:00:00"
            manifest["step"][2]["time_end"] = "2000-01-05T00:00:00"
        end
        @test_throws ArgumentError validate_structural_trajectory(
            gap,
            TRAJECTORY_SCHEMA,
            receipt,
            "DE-Hai",
        )

        shifted = joinpath(directory, "shifted")
        cp(valid, shifted)
        rewrite_manifest(shifted) do manifest
            for step in manifest["step"]
                step["time_start"] =
                    string(DateTime(step["time_start"]) + Day(1))
                step["time_end"] = string(DateTime(step["time_end"]) + Day(1))
            end
        end
        @test_throws ArgumentError validate_structural_trajectory(
            shifted,
            TRAJECTORY_SCHEMA,
            receipt,
            "DE-Hai",
        )

        seasonal = joinpath(directory, "seasonal")
        write_synthetic_bundle(
            seasonal,
            TRAJECTORY_SCHEMA;
            step_count = 365,
            shared_step_payloads = true,
        )
        seasonal_manifest = TOML.parsefile(joinpath(seasonal, "manifest.toml"))
        seasonal_manifest["trajectory"]["site"] = "CA-Mer"
        open(joinpath(seasonal, "manifest.toml"), "w") do io
            TOML.print(io, seasonal_manifest; sorted = true)
        end
        seasonal_receipt = Dict(
            "step_count" => 365,
            "capture_year" => 2001,
            "capture_event_count" => 365,
            "capture_source_calendar" => "standard",
            "capture_first_time" => "2001-01-01T00:00:00",
            "capture_last_time" => "2001-12-31T00:00:00",
            "capture_next_year_start" => "2002-01-01T00:00:00",
        )
        rewrite_manifest(seasonal) do manifest
            for (index, step) in enumerate(manifest["step"])
                start = DateTime(2001, 1, 1) + Day(index - 1)
                step["time_start"] = string(start)
                step["time_end"] = string(start + Day(1))
            end
            manifest["trajectory"]["site"] = "CA-Mer"
        end
        @test validate_structural_trajectory(
            seasonal,
            TRAJECTORY_SCHEMA,
            seasonal_receipt,
            "CA-Mer",
        ).ok
        wrong_year = deepcopy(seasonal_receipt)
        wrong_year["capture_year"] = 2000
        @test_throws ArgumentError validate_structural_trajectory(
            seasonal,
            TRAJECTORY_SCHEMA,
            wrong_year,
            "CA-Mer",
        )
        shifted_receipt = deepcopy(seasonal_receipt)
        shifted_receipt["capture_first_time"] = "2001-01-02T00:00:00"
        shifted_receipt["capture_last_time"] = "2002-01-01T00:00:00"
        shifted_receipt["capture_next_year_start"] = "2002-01-02T00:00:00"
        rewrite_manifest(seasonal) do manifest
            for step in manifest["step"]
                step["time_start"] =
                    string(DateTime(step["time_start"]) + Day(1))
                step["time_end"] = string(DateTime(step["time_end"]) + Day(1))
            end
        end
        @test_throws ArgumentError validate_structural_trajectory(
            seasonal,
            TRAJECTORY_SCHEMA,
            shifted_receipt,
            "CA-Mer",
        )
    end
end

include("inactive_archive_roundtrip_tests.jl")

end
