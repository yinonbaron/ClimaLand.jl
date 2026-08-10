import Tar

@testset "packed site retains its activity and capture receipts" begin
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

        report = run_extraction_plan(
            plan_path,
            work,
            archives,
            synthetic_capture!;
            repository_root = repository,
        )
        archive = joinpath(archives, only(policy["site"])["name"] * ".tar")
        members = Set(header.path for header in Tar.list(archive))

        @test report.packed_count == 1
        @test "capture_receipt.toml" in members
        @test "field_activity.toml" in members
        @test "packed-input.bin" in members
    end
end
