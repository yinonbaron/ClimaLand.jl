function write_activity_report(
    path,
    fields;
    inactive = String[],
    omitted = String[],
)
    records = [
        Dict(
            "name" => name,
            "present" => name ∉ omitted,
            "active" => name ∉ inactive,
        ) for name in fields if name ∉ omitted
    ]
    open(path, "w") do io
        TOML.print(
            io,
            Dict("schema_version" => 1, "field" => records);
            sorted = true,
        )
    end
end

function synthetic_capture!(site, workspace, required_fields)
    capture = joinpath(workspace, "capture")
    mkpath(capture)
    open(joinpath(capture, "packed-input.bin"), "w") do io
        write(io, codeunits(site))
    end
    write_activity_report(
        joinpath(workspace, "field_activity.toml"),
        required_fields;
        inactive = ["driver.thliq"],
    )
    receipt = Dict(
        "schema_version" => 1,
        "status" => "synthetic",
        "site" => site,
        "complete_seasonal_cycle" => false,
        "step_count" => 2,
        "source_sha256" => repeat("a", 64),
        "execution_sha256" => repeat("b", 64),
        "trajectory_schema_sha256" => sha256_path(TRAJECTORY_SCHEMA),
    )
    open(joinpath(workspace, "capture_receipt.toml"), "w") do io
        TOML.print(io, receipt; sorted = true)
    end
    return nothing
end

@testset "site extraction is sequential and packs immediately" begin
    mktempdir() do directory
        policy = TOML.parsefile(EXTRACTION_POLICY)
        policy["site"] = policy["site"][1:3]
        policy["expected_site_count"] = 3
        policy_path = joinpath(directory, "policy.toml")
        open(policy_path, "w") do io
            TOML.print(io, policy; sorted = true)
        end
        plan_path = joinpath(directory, "plan.toml")
        build_extraction_plan(
            plan_path,
            policy_path,
            TRAJECTORY_SCHEMA;
            expected_site_count = 3,
        )
        repository = joinpath(directory, "repository")
        work = joinpath(directory, "external_work")
        archives = joinpath(directory, "external_archives")
        mkpath(repository)
        observed_live_workspaces = Int[]
        capture! = function (site, workspace, required_fields)
            push!(
                observed_live_workspaces,
                count(isdir, joinpath.(Ref(work), readdir(work))),
            )
            synthetic_capture!(site, workspace, required_fields)
        end

        report = run_extraction_plan(
            plan_path,
            work,
            archives,
            capture!;
            repository_root = repository,
        )

        @test report.site_count == 3
        @test report.packed_count == 3
        @test report.failed_count == 0
        @test observed_live_workspaces == [1, 1, 1]
        @test isempty(readdir(work))
        @test sort(filter(name -> endswith(name, ".tar"), readdir(archives))) ==
              sort([
            site["name"] * ".tar" for site in TOML.parsefile(plan_path)["site"]
        ])
        @test all(
            isfile(joinpath(archives, site["name"] * ".receipt.toml")) for
            site in TOML.parsefile(plan_path)["site"]
        )
        receipts = [
            TOML.parsefile(joinpath(archives, site["name"] * ".receipt.toml")) for site in TOML.parsefile(plan_path)["site"]
        ]
        @test all(
            receipt["inactive_fields"] == ["driver.thliq"] for
            receipt in receipts
        )
        @test all(isempty(receipt["missing_fields"]) for receipt in receipts)
        @test all(
            receipt["redistribution_status"] == "blocked" for
            receipt in receipts
        )
        @test all(receipt["real_acceptance"] == false for receipt in receipts)
    end
end

@testset "missing fields fail closed and external roots are enforced" begin
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
        bad_capture! = function (site, workspace, required_fields)
            synthetic_capture!(site, workspace, required_fields)
            write_activity_report(
                joinpath(workspace, "field_activity.toml"),
                required_fields;
                omitted = [first(required_fields)],
            )
        end
        report = run_extraction_plan(
            plan_path,
            joinpath(directory, "work"),
            joinpath(directory, "archives"),
            bad_capture!;
            repository_root = repository,
        )
        @test report.packed_count == 0
        @test report.failed_count == 1
        @test !isempty(only(report.site).missing_fields)

        @test_throws ArgumentError run_extraction_plan(
            plan_path,
            joinpath(repository, "work"),
            joinpath(directory, "outside"),
            bad_capture!;
            repository_root = repository,
        )
    end
end

@testset "site callback exceptions are persisted immediately" begin
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
        archives = joinpath(directory, "archives")
        mkpath(repository)
        result = open(joinpath(directory, "stderr.log"), "w+") do output
            report = redirect_stderr(output) do
                run_extraction_plan(
                    plan_path,
                    joinpath(directory, "work"),
                    archives,
                    (site, workspace, required_fields) ->
                        error("callback failed");
                    repository_root = repository,
                )
            end
            flush(output)
            seekstart(output)
            return (; report, emitted = read(output, String))
        end
        site = only(TOML.parsefile(plan_path)["site"])["name"]
        failure_path = joinpath(archives, site * ".failure.toml")

        @test result.report.failed_count == 1
        @test isfile(failure_path)
        @test TOML.parsefile(failure_path)["issues"] == ["callback failed"]
        @test occursin("$site failed: callback failed", result.emitted)
    end
end
