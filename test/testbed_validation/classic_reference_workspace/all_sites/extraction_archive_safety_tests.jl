@testset "existing external archives are never overwritten or deleted" begin
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
        site = only(policy["site"])["name"]
        archive = joinpath(archives, site * ".tar")
        write(archive, "sentinel archive")

        report = run_extraction_plan(
            plan_path,
            work,
            archives,
            synthetic_capture!;
            repository_root = repository,
        )

        @test report.failed_count == 1
        @test read(archive, String) == "sentinel archive"
        @test isempty(readdir(work))
    end
end
