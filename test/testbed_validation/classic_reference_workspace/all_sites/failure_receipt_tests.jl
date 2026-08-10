using Test
import TOML

include("extraction.jl")
using .ClassicAllSitesExtraction

const FAILURE_POLICY = joinpath(@__DIR__, "site_policy_inventory.toml")
const FAILURE_SCHEMA =
    joinpath(@__DIR__, "..", "trajectory_bundle", "schema.toml")

struct SyntheticReplayFailure <: Exception
    receipt_path::String
    report::NamedTuple
end

Base.showerror(io::IO, ::SyntheticReplayFailure) =
    print(io, "seasonal free replay failed")

@testset "replay failures preserve structured diagnostics before cleanup" begin
    mktempdir() do directory
        policy = TOML.parsefile(FAILURE_POLICY)
        policy["site"] = policy["site"][1:1]
        policy["expected_site_count"] = 1
        policy_path = joinpath(directory, "policy.toml")
        open(policy_path, "w") do io
            TOML.print(io, policy; sorted = true)
        end
        plan_path = joinpath(directory, "plan.toml")
        build_extraction_plan(
            plan_path,
            policy_path,
            FAILURE_SCHEMA;
            expected_site_count = 1,
        )
        repository = joinpath(directory, "repository")
        archives = joinpath(directory, "archives")
        mkpath(repository)
        callback = function (site, workspace, required_fields)
            receipt_path = joinpath(workspace, "replay_failure_receipt.toml")
            write(receipt_path, "status = \"fail\"\n")
            report = (;
                day_one_exact = false,
                day_one_state_exact = false,
                day_one_flux_within_tolerance = true,
                state_ok = false,
                flux_ok = true,
                closure_ok = true,
                drift_ok = false,
                max_state_errors = Dict("reference.post_litrmass" => 2.0e-12),
                max_flux_errors = Dict("audit.hetrores" => 3.0e-15),
                max_carbon_closure = 4.0e-15,
                naive_accumulated_drift = 5.1e-12,
                accumulated_drift = 5.0e-12,
                drift_algorithm = "neumaier_signed_primitive_ledger",
                drift_algorithm_version = 1,
                drift_oracle_conversion = "Float64 primitive terms; BigFloat summation oracle",
                drift_term_count = 42,
                drift_term_scale = 17.5,
            )
            throw(SyntheticReplayFailure(receipt_path, report))
        end

        report = run_extraction_plan(
            plan_path,
            joinpath(directory, "work"),
            archives,
            callback;
            repository_root = repository,
        )
        site = only(TOML.parsefile(plan_path)["site"])["name"]
        failure = TOML.parsefile(joinpath(archives, site * ".failure.toml"))
        preserved = joinpath(archives, site * ".replay-failure.toml")

        @test report.failed_count == 1
        @test failure["cause"]["message"] == "seasonal free replay failed"
        @test occursin("SyntheticReplayFailure", failure["cause"]["type"])
        @test failure["failure_phase"] == "replay_acceptance"
        @test failure["failed_gates"] ==
              ["day_one_state_exact", "state", "drift"]
        @test failure["replay_receipt_path"] == abspath(preserved)
        @test failure["replay_receipt_sha256"] == sha256_path(preserved)
        @test failure["max_state_errors"]["reference.post_litrmass"] == 2.0e-12
        @test failure["max_flux_errors"]["audit.hetrores"] == 3.0e-15
        @test failure["max_carbon_closure"] == 4.0e-15
        @test failure["naive_accumulated_drift"] == 5.1e-12
        @test failure["accumulated_drift"] == 5.0e-12
        @test failure["compensated_accumulated_drift"] == 5.0e-12
        @test failure["drift_algorithm"] == "neumaier_signed_primitive_ledger"
        @test failure["drift_algorithm_version"] == 1
        @test failure["drift_oracle_conversion"] ==
              "Float64 primitive terms; BigFloat summation oracle"
        @test failure["drift_term_count"] == 42
        @test failure["drift_term_scale"] == 17.5
        @test !isdir(joinpath(directory, "work", site * ".capture"))
    end
end
