using Test
import TOML
import Tar

if !isdefined(Main, :ClassicAllSitesExtraction)
    include("extraction.jl")
end
using .ClassicAllSitesExtraction

function resume_fixture(root)
    policy = TOML.parsefile(EXTRACTION_POLICY)
    policy["site"] = policy["site"][1:3]
    policy["expected_site_count"] = 3
    policy_path = joinpath(root, "policy.toml")
    open(policy_path, "w") do io
        TOML.print(io, policy; sorted = true)
    end
    plan_path = joinpath(root, "plan.toml")
    build_extraction_plan(
        plan_path,
        policy_path,
        TRAJECTORY_SCHEMA;
        expected_site_count = 3,
    )
    prefix_policy = deepcopy(policy)
    prefix_policy["site"] = prefix_policy["site"][1:2]
    prefix_policy["expected_site_count"] = 2
    prefix_policy_path = joinpath(root, "prefix_policy.toml")
    open(prefix_policy_path, "w") do io
        TOML.print(io, prefix_policy; sorted = true)
    end
    prefix_plan = joinpath(root, "prefix_plan.toml")
    build_extraction_plan(
        prefix_plan,
        prefix_policy_path,
        TRAJECTORY_SCHEMA;
        expected_site_count = 2,
    )
    repository = joinpath(root, "repository")
    work = joinpath(root, "work")
    archives = joinpath(root, "archives")
    mkpath(repository)
    run_extraction_plan(
        prefix_plan,
        work,
        archives,
        synthetic_capture!;
        repository_root = repository,
        stop_on_failure = true,
    )
    rm(joinpath(archives, "campaign_extraction_receipt.toml"))
    interrupted_site = policy["site"][3]["name"]
    interrupted = joinpath(work, interrupted_site * ".capture")
    mkpath(joinpath(interrupted, "execution", "raw"))
    write(joinpath(interrupted, "execution", "raw", "partial.bin"), "partial")
    config_path = joinpath(root, "campaign-config.toml")
    open(config_path, "w") do io
        TOML.print(
            io,
            Dict(
                "schema_version" => 1,
                "plan_path" => plan_path,
                "work_root" => work,
                "archive_root" => archives,
                "stop_on_failure" => true,
            );
            sorted = true,
        )
    end
    validated = String[]
    validate_existing! = function (site, archive, receipt)
        push!(validated, site)
        isfile(archive) && isfile(receipt) || error("package missing")
        TOML.parsefile(receipt)["site"] == site ||
            throw(ArgumentError("site differs"))
        return (; ok = true, evidence_complete = true)
    end
    return (;
        policy,
        plan_path,
        config_path,
        repository,
        work,
        archives,
        interrupted_site,
        interrupted,
        validated,
        validate_existing!,
    )
end

@testset "resume validates prefix and preserves interrupted staging" begin
    mktempdir() do root
        fixture = resume_fixture(root)
        state = prepare_extraction_resume(
            fixture.plan_path,
            fixture.config_path,
            fixture.work,
            fixture.archives,
            fixture.validate_existing!;
            repository_root = fixture.repository,
            expected_plan_sha256 = sha256_path(fixture.plan_path),
            expected_config_sha256 = sha256_path(fixture.config_path),
        )

        @test state.next_index == 3
        @test fixture.validated ==
              getindex.(fixture.policy["site"][1:2], "name")
        @test !ispath(fixture.interrupted)
        @test isfile(state.interruption_archive)
        @test isfile(state.interruption_receipt)
        interruption = TOML.parsefile(state.interruption_receipt)
        @test interruption["status"] == "interrupted"
        @test interruption["site"] == fixture.interrupted_site
        @test interruption["archive_sha256"] ==
              sha256_path(state.interruption_archive)
        @test interruption["plan_sha256"] == sha256_path(fixture.plan_path)
        @test interruption["campaign_config_sha256"] ==
              sha256_path(fixture.config_path)
        manifest = TOML.parsefile(
            joinpath(dirname(state.interruption_receipt), "tree_manifest.toml"),
        )
        mktempdir() do extracted
            Tar.extract(state.interruption_archive, extracted)
            records = [
                Dict(
                    "path" => relpath(joinpath(root, name), extracted),
                    "bytes" => filesize(joinpath(root, name)),
                    "sha256" => sha256_path(joinpath(root, name)),
                ) for (root, _, files) in walkdir(extracted) for
                name in files
            ]
            sort!(records; by = record -> record["path"])
            @test records == manifest["file"]
        end

        report = run_extraction_plan(
            fixture.plan_path,
            fixture.work,
            fixture.archives,
            synthetic_capture!;
            repository_root = fixture.repository,
            stop_on_failure = true,
            resume = state,
        )
        @test report.site_count == 3
        @test report.packed_count == 3
        @test report.failed_count == 0
        names = getindex.(fixture.policy["site"], "name")
        @test fixture.validated == [
            names[1:2]
            names[3]
            names
        ]
        summary = TOML.parsefile(report.summary_path)
        @test summary["plan_sha256"] == sha256_path(fixture.plan_path)
        @test summary["campaign_config_sha256"] ==
              sha256_path(fixture.config_path)
        @test summary["attempt_count"] == 2
        @test getindex.(summary["attempt"], "status") ==
              ["interrupted", "complete"]
        @test length(summary["site"]) == 3
        @test summary["status"] == "complete"
        @test summary["full_coverage"] === true
        @test summary["package_count"] == 3
        @test getindex.(summary["package"], "site") ==
              getindex.(fixture.policy["site"], "name")
        @test all(
            package["archive_sha256"] ==
            sha256_path(joinpath(fixture.archives, package["site"] * ".tar")) &&
                package["receipt_sha256"] == sha256_path(
                    joinpath(
                        fixture.archives,
                        package["site"] * ".receipt.toml",
                    ),
                ) for package in summary["package"]
        )
        @test summary["package_inventory_sha256"] ==
              summary["attempt"][2]["package_inventory_sha256"]
    end
end

@testset "resume rejects gaps corruption extras and config drift" begin
    mktempdir() do root
        fixture = resume_fixture(root)
        first_site = fixture.policy["site"][1]["name"]
        rm(joinpath(fixture.archives, first_site * ".tar"))
        @test_throws ArgumentError prepare_extraction_resume(
            fixture.plan_path,
            fixture.config_path,
            fixture.work,
            fixture.archives,
            fixture.validate_existing!;
            repository_root = fixture.repository,
            expected_plan_sha256 = sha256_path(fixture.plan_path),
            expected_config_sha256 = sha256_path(fixture.config_path),
        )
    end

    mktempdir() do root
        fixture = resume_fixture(root)
        second_site = fixture.policy["site"][2]["name"]
        receipt_path = joinpath(fixture.archives, second_site * ".receipt.toml")
        receipt = TOML.parsefile(receipt_path)
        receipt["site"] = "forged"
        open(receipt_path, "w") do io
            TOML.print(io, receipt; sorted = true)
        end
        @test_throws ArgumentError prepare_extraction_resume(
            fixture.plan_path,
            fixture.config_path,
            fixture.work,
            fixture.archives,
            fixture.validate_existing!;
            repository_root = fixture.repository,
            expected_plan_sha256 = sha256_path(fixture.plan_path),
            expected_config_sha256 = sha256_path(fixture.config_path),
        )
    end

    mktempdir() do root
        fixture = resume_fixture(root)
        write(joinpath(fixture.archives, "EXTRA.tar"), "forged")
        @test_throws ArgumentError prepare_extraction_resume(
            fixture.plan_path,
            fixture.config_path,
            fixture.work,
            fixture.archives,
            fixture.validate_existing!;
            repository_root = fixture.repository,
            expected_plan_sha256 = sha256_path(fixture.plan_path),
            expected_config_sha256 = sha256_path(fixture.config_path),
        )
    end

    for (root_kind, entry_kind) in
        ((:archives, :directory), (:work, :file), (:work, :link))
        mktempdir() do root
            fixture = resume_fixture(root)
            target_root = getproperty(fixture, root_kind)
            extra = joinpath(target_root, "unexpected")
            if entry_kind == :directory
                mkpath(extra)
            elseif entry_kind == :file
                write(extra, "forged")
            else
                symlink(fixture.interrupted, extra)
            end
            @test_throws ArgumentError prepare_extraction_resume(
                fixture.plan_path,
                fixture.config_path,
                fixture.work,
                fixture.archives,
                fixture.validate_existing!;
                repository_root = fixture.repository,
                expected_plan_sha256 = sha256_path(fixture.plan_path),
                expected_config_sha256 = sha256_path(fixture.config_path),
            )
        end
    end

    mktempdir() do root
        fixture = resume_fixture(root)
        state = prepare_extraction_resume(
            fixture.plan_path,
            fixture.config_path,
            fixture.work,
            fixture.archives,
            fixture.validate_existing!;
            repository_root = fixture.repository,
            expected_plan_sha256 = sha256_path(fixture.plan_path),
            expected_config_sha256 = sha256_path(fixture.config_path),
        )
        open(fixture.config_path, "a") do io
            println(io, "drift = true")
        end
        @test_throws ArgumentError run_extraction_plan(
            fixture.plan_path,
            fixture.work,
            fixture.archives,
            synthetic_capture!;
            repository_root = fixture.repository,
            stop_on_failure = true,
            resume = state,
        )
    end
end

@testset "resume verifies interrupted TAR against its manifest" begin
    for mutation in (:content, :missing, :extra)
        mktempdir() do root
            fixture = resume_fixture(root)
            corrupt_pack! = function (source, destination)
                modified = joinpath(root, "modified-" * string(mutation))
                cp(source, modified)
                payload =
                    joinpath(modified, "execution", "raw", "partial.bin")
                if mutation == :content
                    write(payload, "tampered")
                elseif mutation == :missing
                    rm(payload)
                else
                    write(joinpath(modified, "extra.bin"), "extra")
                end
                Tar.create(modified, destination)
                return destination
            end
            @test_throws ArgumentError prepare_extraction_resume(
                fixture.plan_path,
                fixture.config_path,
                fixture.work,
                fixture.archives,
                fixture.validate_existing!;
                repository_root = fixture.repository,
                expected_plan_sha256 = sha256_path(fixture.plan_path),
                expected_config_sha256 = sha256_path(fixture.config_path),
                pack_interrupted! = corrupt_pack!,
            )
        end
    end
end

@testset "resume final coverage rejects package tampering" begin
    mktempdir() do root
        fixture = resume_fixture(root)
        state = prepare_extraction_resume(
            fixture.plan_path,
            fixture.config_path,
            fixture.work,
            fixture.archives,
            fixture.validate_existing!;
            repository_root = fixture.repository,
            expected_plan_sha256 = sha256_path(fixture.plan_path),
            expected_config_sha256 = sha256_path(fixture.config_path),
        )
        first_site = fixture.policy["site"][1]["name"]
        tampering_capture! = function (site, workspace, required_fields)
            synthetic_capture!(site, workspace, required_fields)
            open(joinpath(fixture.archives, first_site * ".tar"), "a") do io
                write(io, "tamper")
            end
        end
        @test_throws ArgumentError run_extraction_plan(
            fixture.plan_path,
            fixture.work,
            fixture.archives,
            tampering_capture!;
            repository_root = fixture.repository,
            stop_on_failure = true,
            resume = state,
        )
        @test !isfile(
            joinpath(fixture.archives, "campaign_extraction_receipt.toml"),
        )
    end
end
