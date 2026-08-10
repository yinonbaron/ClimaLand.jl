function write_roundtrip_toml(path, document)
    mkpath(dirname(path))
    open(path, "w") do io
        TOML.print(io, document; sorted = true)
    end
    return path
end

function roundtrip_activity_document()
    fields = load_expanded_schema(TRAJECTORY_SCHEMA)["field"]
    records = [
        Dict(
            "name" => field["name"],
            "present" => true,
            "active" => false,
            "reason" => "observed_zero",
            "nonzero_count" => 0,
            "maximum_absolute_value" => 0.0,
        ) for field in fields
    ]
    return Dict(
        "schema_version" => 1,
        "field_count" => length(records),
        "field" => records,
    )
end

function roundtrip_inactive_evidence(mask_sha256)
    contract =
        ClassicAllSiteParity.ClassicInactiveStageB.CANONICAL_GUARD_CONTRACT
    guards = [
        merge(Dict("label" => label), deepcopy(record)) for
        (label, record) in contract
    ]
    return Dict(
        "schema_version" => 1,
        "evidence_status" => "complete",
        "site" => "CA-Mer",
        "stage_b_status" => "inactive",
        "reason" => "all_tiles_are_peatland_and_v5_mineral_mask_is_zero",
        "replay_claimed" => false,
        "replay_result" => "not_applicable_inactive_path",
        "complete_seasonal_cycle" => true,
        "step_count" => 365,
        "stage_c_semantics_excluded" => true,
        "deferred_issue" => 108,
        "stage_c_exclusion" => [
            "captured_litter_and_soil_carbon_pool_semantics",
            "captured_peat_and_moss_heterotrophic_flux_semantics",
            "captured_peat_and_moss_pool_update_semantics",
        ],
        "initial_condition_sha256" => VALID_SHA,
        "initial_ipeatland_dtype" => "Int32",
        "initial_ipeatland_shape" => [1],
        "ipeatland" => [1],
        "peatland_type" => ["Bog"],
        "initial_imoss_dtype" => "Int32",
        "initial_imoss_shape" => [1],
        "imoss" => [1],
        "moss_type" => ["Sphagnum"],
        "job_options_sha256" => VALID_SHA,
        "configuration" => Dict(
            "do_peat_outputs" => true,
            "use_static_peat_depth" => true,
            "turbation_switch_requested" => true,
        ),
        "mineral_mask_path" => "payloads/fixed/static_mineral_mask.bin",
        "mineral_mask_payload_sha256" => mask_sha256,
        "mineral_mask_payload_bytes" => 4,
        "mineral_mask_dtype" => "int32",
        "mineral_mask_shape" => [1],
        "mineral_mask" => [0],
        "mineral_mask_count" => 1,
        "mineral_mask_nonzero_count" => 0,
        "mineral_mask_minimum" => 0,
        "mineral_mask_maximum" => 0,
        "source_guard" => guards,
    )
end

function write_portable_inactive_package(root, inventory)
    bundle = joinpath(root, "bundle")
    write_synthetic_bundle(
        bundle,
        TRAJECTORY_SCHEMA;
        step_count = 365,
        shared_step_payloads = true,
    )
    manifest_path = joinpath(bundle, "manifest.toml")
    manifest = TOML.parsefile(manifest_path)
    manifest["trajectory"]["site"] = "CA-Mer"
    first_time = DateTime(2001, 1, 1)
    for (index, step) in enumerate(manifest["step"])
        step["index"] = index
        step["time_start"] = string(first_time + Day(index - 1))
        step["time_end"] = string(first_time + Day(index))
    end
    mask_record = only(
        filter(
            field -> field["name"] == "static.mineral_mask",
            manifest["field"],
        ),
    )
    mask_path = joinpath(bundle, mask_record["path"])
    open(mask_path, "w") do io
        write(io, Int32[0])
    end
    mask_record["shape"] = [1]
    mask_record["bytes"] = 4
    mask_record["sha256"] = sha256_file(mask_path)

    evidence_root = joinpath(bundle, "evidence")
    mkpath(evidence_root)
    nonperturbation = Dict(
        "schema_version" => 1,
        "site" => "CA-Mer",
        "reference_kind" => "fresh_local_fortran",
        "candidate_kind" => "instrumented_stage_b_v5",
        "synthetic_data_used" => false,
        "result" => "pass",
        "criteria" => "exact values, coordinates, masks, dimensions, types, and units",
        "compared_files" => 57,
        "failed_files" => 0,
        "record_count_per_daily_file" => 4018,
    )
    nonperturbation_path = write_roundtrip_toml(
        joinpath(evidence_root, "nonperturbation_receipt.toml"),
        nonperturbation,
    )
    inactive_path = write_roundtrip_toml(
        joinpath(evidence_root, "inactive_stage_b.toml"),
        roundtrip_inactive_evidence(mask_record["sha256"]),
    )
    manifest["evidence"] = Dict(
        "inactive_stage_b_evidence_sha256" => sha256_file(inactive_path),
        "replay_claimed" => false,
    )
    write_roundtrip_toml(manifest_path, manifest)

    activity = roundtrip_activity_document()
    activity_path =
        write_roundtrip_toml(joinpath(bundle, "field_activity.toml"), activity)
    provenance = real_provenance()
    delete!(provenance, "replay_receipt_sha256")
    provenance["nonperturbation_receipt_sha256"] =
        sha256_file(nonperturbation_path)
    provenance["inactive_stage_b_evidence_sha256"] = sha256_file(inactive_path)
    provenance["site_job_options_sha256"] = VALID_SHA
    provenance["site_initial_condition_sha256"] = VALID_SHA
    capture = Dict(
        "site" => "CA-Mer",
        "status" => "complete",
        "reference_kind" => "fresh_local_fortran",
        "oracle_contract" => "stage_b_v5",
        "synthetic_data_used" => false,
        "complete_seasonal_cycle" => true,
        "step_count" => 365,
        "capture_year" => 2001,
        "capture_event_count" => 365,
        "capture_source_calendar" => "standard",
        "capture_first_time" => "2001-01-01T00:00:00",
        "capture_last_time" => "2001-12-31T00:00:00",
        "capture_next_year_start" => "2002-01-01T00:00:00",
        "trajectory_schema_sha256" => sha256_file(TRAJECTORY_SCHEMA),
        "stage_b_status" => "inactive",
        "replay_claimed" => false,
        "stage_c_semantics_excluded" => true,
        "deferred_issue" => 108,
        "provenance" => provenance,
    )
    capture_path =
        write_roundtrip_toml(joinpath(bundle, "capture_receipt.toml"), capture)

    archive = joinpath(root, "CA-Mer.tar")
    Tar.create(bundle, archive)
    policy = inventory.policy_records["CA-Mer"]
    external = deepcopy(capture)
    external["schema_version"] = 1
    external["artifact_policy"] = "external_only"
    external["policy_inventory_sha256"] = inventory.policy_sha256
    external["missing_fields"] = String[]
    external["inactive_fields"] = sort!(getindex.(activity["field"], "name"))
    external["nonperturbation_result"] = "pass"
    external["capture_receipt_sha256"] = sha256_file(capture_path)
    external["activity_report_sha256"] = sha256_file(activity_path)
    external["archive_path"] = abspath(archive)
    external["archive_bytes"] = filesize(archive)
    external["archive_sha256"] = sha256_file(archive)
    for key in ClassicAllSiteParity.RECEIPT_IDENTITY_FIELDS
        haskey(policy, key) && (external[key] = policy[key])
    end
    receipt =
        write_roundtrip_toml(joinpath(root, "CA-Mer.receipt.toml"), external)
    package = (site = "CA-Mer", archive, receipt)
    tolerances = (; sha256 = VALID_SHA, measurement_receipts = NamedTuple[])
    return (; package, tolerances)
end

@testset "inactive archive is consumed without a Stage B parity claim" begin
    inventory = load_campaign_inventory(POLICY_INVENTORY, SITE_METRICS)
    mktempdir() do root
        fixture = write_portable_inactive_package(root, inventory)
        unexpected(args...; kwargs...) =
            error("inactive archive invoked replay")
        report = consume_site_archive(
            fixture.package,
            inventory,
            TRAJECTORY_SCHEMA,
            unexpected,
            unexpected,
            unexpected;
            tolerances = fixture.tolerances,
        )
        @test report.ok
        @test report.evidence_complete
        @test report.stage_b_status == "inactive"
        @test !report.stage_b_parity
        @test report.excluded_from_stage_b_parity
        @test !report.replay_claimed
        @test report.deferred_issue == 108
        @test isnothing(report.replay)
        @test isnothing(report.evaluation)
        @test isempty(report.steps)
        @test length(report.applicability["source_guard"]) == 10
    end
end
