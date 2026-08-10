@testset "existing campaign receipts are never overwritten" begin
    mktempdir() do directory
        policy = TOML.parsefile(EXTRACTION_POLICY)
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
            TRAJECTORY_SCHEMA;
            expected_site_count = 1,
        )
        repository = joinpath(directory, "repository")
        work = joinpath(directory, "work")
        archives = joinpath(directory, "archives")
        mkpath(repository)
        mkpath(archives)
        summary = joinpath(archives, "campaign_extraction_receipt.toml")
        write(summary, "sentinel receipt")

        @test_throws ArgumentError run_extraction_plan(
            plan_path,
            work,
            archives,
            synthetic_capture!;
            repository_root = repository,
        )
        @test read(summary, String) == "sentinel receipt"
        @test !ispath(work)
        @test length(readdir(archives)) == 1
    end
end
