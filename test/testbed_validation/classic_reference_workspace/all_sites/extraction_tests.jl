using Test
import SHA
import TOML

include("extraction.jl")
using .ClassicAllSitesExtraction

const EXTRACTION_POLICY = joinpath(@__DIR__, "site_policy_inventory.toml")
const TRAJECTORY_SCHEMA =
    joinpath(@__DIR__, "..", "trajectory_bundle", "schema.toml")

@testset "all-site extraction plan binds policy and trajectory contracts" begin
    mktempdir() do directory
        plan_path = joinpath(directory, "extraction_plan.toml")
        build_extraction_plan(plan_path, EXTRACTION_POLICY, TRAJECTORY_SCHEMA)
        plan = TOML.parsefile(plan_path)

        @test plan["schema_version"] == 1
        @test plan["site_count"] == 59
        @test length(plan["site"]) == 59
        @test all(
            site["redistribution_status"] == "blocked" for site in plan["site"]
        )
        @test all(
            site["artifact_policy"] == "external_only" for site in plan["site"]
        )
        @test all(
            startswith(site["policy_reference"], "https://") for
            site in plan["site"]
        )
        @test all(!isempty(site["unresolved_reason"]) for site in plan["site"])
        @test plan["trajectory_schema_sha256"] == sha256_path(TRAJECTORY_SCHEMA)
        @test length(plan["required_driver_field"]) == 20
        @test length(plan["required_bundle_field"]) == 70
        @test "driver.tbar" in plan["required_driver_field"]
        @test "driver.post_resp_disturbance_delta_soil" in
              plan["required_driver_field"]
    end
end
