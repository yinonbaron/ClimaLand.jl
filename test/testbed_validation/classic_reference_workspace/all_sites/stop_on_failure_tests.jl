@testset "campaign can stop immediately after the first site failure" begin
    mktempdir() do directory
        policy = TOML.parsefile(EXTRACTION_POLICY)
        policy["site"] = policy["site"][1:2]
        policy["expected_site_count"] = 2
        policy_path = joinpath(directory, "policy.toml")
        open(policy_path, "w") do io
            TOML.print(io, policy; sorted = true)
        end
        plan_path = joinpath(directory, "plan.toml")
        build_extraction_plan(
            plan_path,
            policy_path,
            TRAJECTORY_SCHEMA;
            expected_site_count = 2,
        )
        repository = joinpath(directory, "repository")
        archives = joinpath(directory, "archives")
        mkpath(repository)
        calls = String[]
        report = run_extraction_plan(
            plan_path,
            joinpath(directory, "work"),
            archives,
            (site, workspace, required_fields) -> begin
                push!(calls, site)
                error("first site failed")
            end;
            repository_root = repository,
            stop_on_failure = true,
        )
        sites = getindex.(TOML.parsefile(plan_path)["site"], "name")
        summary = TOML.parsefile(report.summary_path)

        @test calls == sites[1:1]
        @test report.site_count == 1
        @test report.failed_count == 1
        @test report.packed_count == 0
        @test summary["site_count"] == 1
        @test summary["site"][1]["name"] == first(sites)
        @test isfile(joinpath(archives, first(sites) * ".failure.toml"))
        @test !ispath(joinpath(archives, sites[2] * ".failure.toml"))
    end
end
