using Test
import ClimaLand
import SHA
import TOML

const PROCESS_MATRIX_DIRECTORY = @__DIR__
const PROCESS_TRAJECTORY_DIRECTORY =
    joinpath(@__DIR__, "..", "trajectory_bundle")
const PROCESS_TRAJECTORY_SCHEMA =
    joinpath(PROCESS_TRAJECTORY_DIRECTORY, "schema.toml")

if !isdefined(Main, :ClassicTrajectoryBundle)
    include(joinpath(PROCESS_TRAJECTORY_DIRECTORY, "trajectory_bundle.jl"))
end
if !isdefined(Main, :ClassicToleranceContract)
    include(joinpath(PROCESS_TRAJECTORY_DIRECTORY, "tolerance_contract.jl"))
end
if !isdefined(Main, :ClassicFreeReplay)
    include(joinpath(PROCESS_TRAJECTORY_DIRECTORY, "free_replay.jl"))
end

if !isdefined(Main, :ClassicCallbackAdapter)
    include(
        joinpath(PROCESS_TRAJECTORY_DIRECTORY, "classic_callback_adapter.jl"),
    )
end
include("matrix_execution.jl")
using .ClassicMatrixExecution

function write_toml_fixture(path, table)
    open(path, "w") do io
        TOML.print(io, table; sorted = true)
    end
    return path
end

function valid_archive_receipt(site, archive, schema_hash)
    return Dict{String, Any}(
        "schema_version" => 1,
        "site" => site,
        "status" => "complete",
        "reference_kind" => "fresh_local_fortran",
        "oracle_contract" => "stage_b_v5",
        "synthetic_data_used" => false,
        "complete_seasonal_cycle" => true,
        "step_count" => 365,
        "archive_path" => abspath(archive),
        "archive_sha256" => bytes2hex(open(SHA.sha256, archive)),
        "archive_bytes" => filesize(archive),
        "trajectory_schema_sha256" => schema_hash,
        "capture_receipt_sha256" => repeat("a", 64),
        "activity_report_sha256" => repeat("b", 64),
        "missing_fields" => String[],
        "inactive_fields" => ["driver.pre_resp_competition_delta_litter"],
        "artifact_policy" => "external_only",
    )
end

@testset "canonical independent archive manifest is hash-bound" begin
    sites = ["GF-Guy", "SD-Dem", "US-MMS", "CA-Cbo"]
    mktempdir() do directory
        records = Dict{String, Any}[]
        for site in sites
            archive = joinpath(directory, site * ".tar")
            receipt = joinpath(directory, site * ".receipt.toml")
            write(archive, site * " archive")
            write(receipt, site * " receipt")
            push!(
                records,
                Dict(
                    "site" => site,
                    "archive_path" => abspath(archive),
                    "archive_sha256" => bytes2hex(open(SHA.sha256, archive)),
                    "receipt_path" => abspath(receipt),
                    "receipt_sha256" => bytes2hex(open(SHA.sha256, receipt)),
                ),
            )
        end
        document = Dict("schema_version" => 1, "site" => records)
        path =
            write_toml_fixture(joinpath(directory, "archives.toml"), document)
        loaded = load_archive_manifest(path, sites)
        @test loaded.sites == sites
        @test Set(keys(loaded.archives)) == Set(sites)
        @test loaded.sha256 == bytes2hex(open(SHA.sha256, path))

        forged = deepcopy(document)
        first(forged["site"])["archive_sha256"] = repeat("f", 64)
        write_toml_fixture(path, forged)
        @test_throws ArgumentError load_archive_manifest(path, sites)

        missing = deepcopy(document)
        pop!(missing["site"])
        write_toml_fixture(path, missing)
        @test_throws ArgumentError load_archive_manifest(path, sites)

        extra = deepcopy(document)
        push!(extra["site"], deepcopy(first(extra["site"])))
        extra["site"][end]["site"] = "DE-Hai"
        write_toml_fixture(path, extra)
        @test_throws ArgumentError load_archive_manifest(path, sites)
    end
end

@testset "real four-site archive inventory and receipt gate" begin
    matrix = TOML.parsefile(joinpath(@__DIR__, "selection_matrix.toml"))
    sites = selected_matrix_sites(matrix)
    @test sites == ["GF-Guy", "SD-Dem", "US-MMS", "CA-Cbo"]
    schema_hash = bytes2hex(open(SHA.sha256, PROCESS_TRAJECTORY_SCHEMA))

    mktempdir() do directory
        for site in sites
            archive = joinpath(directory, site * ".tar")
            write(archive, site)
            receipt = valid_archive_receipt(site, archive, schema_hash)
            write_toml_fixture(
                joinpath(directory, site * ".receipt.toml"),
                receipt,
            )
        end
        inventory = discover_matrix_archives(directory, sites)
        @test Set(keys(inventory)) == Set(sites)
        @test all(
            validate_site_archive_receipt(
                paths.receipt,
                paths.archive,
                site,
                schema_hash,
            )["status"] == "complete" for (site, paths) in inventory
        )

        extra = joinpath(directory, "DE-Hai.tar")
        write(extra, "extra")
        @test_throws ArgumentError discover_matrix_archives(directory, sites)
        rm(extra)

        receipt_path = inventory["GF-Guy"].receipt
        receipt = TOML.parsefile(receipt_path)
        receipt["synthetic_data_used"] = true
        write_toml_fixture(receipt_path, receipt)
        @test_throws ArgumentError validate_site_archive_receipt(
            receipt_path,
            inventory["GF-Guy"].archive,
            "GF-Guy",
            schema_hash,
        )
    end
end

@testset "field activity is explicit and measured" begin
    schema = Main.ClassicTrajectoryBundle.load_bundle_schema(
        PROCESS_TRAJECTORY_SCHEMA,
    )
    records = [
        Dict(
            "name" => field["name"],
            "present" => true,
            "active" => false,
            "nonzero_count" => 0,
            "maximum_absolute_value" => 0.0,
        ) for field in schema["field"]
    ]
    mktempdir() do directory
        path = write_toml_fixture(
            joinpath(directory, "field_activity.toml"),
            Dict("schema_version" => 1, "field" => records),
        )
        activity = validate_field_activity(path, schema)
        @test length(activity.inactive_pathways) > 0
        @test isempty(activity.active_pathways)

        report = TOML.parsefile(path)
        first(report["field"])["active"] = true
        write_toml_fixture(path, report)
        @test_throws ArgumentError validate_field_activity(path, schema)

        report = Dict("schema_version" => 1, "field" => records[2:end])
        write_toml_fixture(path, report)
        @test_throws ArgumentError validate_field_activity(path, schema)
    end
end


@testset "per-field tolerances and call-snapshot localization fail closed" begin
    schema = Main.ClassicTrajectoryBundle.load_bundle_schema(
        PROCESS_TRAJECTORY_SCHEMA,
    )
    state_names = Set(
        field["name"] for
        field in schema["field"] if field["section"] == "reference_state"
    )
    flux_names = Set(
        field["name"] for
        field in schema["field"] if field["section"] == "audit_diagnostics"
    )
    tolerances = (;
        state = Dict(name => 1.0e-12 for name in state_names),
        flux = Dict(name => 1.0e-12 for name in flux_names),
        budget = Dict("carbon_closure" => 1.0e-12),
        drift = Dict("accumulated_drift" => 1.0e-12),
    )

    state_errors = Dict(name => 0.0 for name in keys(tolerances.state))
    state_errors["reference.after_pool_update_litrmass"] = 1.0e-6
    step = (;
        index = 7,
        time_start = "2000-01-07",
        time_end = "2000-01-08",
        state_errors,
        flux_errors = Dict(name => 0.0 for name in keys(tolerances.flux)),
        carbon_closure = 0.0,
        accumulated_drift = 0.0,
        roundoff_ok = true,
        roundoff_residual = 0.0,
        roundoff_threshold = 1.0e-12,
        roundoff_bound = 0.0,
        roundoff_term_count = 1,
        roundoff_term_scale = 0.0,
        roundoff_term_scale_upper = 0.0,
        roundoff_ratio = 0.0,
    )
    report = (;
        steps = [step],
        max_state_errors = Dict(
            name => step.state_errors[name] for name in keys(tolerances.state)
        ),
        max_flux_errors = Dict(name => 0.0 for name in keys(tolerances.flux)),
        max_carbon_closure = 0.0,
        accumulated_drift = 0.0,
        max_naive_carbon_closure = 0.0,
        naive_accumulated_drift = 0.0,
        closure_ok = true,
        drift_ok = true,
        drift_roundoff_residual = 0.0,
        drift_roundoff_threshold = 1.0e-12,
        drift_roundoff_bound = 0.0,
        drift_roundoff_term_count = 1,
        drift_roundoff_term_scale = 0.0,
        drift_roundoff_term_scale_upper = 0.0,
        drift_roundoff_ratio = 0.0,
        initialization_count = 1,
        recurrent_state_replacements = 0,
        day_one_exact = false,
    )
    evaluation = evaluate_replay_report(report, tolerances, schema)
    @test !evaluation.ok
    failure = only(evaluation.failure_localization)
    @test failure["field"] == "reference.after_pool_update_litrmass"
    @test failure["step_index"] == 7
    @test failure["call_snapshot"] == "after_pool_update"
    @test failure["call_snapshot_payload"] == "payloads/step_00000007"

    drift_step = merge(step, (; accumulated_drift = 2.0e-12,))
    drift_report = merge(
        report,
        (;
            steps = [drift_step],
            max_state_errors = Dict(
                name => 0.0 for name in keys(tolerances.state)
            ),
            accumulated_drift = 2.0e-12,
            drift_ok = false,
            drift_roundoff_residual = 2.0e-12,
            drift_roundoff_threshold = 1.0e-12,
            drift_roundoff_ratio = 2.0,
        ),
    )
    drift_evaluation = evaluate_replay_report(drift_report, tolerances, schema)
    @test !drift_evaluation.ok
    @test drift_evaluation.state_ok
    @test drift_evaluation.budget_ok
    @test !drift_evaluation.drift_ok
    @test only(drift_evaluation.failure_localization)["family"] == "drift"

    analytic_step = merge(
        step,
        (;
            carbon_closure = 1.0e-6,
            roundoff_residual = 2.0e-12,
            roundoff_bound = 3.0e-12,
            roundoff_threshold = 3.0e-12,
            roundoff_term_scale = 10_000.0,
            roundoff_term_scale_upper = 10_001.0,
            roundoff_ratio = 2 / 3,
        ),
    )
    analytic_report = merge(
        report,
        (;
            steps = [analytic_step],
            max_state_errors = Dict(
                name => 0.0 for name in keys(tolerances.state)
            ),
            max_carbon_closure = 2.0e-12,
            max_naive_carbon_closure = 1.0e-6,
        ),
    )
    analytic_evaluation =
        evaluate_replay_report(analytic_report, tolerances, schema)
    @test analytic_evaluation.ok
    @test analytic_evaluation.budget_ok

    injected_step = merge(
        analytic_step,
        (;
            roundoff_ok = false,
            roundoff_residual = 4.0e-12,
            roundoff_ratio = 4 / 3,
        ),
    )
    injected_report = merge(
        analytic_report,
        (;
            steps = [injected_step],
            max_carbon_closure = 4.0e-12,
            closure_ok = false,
        ),
    )
    injected_evaluation =
        evaluate_replay_report(injected_report, tolerances, schema)
    @test !injected_evaluation.budget_ok
    budget_failure = only(injected_evaluation.failure_localization)
    @test budget_failure["error"] == 4.0e-12
    @test budget_failure["tolerance"] == 3.0e-12
    @test budget_failure["analytic_bound"] == 3.0e-12
end
