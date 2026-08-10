@testset "external-root checks resolve symlinks" begin
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
        mkpath(repository)
        disguised_work = joinpath(directory, "external-looking-work")
        symlink(repository, disguised_work)

        @test_throws ArgumentError run_extraction_plan(
            plan_path,
            disguised_work,
            joinpath(directory, "archives"),
            synthetic_capture!;
            repository_root = repository,
        )
        @test isempty(readdir(repository))
    end
end
