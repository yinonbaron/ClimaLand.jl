function draft_activity()
    return (;
        active_pathways = ["heterotrophic_respiration"],
        inactive_pathways = ["turbation"],
        active_fields = ["audit.hetrores"],
        inactive_fields = ["audit.turbation_delta_litter"],
    )
end

function draft_report_fixture(root, inventory)
    archives = joinpath(root, "archives")
    mkpath(archives)
    measurement = joinpath(root, "measurement.toml")
    write(measurement, "schema_version = 1\nstatus = \"pass\"\n")
    measurement_sha = sha256_file(measurement)
    tolerances = (;
        state = Dict("state.one" => 1.0e-12),
        flux = Dict("flux.one" => 1.0e-12),
        budget = Dict("carbon_closure" => 1.0e-12),
        drift = Dict("accumulated_drift" => 1.0e-12),
        sha256 = repeat("a", 64),
        measurement_receipts = [(;
            path = measurement,
            evidence_id = "measurement.toml",
            sha256 = measurement_sha,
        )],
    )
    inactive_sites = Set(inventory.sites[1:2])
    reports = NamedTuple[]
    for site in inventory.sites
        archive = joinpath(archives, site * ".tar")
        receipt_path = joinpath(archives, site * ".receipt.toml")
        write(archive, "synthetic archive inventory $site")
        inactive = site in inactive_sites
        evidence_hash = repeat(inactive ? "d" : "e", 64)
        provenance = Dict(
            "nonperturbation_receipt_sha256" => repeat("c", 64),
            (
                inactive ? "inactive_stage_b_evidence_sha256" :
                "replay_receipt_sha256"
            ) => evidence_hash,
        )
        receipt = Dict(
            "site" => site,
            "status" => "complete",
            "stage_b_status" => inactive ? "inactive" : "active",
            "archive_path" => abspath(archive),
            "archive_sha256" => sha256_file(archive),
            "capture_receipt_sha256" => repeat("a", 64),
            "activity_report_sha256" => repeat("b", 64),
            "provenance" => provenance,
        )
        open(receipt_path, "w") do io
            TOML.print(io, receipt; sorted = true)
        end
        errors = (;
            state = Dict("state.one" => 0.0),
            flux = Dict("flux.one" => 0.0),
            budget = Dict("carbon_closure" => 0.0),
            drift = Dict("accumulated_drift" => 0.0),
        )
        push!(
            reports,
            (;
                site,
                evidence_complete = true,
                stage_b_status = inactive ? "inactive" : "active",
                stage_b_parity = !inactive,
                activity = draft_activity(),
                achieved_errors = inactive ? nothing : errors,
                evaluation = inactive ? nothing :
                             (; failure_localization = Any[]),
                applicability = inactive ?
                                Dict("stage_b_status" => "inactive") : nothing,
            ),
        )
    end
    campaign = (;
        ok = true,
        evidence_complete = true,
        active_stage_b_parity_complete = true,
        active_site_count = 57,
        inactive_site_count = 2,
        site_count = 59,
        reports,
    )
    return (; archives, campaign, tolerances, measurement)
end

@testset "all-site draft report binds every evidence layer" begin
    inventory = load_campaign_inventory(POLICY_INVENTORY, SITE_METRICS)
    mktempdir() do root
        fixture = draft_report_fixture(root, inventory)
        path = joinpath(root, "draft.toml")
        result = write_all_site_draft_report(
            path,
            fixture.campaign,
            fixture.archives,
            inventory,
            fixture.tolerances;
            repository_root = normpath(joinpath(@__DIR__, "../../../..")),
        )
        report = TOML.parsefile(path)
        @test result.sha256 == sha256_file(path)
        @test report["status"] == "draft_complete"
        @test report["approval_status"] == "pending_direct_user_approval"
        @test report["scientific_status"] == "not_promoted"
        @test report["seasonal_parity_claimed"] === false
        @test report["checksum_status"] == "draft_only_not_promoted"
        @test report["site_count"] == 59
        @test report["active_site_count"] == 57
        @test report["inactive_site_count"] == 2
        @test length(report["site"]) == 59
        @test Set(keys(report["site"][3]["max_state_errors"])) ==
              Set(keys(fixture.tolerances.state))
        @test report["tolerances"]["state"] == fixture.tolerances.state
        @test report["tolerances"]["flux"] == fixture.tolerances.flux
        @test report["tolerances"]["budget"] == fixture.tolerances.budget
        @test report["tolerances"]["drift"] == fixture.tolerances.drift
        @test haskey(report["site"][3], "failure_localization")
        @test report["site"][1]["replay_claimed"] === false
        @test report["site"][1]["deferred_issue"] == 108
        @test report["tolerance_measurement_receipt"][1]["sha256"] ==
              sha256_file(fixture.measurement)
    end
end

@testset "all-site draft report fails closed on forged inputs" begin
    inventory = load_campaign_inventory(POLICY_INVENTORY, SITE_METRICS)
    mktempdir() do root
        fixture = draft_report_fixture(root, inventory)
        missing = merge(
            fixture.campaign,
            (; reports = fixture.campaign.reports[2:end], site_count = 58),
        )
        @test_throws ArgumentError build_all_site_draft_report(
            missing,
            fixture.archives,
            inventory,
            fixture.tolerances,
        )

        incomplete = deepcopy(fixture.campaign.reports)
        delete!(incomplete[3].achieved_errors.state, "state.one")
        @test_throws ArgumentError build_all_site_draft_report(
            merge(fixture.campaign, (; reports = incomplete)),
            fixture.archives,
            inventory,
            fixture.tolerances,
        )

        write(fixture.measurement, "tampered")
        @test_throws ArgumentError build_all_site_draft_report(
            fixture.campaign,
            fixture.archives,
            inventory,
            fixture.tolerances,
        )

        @test_throws ArgumentError write_all_site_draft_report(
            joinpath(@__DIR__, "forbidden-draft.toml"),
            fixture.campaign,
            fixture.archives,
            inventory,
            fixture.tolerances;
            repository_root = normpath(joinpath(@__DIR__, "../../../..")),
        )

        repository_root = joinpath(root, "repository")
        mkpath(joinpath(repository_root, "reports"))
        link = joinpath(root, "repository-link")
        symlink(repository_root, link)
        fresh_root = joinpath(root, "fresh")
        fresh = draft_report_fixture(fresh_root, inventory)
        @test_throws ArgumentError write_all_site_draft_report(
            joinpath(link, "reports", "escaped.toml"),
            fresh.campaign,
            fresh.archives,
            inventory,
            fresh.tolerances;
            repository_root,
        )
    end
end

@testset "all-site draft report runner parses" begin
    runner = joinpath(@__DIR__, "run_all_site_report.jl")
    @test Meta.parseall(read(runner, String)) isa Expr
end

@testset "external output path rejects final symlinks" begin
    mktempdir() do root
        repository_root = joinpath(root, "repository")
        mkpath(repository_root)

        target = joinpath(root, "existing.toml")
        write(target, "existing")
        live_link = joinpath(root, "live-link.toml")
        symlink(target, live_link)
        @test_throws ArgumentError external_output_path(
            live_link,
            repository_root,
        )

        dangling_link = joinpath(root, "dangling-link.toml")
        symlink(joinpath(root, "missing.toml"), dangling_link)
        @test islink(dangling_link)
        @test !ispath(dangling_link)
        @test_throws ArgumentError external_output_path(
            dangling_link,
            repository_root,
        )
    end
end
