function fixture_source_provenance()
    return Dict(
        "source_archive_sha256" => repeat("1", 64),
        "source_tree_sha256" => repeat("2", 64),
        "source_commit" => repeat("3", 40),
        "executable_sha256" => repeat("4", 64),
        "parameter_namelist_sha256" => repeat("5", 64),
        "job_options_sha256" => repeat("6", 64),
        "initial_condition_sha256" => repeat("7", 64),
        "instrumentation_patch_sha256" => repeat("8", 64),
        "schema_sha256" => sha256_file(TRAJECTORY_SCHEMA),
        "source_receipt_sha256" => repeat("9", 64),
        "source_package_sha256" => repeat("a", 64),
        "consumer_code_sha256" =>
            sha256_file(joinpath(@__DIR__, "all_site_parity.jl")),
    )
end

function fixture_replay_and_steps()
    replay = callback_replay()
    difficult = replay.steps[2]
    difficult.drivers["driver.tbar"][1, 1:5] .= 270.0
    difficult.drivers["driver.thice"][1, 1:5] .= 0.2
    difficult.drivers["driver.thliq"][1, 6:10] .= 0.5
    difficult.drivers["driver.thliq"][1, 11:15] .= 0.0
    difficult.drivers["driver.pre_resp_land_use_delta_litter"][1, 1, 1] = 3.0
    difficult.audit_diagnostics["audit.litter_clamp_correction"][1, 1, 1] = 2.0
    difficult.audit_diagnostics["audit.turbation_delta_litter"][1, 1, 1] = 1.0
    replay_report = (
        steps = [
            (; index = 1, state_error = 1.0e6),
            (; index = 2, state_error = 0.0),
        ],
    )
    return replay, fixture_step_records(replay, replay_report)
end

function synthetic_fixture_report(site)
    replay, steps = fixture_replay_and_steps()
    return (;
        site,
        ok = true,
        reference_kind = "synthetic",
        synthetic_data_used = true,
        fixture_static_data = replay.static_data,
        fixture_provenance = fixture_source_provenance(),
        steps,
    )
end

function approved_fixture_inventory(inventory, site)
    policies = deepcopy(inventory.policy_records)
    policy = policies[site]
    policy["policy_status"] = "cc_by_4"
    policy["redistribution_status"] = "approved"
    policy["source_chain_status"] = "complete"
    policy["attribution_status"] = "complete"
    return merge(inventory, (; policy_records = policies))
end

@testset "compact fixture selection is policy and process based" begin
    inventory = load_campaign_inventory(POLICY_INVENTORY, SITE_METRICS)
    site = first(inventory.sites)
    reports = [synthetic_fixture_report(site)]
    @test isempty(select_fixture_candidates(reports, inventory))
    approved = approved_fixture_inventory(inventory, site)
    candidate = only(select_fixture_candidates(reports, approved))
    @test candidate.ordinary_step == 1
    @test candidate.difficult_step == 2
    @test candidate.license_identifier == "CC-BY-4.0"
    @test Set(candidate.difficult_event_coverage) == Set((
        "freeze_thaw",
        "saturation",
        "drought",
        "large_inputs",
        "clamp",
        "turbation",
    ))
    reversed_errors =
        [merge(only(reports), (; steps = reverse(reports[1].steps)))]
    process_candidate =
        only(select_fixture_candidates(reversed_errors, approved))
    @test process_candidate.ordinary_step == candidate.ordinary_step
    @test process_candidate.difficult_step == candidate.difficult_step
    invalid = deepcopy(reports)
    invalid[1].steps[1].event_metrics["drought"] = NaN
    @test_throws ArgumentError select_fixture_candidates(invalid, approved)
end

@testset "fixture bridge retains payloads only for selected events" begin
    replay = callback_replay()
    previous = last(replay.steps)
    push!(
        replay.steps,
        ClassicTrajectoryBundle.TrajectoryStep(
            3,
            previous.time_end,
            previous.time_end + Day(1),
            deepcopy(previous.drivers),
            deepcopy(previous.reference_state),
            deepcopy(previous.audit_diagnostics),
        ),
    )
    replay_report = (
        steps = [
            (; index = 1, state_error = 0.0),
            (; index = 2, state_error = 0.0),
            (; index = 3, state_error = 0.0),
        ],
    )
    records = fixture_step_records(replay, replay_report)
    @test count(step -> hasproperty(step, :drivers), records) == 2
    @test !hasproperty(records[3], :drivers)
end

@testset "synthetic compact fixture packer fails closed" begin
    inventory = load_campaign_inventory(POLICY_INVENTORY, SITE_METRICS)
    site = first(inventory.sites)
    approved = approved_fixture_inventory(inventory, site)
    report = synthetic_fixture_report(site)
    mktempdir() do directory
        archive = joinpath(directory, "synthetic.tar")
        packed = pack_synthetic_compact_fixture(
            archive,
            [report],
            approved,
            TRAJECTORY_SCHEMA;
            repository_root = normpath(joinpath(@__DIR__, "../../../..")),
        )
        @test packed.fixture_count == 2
        @test !packed.scientific_parity_claimed
        extracted = joinpath(directory, "extracted")
        mkpath(extracted)
        Tar.extract(archive, extracted)
        manifest = TOML.parsefile(joinpath(extracted, "manifest.toml"))
        @test manifest["synthetic_data_used"] === true
        @test manifest["scientific_parity_claimed"] === false
        @test manifest["selection_basis"] ==
              "explicit_event_coverage_then_process_magnitude"
        @test Set(getindex.(manifest["fixture"], "role")) ==
              Set(("ordinary", "difficult"))
        @test manifest["trajectory_schema_sha256"] ==
              sha256_file(TRAJECTORY_SCHEMA)
        @test manifest["fixture_packer_sha256"] ==
              sha256_file(joinpath(@__DIR__, "all_site_parity.jl"))
        for record in manifest["fixture"]
            bundle = joinpath(extracted, record["bundle_path"])
            @test validate_bundle(bundle, TRAJECTORY_SCHEMA).ok
            @test length(open_replay(bundle, TRAJECTORY_SCHEMA).steps) == 1
            @test record["bundle_manifest_sha256"] ==
                  sha256_file(joinpath(bundle, "manifest.toml"))
            @test haskey(record, "event_metrics")
            @test haskey(record, "source_receipt_sha256")
            @test haskey(record, "source_package_sha256")
        end

        real_report = merge(
            report,
            (;
                reference_kind = "fresh_local_fortran",
                synthetic_data_used = false,
            ),
        )
        @test_throws ArgumentError pack_synthetic_compact_fixture(
            joinpath(directory, "real.tar"),
            [real_report],
            approved,
            TRAJECTORY_SCHEMA;
            repository_root = normpath(joinpath(@__DIR__, "../../../..")),
        )
        @test_throws ArgumentError pack_synthetic_compact_fixture(
            joinpath(@__DIR__, "forbidden.tar"),
            [report],
            approved,
            TRAJECTORY_SCHEMA;
            repository_root = normpath(joinpath(@__DIR__, "../../../..")),
        )
        incomplete = deepcopy(report)
        for step in incomplete.steps
            step.event_metrics["turbation"] = 0.0
        end
        @test_throws ArgumentError pack_synthetic_compact_fixture(
            joinpath(directory, "incomplete-events.tar"),
            [incomplete],
            approved,
            TRAJECTORY_SCHEMA;
            repository_root = normpath(joinpath(@__DIR__, "../../../..")),
        )
        repository_root = joinpath(directory, "repository")
        mkpath(joinpath(repository_root, "fixtures"))
        link = joinpath(directory, "repository-link")
        symlink(repository_root, link)
        @test_throws ArgumentError pack_synthetic_compact_fixture(
            joinpath(link, "fixtures", "escaped.tar"),
            [report],
            approved,
            TRAJECTORY_SCHEMA;
            repository_root,
        )
    end
end
