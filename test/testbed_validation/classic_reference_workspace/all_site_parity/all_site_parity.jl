module ClassicAllSiteParity

import SHA
import TOML
import Tar
using Dates: DateTime, daysinyear
using ..ClassicToleranceContract: evaluate_replay_report
using ..ClassicTrajectoryBundle: validate_bundle
include(joinpath(@__DIR__, "..", "all_sites", "inactive_stage_b.jl"))
using .ClassicInactiveStageB: validate_inactive_stage_b_evidence

export classify_activity,
    consume_site_archive,
    external_output_path,
    fixture_step_records,
    load_campaign_inventory,
    load_expanded_schema,
    pack_synthetic_compact_fixture,
    run_all_site_parity,
    select_fixture_candidates,
    sha256_file,
    step_process_activity,
    validate_archive_headers,
    validate_archive_set,
    validate_external_receipt,
    validate_nonperturbation_evidence,
    validate_structural_trajectory,
    validate_real_provenance

const EXPECTED_SITE_COUNT = 59
const SAFE_SITE = r"^[A-Z0-9]{2,3}-[A-Za-z0-9]{2,3}$"

sha256_file(path) = bytes2hex(open(SHA.sha256, path))

function site_names(document, count_key, name_key)
    count = get(document, count_key, nothing)
    count == EXPECTED_SITE_COUNT ||
        throw(ArgumentError("$count_key must equal $EXPECTED_SITE_COUNT"))
    records = get(document, "site", Any[])
    length(records) == EXPECTED_SITE_COUNT || throw(
        ArgumentError(
            "inventory must contain exactly $EXPECTED_SITE_COUNT sites",
        ),
    )
    names = String[get(record, name_key, "") for record in records]
    length(unique(names)) == EXPECTED_SITE_COUNT ||
        throw(ArgumentError("inventory contains duplicate site identifiers"))
    all(name -> occursin(SAFE_SITE, name), names) ||
        throw(ArgumentError("inventory contains an unsafe site identifier"))
    return names
end

"""
    load_campaign_inventory(policy_path, metrics_path)

Load and cross-check the exact 59-site policy and process inventories. Both
inventories must describe the identical site set, and site artifacts must
remain external to the Git repository.
"""
function load_campaign_inventory(policy_path, metrics_path)
    policy = TOML.parsefile(policy_path)
    metrics = TOML.parsefile(metrics_path)
    get(policy, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported policy inventory"))
    get(metrics, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported site metrics inventory"))
    policy_sites = site_names(policy, "expected_site_count", "name")
    metric_sites = site_names(metrics, "site_count", "site")
    Set(policy_sites) == Set(metric_sites) || throw(
        ArgumentError("policy and process inventories contain different sites"),
    )
    artifact_policy = get(policy, "artifact_policy", Dict())
    all(
        get(artifact_policy, key, nothing) == "external_only" for
        key in ("site_inputs", "derived_tapes", "trajectory_bundles")
    ) || throw(ArgumentError("restricted site artifacts must remain external"))
    policy_records = Dict(record["name"] => record for record in policy["site"])
    required = (
        "full_name",
        "source_identifier",
        "policy_status",
        "attribution_status",
        "source_chain_status",
        "redistribution_status",
    )
    all(
        all(haskey(policy_records[name], key) for key in required) for
        name in policy_sites
    ) || throw(ArgumentError("policy inventory has incomplete site records"))
    return (
        sites = sort!(policy_sites),
        policy_records,
        policy_sha256 = sha256_file(policy_path),
        metrics_sha256 = sha256_file(metrics_path),
    )
end

const SHA256_PATTERN = r"^[0-9a-f]{64}$"
const COMMIT_PATTERN = r"^[0-9a-f]{40}$"
const REAL_PROVENANCE_HASHES = (
    "source_archive_sha256",
    "source_tree_sha256",
    "instrumented_executable_sha256",
    "instrumentation_patch_sha256",
    "snapshot_schema_sha256",
    "parameter_namelist_sha256",
    "site_job_options_sha256",
    "site_initial_condition_sha256",
    "completion_ledger_sha256",
    "time_index_sha256",
    "nonperturbation_receipt_sha256",
    "oracle_receipt_sha256",
    "oracle_output_manifest_sha256",
    "execution_receipt_sha256",
    "sealed_event_index_sha256",
)
const PATHWAY_FIELDS = Dict(
    "competition" => (
        "driver.pre_resp_competition_delta_litter",
        "driver.pre_resp_competition_delta_soil",
    ),
    "land_use" => (
        "driver.pre_resp_land_use_delta_litter",
        "driver.pre_resp_land_use_delta_soil",
    ),
    "harvest" => (
        "driver.pre_resp_harvest_delta_litter",
        "driver.pre_resp_harvest_delta_soil",
    ),
    "heterotrophic_respiration" => (
        "audit.ltresveg",
        "audit.scresveg",
        "audit.hetrsveg",
        "audit.litres",
        "audit.socres",
        "audit.hetrores",
        "audit.soilresp",
    ),
    "humification" => ("audit.humtrsvg", "audit.humiftrs"),
    "turnover" => (
        "driver.post_resp_turnover_delta_litter",
        "driver.post_resp_turnover_delta_soil",
    ),
    "mortality" => (
        "driver.post_resp_mortality_delta_litter",
        "driver.post_resp_mortality_delta_soil",
    ),
    "disturbance" => (
        "driver.post_resp_disturbance_delta_litter",
        "driver.post_resp_disturbance_delta_soil",
    ),
    "pool_clamping" =>
        ("audit.litter_clamp_correction", "audit.soil_clamp_correction"),
    "turbation" => (
        "audit.turbation_delta_litter",
        "audit.turbation_delta_soil",
        "audit.turbation_litter_column_residual",
        "audit.turbation_soil_column_residual",
    ),
)

valid_sha256(value) =
    value isa AbstractString && occursin(SHA256_PATTERN, value)
valid_commit(value) =
    value isa AbstractString && occursin(COMMIT_PATTERN, value)

"""
    validate_real_provenance(provenance)

Require machine-readable evidence that a bundle came from the fresh local
CLASSIC v2.0 Fortran oracle under the promoted Stage B v5 capture contract.
"""
function validate_real_provenance(provenance)
    get(provenance, "reference_kind", nothing) == "fresh_local_fortran" ||
        throw(ArgumentError("reference_kind is not fresh_local_fortran"))
    get(provenance, "capture_schema", nothing) == "stage_b_v5" ||
        throw(ArgumentError("capture_schema is not stage_b_v5"))
    get(provenance, "synthetic", nothing) === false ||
        throw(ArgumentError("synthetic evidence cannot pass the real gate"))
    valid_commit(get(provenance, "source_commit", nothing)) ||
        throw(ArgumentError("provenance lacks a valid source_commit"))
    for key in REAL_PROVENANCE_HASHES
        valid_sha256(get(provenance, key, nothing)) ||
            throw(ArgumentError("provenance lacks a valid $key"))
    end
    stage_b_status = get(provenance, "stage_b_status", "active")
    if stage_b_status == "inactive"
        valid_sha256(
            get(provenance, "inactive_stage_b_evidence_sha256", nothing),
        ) || throw(
            ArgumentError("inactive provenance lacks applicability evidence"),
        )
        haskey(provenance, "replay_receipt_sha256") &&
            throw(ArgumentError("inactive provenance contains replay evidence"))
    elseif stage_b_status == "active"
        valid_sha256(get(provenance, "replay_receipt_sha256", nothing)) ||
            throw(ArgumentError("active provenance lacks replay evidence"))
    else
        throw(ArgumentError("provenance Stage-B status is invalid"))
    end
    return true
end

function load_expanded_schema(path)
    schema = TOML.parsefile(path)
    get(schema, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported trajectory schema"))
    fields = copy(get(schema, "field", Any[]))
    for group in get(get(schema, "groups", Dict()), "field", Any[])
        for name in get(group, "names", Any[])
            field =
                Dict(key => value for (key, value) in group if key != "names")
            field["name"] = name
            push!(fields, field)
        end
    end
    names = getindex.(fields, "name")
    length(unique(names)) == length(names) ||
        throw(ArgumentError("trajectory schema contains duplicate fields"))
    schema["field"] = fields
    return schema
end

function validate_activity_record(record)
    required = (
        "name",
        "present",
        "active",
        "reason",
        "nonzero_count",
        "maximum_absolute_value",
    )
    all(haskey(record, key) for key in required) ||
        throw(ArgumentError("activity record has incomplete evidence"))
    get(record, "present", false) === true ||
        throw(ArgumentError("activity record is not present"))
    active = record["active"]
    active isa Bool || throw(ArgumentError("activity status must be a boolean"))
    reason = record["reason"]
    reason isa AbstractString && !isempty(reason) ||
        throw(ArgumentError("activity record lacks a reason"))
    nonzero_count = record["nonzero_count"]
    maximum = record["maximum_absolute_value"]
    nonzero_count isa Integer && nonzero_count >= 0 ||
        throw(ArgumentError("activity nonzero_count is inconsistent"))
    maximum isa Real && isfinite(maximum) && maximum >= 0 ||
        throw(ArgumentError("activity maximum_absolute_value is invalid"))
    if active
        nonzero_count > 0 && maximum > 0 ||
            throw(ArgumentError("active field lacks nonzero evidence"))
    else
        nonzero_count == 0 && maximum == 0 ||
            throw(ArgumentError("inactive field has nonzero evidence"))
    end
    return nothing
end

"""
    classify_activity(document, schema_path)

Validate exact 70-field bundle activity coverage and return explicit active and
inactive Stage B pathways. Inactivity is accepted only with zero-count evidence
and a recorded reason for every field owned by the pathway.
"""
function classify_activity(document, schema_path)
    get(document, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported field-activity schema"))
    schema = load_expanded_schema(schema_path)
    expected = Set(field["name"] for field in schema["field"])
    records = get(document, "field", Any[])
    get(document, "field_count", nothing) == length(expected) ||
        throw(ArgumentError("field activity count differs from the schema"))
    names = String[get(record, "name", "") for record in records]
    length(unique(names)) == length(names) ||
        throw(ArgumentError("field activity contains duplicate records"))
    Set(names) == expected || throw(
        ArgumentError(
            "field activity does not exactly cover the bundle schema",
        ),
    )
    by_name = Dict(record["name"] => record for record in records)
    foreach(validate_activity_record, values(by_name))
    active_pathways = String[]
    inactive_pathways = String[]
    for (pathway, fields) in PATHWAY_FIELDS
        statuses = [by_name[name]["active"] for name in fields]
        destination = any(statuses) ? active_pathways : inactive_pathways
        push!(destination, pathway)
    end
    return (
        active_pathways = sort!(active_pathways),
        inactive_pathways = sort!(inactive_pathways),
        active_fields = sort!([
            name for (name, record) in by_name if record["active"]
        ]),
        inactive_fields = sort!([
            name for (name, record) in by_name if !record["active"]
        ]),
    )
end

const REQUIRED_ARCHIVE_ROOT_FILES =
    Set(("manifest.toml", "field_activity.toml", "capture_receipt.toml"))
const CAMPAIGN_CONTROL_FILES = Set((
    "campaign_completion_receipt.v2.toml",
    "campaign_extraction_receipt.toml",
    "campaign_package_inventory.v2.toml",
))
const EVIDENCE_MEMBER_PREFIXES = Set((
    "capture_receipt",
    "command",
    "snapshot_index",
    "completion_ledger",
    "sealed_event_index",
    "execution_receipt",
    "nonperturbation_receipt",
    "netcdf_time_receipt",
    "oracle_outputs",
    "oracle_receipt",
    "replay_receipt",
    "inactive_stage_b",
    "resource_time",
    "run",
))

function required_regular_file(path, label)
    isfile(path) || throw(ArgumentError("missing $label: $path"))
    islink(path) && throw(ArgumentError("$label must not be a symlink"))
    filesize(path) > 0 || throw(ArgumentError("$label is empty"))
    return abspath(path)
end

"""
    validate_archive_set(root, inventory)

Require exactly one nonempty TAR and one receipt for every canonical inventory
entry. The exact three-file campaign-control set is optional; partial or
unrecognized control inventories fail closed.
"""
function validate_archive_set(root, inventory)
    isdir(root) || throw(ArgumentError("archive root does not exist"))
    expected = Set(
        vcat(
            [site * ".tar" for site in inventory.sites],
            [site * ".receipt.toml" for site in inventory.sites],
        ),
    )
    actual = Set(readdir(root))
    expected ⊆ actual ||
        throw(ArgumentError("archive root lacks a canonical site package"))
    controls = setdiff(actual, expected)
    (isempty(controls) || controls == CAMPAIGN_CONTROL_FILES) || throw(
        ArgumentError(
            "archive root does not exactly match the 59-site inventory",
        ),
    )
    return [
        (
            site,
            archive = required_regular_file(
                joinpath(root, site * ".tar"),
                "$site archive",
            ),
            receipt = required_regular_file(
                joinpath(root, site * ".receipt.toml"),
                "$site receipt",
            ),
        ) for site in inventory.sites
    ]
end

function safe_archive_path(path)
    !isabspath(path) && all(part -> part ∉ ("", ".", ".."), splitpath(path))
end

function allowed_archive_file(path)
    path in REQUIRED_ARCHIVE_ROOT_FILES && return true
    occursin(r"^payloads/fixed/[^/]+[.]bin$", path) && return true
    occursin(r"^payloads/step_[0-9]{8}/[^/]+[.]bin$", path) && return true
    startswith(path, "evidence/") || return false
    basename_without_extension = first(splitext(basename(path)))
    return basename_without_extension in EVIDENCE_MEMBER_PREFIXES
end

"""
    validate_archive_headers(path)

Reject unsafe, linked, duplicate, or contract-external TAR members before
extraction. Raw site tapes are not valid trajectory-package members.
"""
function validate_archive_headers(path)
    required_regular_file(path, "site trajectory archive")
    headers = try
        Tar.list(path; strict = true)
    catch error
        throw(
            ArgumentError(
                "unreadable site archive: $(sprint(showerror, error))",
            ),
        )
    end
    paths = getproperty.(headers, :path)
    length(unique(paths)) == length(paths) ||
        throw(ArgumentError("site archive contains duplicate members"))
    all(
        header ->
            header.type in (:file, :directory) &&
            isempty(header.link) &&
            safe_archive_path(header.path),
        headers,
    ) || throw(ArgumentError("site archive contains an unsafe member"))
    files = Set(header.path for header in headers if header.type == :file)
    REQUIRED_ARCHIVE_ROOT_FILES ⊆ files ||
        throw(ArgumentError("site archive lacks required contract files"))
    all(allowed_archive_file, files) ||
        throw(ArgumentError("site archive contains an unexpected payload"))
    return headers
end

const RECEIPT_IDENTITY_FIELDS = (
    "full_name",
    "source_category",
    "source_identifier",
    "policy_status",
    "policy_reference",
    "attribution_status",
    "source_chain_status",
    "redistribution_status",
    "unresolved_reason",
)

"""
    validate_external_receipt(path, archive, site, inventory, schema_path)

Validate archive bytes, site-policy identity, v5 schema, seasonal coverage,
and fresh-local Fortran provenance before extracting a site TAR.
"""
function validate_external_receipt(path, archive, site, inventory, schema_path)
    receipt =
        TOML.parsefile(required_regular_file(path, "$site external receipt"))
    gates = (
        get(receipt, "schema_version", nothing) == 1,
        get(receipt, "site", nothing) == site,
        get(receipt, "status", nothing) == "complete",
        get(receipt, "reference_kind", nothing) == "fresh_local_fortran",
        get(receipt, "oracle_contract", nothing) == "stage_b_v5",
        get(receipt, "synthetic_data_used", nothing) === false,
        get(receipt, "nonperturbation_result", nothing) == "pass",
        get(receipt, "complete_seasonal_cycle", nothing) === true,
        get(receipt, "stage_b_status", nothing) in ("active", "inactive"),
        get(receipt, "artifact_policy", nothing) == "external_only",
        get(receipt, "policy_inventory_sha256", nothing) ==
        inventory.policy_sha256,
        isempty(get(receipt, "missing_fields", Any[nothing])),
    )
    all(gates) || throw(ArgumentError("external receipt gate failed for $site"))
    step_count = get(receipt, "step_count", nothing)
    step_count isa Integer && step_count >= 365 ||
        throw(ArgumentError("external receipt has too few steps for $site"))
    archive = required_regular_file(archive, "$site trajectory archive")
    normpath(abspath(get(receipt, "archive_path", ""))) == archive ||
        throw(ArgumentError("external receipt archive path differs for $site"))
    get(receipt, "archive_bytes", nothing) == filesize(archive) || throw(
        ArgumentError("external receipt archive byte count differs for $site"),
    )
    get(receipt, "archive_sha256", nothing) == sha256_file(archive) ||
        throw(ArgumentError("external receipt archive hash differs for $site"))
    get(receipt, "trajectory_schema_sha256", nothing) ==
    sha256_file(schema_path) ||
        throw(ArgumentError("external receipt schema hash differs for $site"))
    for key in ("capture_receipt_sha256", "activity_report_sha256")
        valid_sha256(get(receipt, key, nothing)) ||
            throw(ArgumentError("external receipt lacks $key for $site"))
    end
    policy = inventory.policy_records[site]
    all(
        get(receipt, key, nothing) == get(policy, key, nothing) for
        key in RECEIPT_IDENTITY_FIELDS
    ) || throw(
        ArgumentError("external receipt policy identity differs for $site"),
    )
    provenance = get(receipt, "provenance", Dict())
    validate_real_provenance(
        merge(
            provenance,
            Dict(
                "reference_kind" => receipt["reference_kind"],
                "capture_schema" => receipt["oracle_contract"],
                "synthetic" => receipt["synthetic_data_used"],
                "stage_b_status" => receipt["stage_b_status"],
            ),
        ),
    )
    return receipt
end

"""
    validate_nonperturbation_evidence(path, site, expected_hash, step_count)

Require the SHA-bound exact 57-file comparison between the instrumented v5
capture and the fresh local Fortran oracle.
"""
function validate_nonperturbation_evidence(
    path,
    site,
    expected_hash,
    step_count,
)
    path = required_regular_file(path, "$site nonperturbation receipt")
    sha256_file(path) == expected_hash ||
        throw(ArgumentError("nonperturbation receipt hash differs for $site"))
    evidence = TOML.parsefile(path)
    gates = (
        get(evidence, "schema_version", nothing) == 1,
        get(evidence, "site", nothing) == site,
        get(evidence, "reference_kind", nothing) == "fresh_local_fortran",
        get(evidence, "candidate_kind", nothing) == "instrumented_stage_b_v5",
        get(evidence, "synthetic_data_used", nothing) === false,
        get(evidence, "result", nothing) == "pass",
        get(evidence, "criteria", nothing) ==
        "exact values, coordinates, masks, dimensions, types, and units",
        get(evidence, "compared_files", nothing) == 57,
        get(evidence, "failed_files", nothing) == 0,
    )
    all(gates) || throw(
        ArgumentError(
            "nonperturbation evidence is not an exact v5 pass for $site",
        ),
    )
    record_count = get(evidence, "record_count_per_daily_file", nothing)
    record_count isa Integer && record_count >= step_count || throw(
        ArgumentError(
            "nonperturbation evidence has insufficient records for $site",
        ),
    )
    return evidence
end

"""
    validate_structural_trajectory(root, schema_path, receipt, site)

Validate trajectory payloads and bind the contiguous manifest chronology to
the trusted seasonal bounds in a complete external receipt, without claiming
a Stage-B replay result.
"""
function validate_structural_trajectory(root, schema_path, receipt, site)
    validation = validate_bundle(root, schema_path)
    validation.ok || throw(
        ArgumentError(
            "bundle structure failed for $site: " *
            join(validation.issues, "; "),
        ),
    )
    manifest = validation.manifest
    get(manifest["trajectory"], "site", nothing) == site ||
        throw(ArgumentError("trajectory manifest site differs for $site"))
    steps = manifest["step"]
    length(steps) == get(receipt, "step_count", nothing) ||
        throw(ArgumentError("trajectory step count differs for $site"))
    capture_year = get(receipt, "capture_year", nothing)
    capture_year isa Integer ||
        throw(ArgumentError("trajectory receipt lacks capture year for $site"))
    expected_step_count = daysinyear(capture_year)
    length(steps) == expected_step_count || throw(
        ArgumentError("trajectory length differs from capture year for $site"),
    )
    get(receipt, "capture_event_count", nothing) == expected_step_count ||
        throw(ArgumentError("capture event count differs for $site"))
    get(receipt, "capture_source_calendar", nothing) == "standard" ||
        throw(ArgumentError("capture calendar differs for $site"))
    first_start = DateTime(first(steps)["time_start"])
    last_start = DateTime(last(steps)["time_start"])
    last_end = DateTime(last(steps)["time_end"])
    first_start == DateTime(capture_year, 1, 1) ||
        throw(ArgumentError("trajectory does not start January 1 for $site"))
    last_start == DateTime(capture_year, 12, 31) || throw(
        ArgumentError("trajectory last interval is not December 31 for $site"),
    )
    last_end == DateTime(capture_year + 1, 1, 1) ||
        throw(ArgumentError("trajectory does not end January 1 for $site"))
    first_start == DateTime(receipt["capture_first_time"]) ||
        throw(ArgumentError("trajectory start differs for $site"))
    last_start == DateTime(receipt["capture_last_time"]) ||
        throw(ArgumentError("trajectory last interval differs for $site"))
    last_end == DateTime(receipt["capture_next_year_start"]) ||
        throw(ArgumentError("trajectory end differs for $site"))
    return validation
end

function validate_embedded_receipts(root, external, site, schema_path)
    capture_path = joinpath(root, "capture_receipt.toml")
    activity_path = joinpath(root, "field_activity.toml")
    sha256_file(
        required_regular_file(capture_path, "$site packed capture receipt"),
    ) == external["capture_receipt_sha256"] ||
        throw(ArgumentError("packed capture receipt hash differs for $site"))
    sha256_file(
        required_regular_file(activity_path, "$site packed activity report"),
    ) == external["activity_report_sha256"] ||
        throw(ArgumentError("packed activity report hash differs for $site"))
    capture = TOML.parsefile(capture_path)
    for key in (
        "site",
        "status",
        "reference_kind",
        "oracle_contract",
        "synthetic_data_used",
        "complete_seasonal_cycle",
        "step_count",
        "capture_year",
        "capture_event_count",
        "capture_source_calendar",
        "capture_first_time",
        "capture_last_time",
        "capture_next_year_start",
        "trajectory_schema_sha256",
        "stage_b_status",
        "replay_claimed",
        "stage_c_semantics_excluded",
        "deferred_issue",
    )
        get(capture, key, nothing) == get(external, key, nothing) || throw(
            ArgumentError("packed capture receipt $key differs for $site"),
        )
    end
    capture_provenance = get(capture, "provenance", Dict())
    external_provenance = external["provenance"]
    all(
        get(capture_provenance, key, nothing) ==
        get(external_provenance, key, nothing) for key in REAL_PROVENANCE_HASHES
    ) || throw(ArgumentError("packed capture provenance differs for $site"))
    validate_nonperturbation_evidence(
        joinpath(root, "evidence", "nonperturbation_receipt.toml"),
        site,
        external_provenance["nonperturbation_receipt_sha256"],
        external["step_count"],
    )
    activity = classify_activity(TOML.parsefile(activity_path), schema_path)
    sort!(String.(get(external, "inactive_fields", Any[]))) ==
    activity.inactive_fields || throw(
        ArgumentError("external inactive-field inventory differs for $site"),
    )
    applicability = nothing
    if external["stage_b_status"] == "inactive"
        capture["replay_claimed"] === false ||
            throw(ArgumentError("inactive capture claims replay"))
        capture["stage_c_semantics_excluded"] === true ||
            throw(ArgumentError("inactive capture includes Stage-C semantics"))
        capture["deferred_issue"] == 108 ||
            throw(ArgumentError("inactive capture has wrong deferred issue"))
        evidence_path = joinpath(root, "evidence", "inactive_stage_b.toml")
        sha256_file(
            required_regular_file(evidence_path, "$site inactive evidence"),
        ) == external_provenance["inactive_stage_b_evidence_sha256"] ||
            throw(ArgumentError("inactive evidence hash differs for $site"))
        any(
            name -> startswith(name, "replay") && endswith(name, ".toml"),
            readdir(joinpath(root, "evidence")),
        ) && throw(ArgumentError("inactive archive contains replay evidence"))
        manifest = TOML.parsefile(joinpath(root, "manifest.toml"))
        manifest_evidence = get(manifest, "evidence", Dict())
        get(manifest_evidence, "inactive_stage_b_evidence_sha256", nothing) ==
        external_provenance["inactive_stage_b_evidence_sha256"] ||
            throw(ArgumentError("manifest inactive evidence hash differs"))
        get(manifest_evidence, "replay_claimed", nothing) === false ||
            throw(ArgumentError("manifest claims inactive replay"))
        validate_inactive_stage_b_evidence(
            evidence_path,
            site,
            root,
            manifest;
            expected_step_count = external["step_count"],
            expected_initial_condition_sha256 = external_provenance["site_initial_condition_sha256"],
            expected_job_options_sha256 = external_provenance["site_job_options_sha256"],
        )
        applicability = TOML.parsefile(evidence_path)
    else
        capture["replay_claimed"] === true ||
            throw(ArgumentError("active capture lacks replay claim"))
    end
    return (; capture, activity, applicability)
end

"""
    consume_site_archive(package, inventory, schema_path, verify_bundle,
                         transition_factory, replay_runner; tolerances)

Extract one validated package temporarily, execute the accepted CLASSIC
callback chronologically from initial state exactly once, and report every
state, flux, and carbon-budget error plus explicit pathway activity.
"""
function consume_site_archive(
    package,
    inventory,
    schema_path,
    verify_bundle,
    transition_factory,
    replay_runner;
    tolerances,
)
    external = validate_external_receipt(
        package.receipt,
        package.archive,
        package.site,
        inventory,
        schema_path,
    )
    validate_archive_headers(package.archive)
    return mktempdir() do root
        Tar.extract(package.archive, root)
        evidence = validate_embedded_receipts(
            root,
            external,
            package.site,
            schema_path,
        )
        structural = validate_structural_trajectory(
            root,
            schema_path,
            external,
            package.site,
        )
        if external["stage_b_status"] == "inactive"
            return (;
                site = package.site,
                ok = true,
                evidence_complete = true,
                stage_b_status = "inactive",
                stage_b_parity = false,
                excluded_from_stage_b_parity = true,
                deferred_issue = 108,
                replay_claimed = false,
                activity = evidence.activity,
                applicability = evidence.applicability,
                replay = nothing,
                evaluation = nothing,
                structural_validation = structural,
                steps = NamedTuple[],
                achieved_errors = nothing,
                tolerance_contract_sha256 = tolerances.sha256,
                tolerance_measurement_receipts = tolerances.measurement_receipts,
                max_state_errors = Dict{String, Float64}(),
                max_flux_errors = Dict{String, Float64}(),
                max_carbon_closure = 0.0,
                accumulated_drift = 0.0,
            )
        end
        acceptance = verify_bundle(root, schema_path)
        acceptance.ok || throw(
            ArgumentError(
                "bundle acceptance failed for $(package.site): " *
                join(acceptance.issues, "; "),
            ),
        )
        replay = acceptance.replay
        isnothing(replay) && throw(
            ArgumentError("accepted bundle has no replay for $(package.site)"),
        )
        length(replay.steps) == external["step_count"] || throw(
            ArgumentError("replay step count differs for $(package.site)"),
        )
        max_tolerance = maximum(
            Iterators.flatten((
                values(tolerances.state),
                values(tolerances.flux),
                values(tolerances.budget),
                values(tolerances.drift),
            ));
            init = 0.0,
        )
        report = replay_runner(
            replay,
            transition_factory(replay);
            atol = max_tolerance,
            rtol = 0.0,
            day_one_flux_tolerances = tolerances.flux,
            day_one_flux_tolerance_contract_sha256 = tolerances.sha256,
        )
        evaluation = evaluate_replay_report(
            report,
            tolerances,
            load_expanded_schema(schema_path),
        )
        fixture_provenance = merge(
            copy(replay.provenance),
            Dict(
                "schema_sha256" => sha256_file(schema_path),
                "source_receipt_sha256" => sha256_file(package.receipt),
                "source_package_sha256" => sha256_file(package.archive),
                "consumer_code_sha256" => sha256_file(@__FILE__),
            ),
        )
        fixture_steps = fixture_step_records(replay, report)
        day_one_ok =
            report.day_one_state_exact && report.day_one_flux_within_tolerance
        return (;
            site = package.site,
            ok = day_one_ok && evaluation.ok,
            reference_kind = external["reference_kind"],
            synthetic_data_used = external["synthetic_data_used"],
            evidence_complete = true,
            stage_b_status = "active",
            stage_b_parity = day_one_ok && evaluation.ok,
            activity = evidence.activity,
            fixture_static_data = deepcopy(replay.static_data),
            fixture_provenance,
            replay = report,
            evaluation,
            steps = fixture_steps,
            achieved_errors = (;
                state = report.max_state_errors,
                flux = report.max_flux_errors,
                budget = evaluation.max_budget_errors,
                drift = evaluation.max_drift_errors,
            ),
            tolerance_contract_sha256 = tolerances.sha256,
            tolerance_measurement_receipts = tolerances.measurement_receipts,
            max_state_errors = report.max_state_errors,
            max_flux_errors = report.max_flux_errors,
            max_carbon_closure = report.max_carbon_closure,
            accumulated_drift = report.accumulated_drift,
        )
    end
end

"""
    run_all_site_parity(consume, root, inventory)

Consume the exact canonical package inventory sequentially in sorted site
order. consume is a closure over consume_site_archive and the accepted bundle,
callback, and replay interfaces.
"""
function run_all_site_parity(consume, root, inventory)
    packages = validate_archive_set(root, inventory)
    reports = [consume(package) for package in packages]
    getindex.(reports, :site) == inventory.sites || throw(
        ArgumentError("site replay order differs from canonical inventory"),
    )
    all(
        report ->
            hasproperty(report, :evidence_complete) &&
            hasproperty(report, :stage_b_status) &&
            hasproperty(report, :stage_b_parity),
        reports,
    ) || throw(ArgumentError("site report lacks applicability result fields"))
    active = filter(report -> report.stage_b_status == "active", reports)
    inactive = filter(report -> report.stage_b_status == "inactive", reports)
    length(active) + length(inactive) == length(reports) ||
        throw(ArgumentError("site report has invalid Stage-B status"))
    evidence_complete = all(report -> report.evidence_complete, reports)
    active_stage_b_parity_complete =
        all(report -> report.stage_b_parity, active)
    return (;
        ok = evidence_complete && active_stage_b_parity_complete,
        evidence_complete,
        active_stage_b_parity_complete,
        active_site_count = length(active),
        inactive_site_count = length(inactive),
        active_stage_b_parity_pass_count = count(
            report -> report.stage_b_parity,
            active,
        ),
        site_count = length(reports),
        execution_order = "sequential",
        reports,
    )
end

function step_process_activity(step)
    activity = Dict{String, Float64}()
    for (pathway, fields) in PATHWAY_FIELDS
        activity[pathway] = sum(fields; init = 0.0) do name
            values = if haskey(step.drivers, name)
                step.drivers[name]
            elseif haskey(step.audit_diagnostics, name)
                step.audit_diagnostics[name]
            else
                throw(ArgumentError("step lacks process field $name"))
            end
            sum(abs, values)
        end
    end
    return activity
end

const DIFFICULT_EVENT_NAMES = (
    "freeze_thaw",
    "saturation",
    "drought",
    "large_inputs",
    "clamp",
    "turbation",
)
const TRANSFER_FIELDS = Tuple(
    vcat(
        [
            collect(fields) for
            (name, fields) in PATHWAY_FIELDS if name in (
                "competition",
                "land_use",
                "harvest",
                "turnover",
                "mortality",
                "disturbance",
            )
        ]...,
    ),
)
const CLAMP_FIELDS =
    ("audit.litter_clamp_correction", "audit.soil_clamp_correction")
const TURBATION_FIELDS = (
    "audit.turbation_delta_litter",
    "audit.turbation_delta_soil",
    "audit.turbation_litter_column_residual",
    "audit.turbation_soil_column_residual",
)

field_magnitude(fields, names) =
    sum(name -> sum(abs, fields[name]), names; init = 0.0)

function step_event_metrics(step, previous_step, static_data)
    tbar = step.drivers["driver.tbar"]
    tfrez = only(static_data["parameter.tfrez"])
    tcrit = only(static_data["parameter.tcrit"])
    frozen = tbar .- tfrez .<= tcrit
    freeze_thaw = if isnothing(previous_step)
        0
    else
        previous_frozen =
            previous_step.drivers["driver.tbar"] .- tfrez .<= tcrit
        count(frozen .!= previous_frozen)
    end
    thpor = static_data["static.thpor"]
    thliq = step.drivers["driver.thliq"]
    thice = step.drivers["driver.thice"]
    return Dict{String, Float64}(
        "freeze_thaw" => freeze_thaw,
        "saturation" => count((thliq .+ thice) .>= 0.95 .* thpor),
        "drought" => count(thliq .<= 0.10 .* thpor),
        "large_inputs" => field_magnitude(step.drivers, TRANSFER_FIELDS),
        "clamp" => field_magnitude(step.audit_diagnostics, CLAMP_FIELDS),
        "turbation" =>
            field_magnitude(step.audit_diagnostics, TURBATION_FIELDS),
    )
end

function fixture_step_records(replay, replay_report)
    length(replay.steps) == length(replay_report.steps) ||
        throw(ArgumentError("fixture chronology differs from replay report"))
    records = NamedTuple[]
    for position in eachindex(replay.steps)
        source = replay.steps[position]
        measured = replay_report.steps[position]
        source.index == measured.index || throw(
            ArgumentError("fixture step index differs from replay report"),
        )
        previous =
            position == firstindex(replay.steps) ? nothing :
            replay.steps[position - 1]
        push!(
            records,
            merge(
                measured,
                (;
                    time_start = source.time_start,
                    time_end = source.time_end,
                    process_activity = step_process_activity(source),
                    event_metrics = step_event_metrics(
                        source,
                        previous,
                        replay.static_data,
                    ),
                ),
            ),
        )
    end
    ordinary_position = argmin(eachindex(records)) do position
        rank = process_rank(records[position])
        (rank..., records[position].index)
    end
    difficult_position = argmax(eachindex(records)) do position
        rank = process_rank(records[position])
        (rank..., -records[position].index)
    end
    for position in Set((ordinary_position, difficult_position))
        source = replay.steps[position]
        initial_state = if position == firstindex(replay.steps)
            Dict(name => copy(values) for (name, values) in replay.initial_state)
        else
            previous = replay.steps[position - 1].reference_state
            Dict(
                "initial.litrmass" =>
                    copy(previous["reference.post_litrmass"]),
                "initial.soilcmas" =>
                    copy(previous["reference.post_soilcmas"]),
            )
        end
        records[position] = merge(
            records[position],
            (;
                initial_state,
                drivers = deepcopy(source.drivers),
                reference_state = deepcopy(source.reference_state),
                audit_diagnostics = deepcopy(source.audit_diagnostics),
            ),
        )
    end
    return records
end

function process_rank(step)
    hasproperty(step, :process_activity) && hasproperty(step, :event_metrics) ||
        throw(ArgumentError("fixture step lacks process-event activity"))
    process = step.process_activity
    events = step.event_metrics
    Set(keys(events)) == Set(DIFFICULT_EVENT_NAMES) ||
        throw(ArgumentError("fixture difficult-event inventory differs"))
    for activity_map in (process, events)
        isempty(activity_map) &&
            throw(ArgumentError("fixture activity is empty"))
        all(
            value -> value isa Real && isfinite(value) && value >= 0,
            values(activity_map),
        ) || throw(ArgumentError("fixture activity is invalid"))
    end
    return (
        count(!iszero, values(events)),
        sum(values(events); init = 0.0),
        count(!iszero, values(process)),
        sum(values(process); init = 0.0),
    )
end

"""
    select_fixture_candidates(reports, inventory)

Select ordinary and difficult steps only from sites whose policy inventory
explicitly approves redistribution with CC-BY-4.0, a resolved source chain,
and complete attribution. Selection uses process activation, never parity error.
"""
function select_fixture_candidates(reports, inventory)
    selected = NamedTuple[]
    for report in reports
        policy = inventory.policy_records[report.site]
        cleared =
            get(policy, "policy_status", nothing) == "cc_by_4" &&
            get(policy, "redistribution_status", nothing) == "approved" &&
            get(policy, "source_chain_status", nothing) == "complete" &&
            get(policy, "attribution_status", nothing) == "complete"
        cleared || continue
        report.ok || continue
        isempty(report.steps) && continue
        ordinary_position = argmin(eachindex(report.steps)) do index
            rank = process_rank(report.steps[index])
            (rank..., report.steps[index].index)
        end
        difficult_position = argmax(eachindex(report.steps)) do index
            rank = process_rank(report.steps[index])
            (rank..., -report.steps[index].index)
        end
        ordinary = report.steps[ordinary_position]
        difficult = report.steps[difficult_position]
        push!(
            selected,
            (
                site = report.site,
                ordinary_step = ordinary.index,
                difficult_step = difficult.index,
                ordinary_event_metrics = copy(ordinary.event_metrics),
                difficult_event_metrics = copy(difficult.event_metrics),
                difficult_event_coverage = sort!([
                    name for
                    (name, value) in difficult.event_metrics if value > 0
                ]),
                source_identifier = policy["source_identifier"],
                license_identifier = "CC-BY-4.0",
            ),
        )
    end
    return selected
end

function external_output_path(path, repository_root)
    isabspath(path) ||
        throw(ArgumentError("external output path must be absolute"))
    islink(path) &&
        throw(ArgumentError("external output path must not be a symlink"))
    parent = dirname(path)
    isdir(parent) && !islink(parent) || throw(
        ArgumentError(
            "external output parent must be an existing regular directory",
        ),
    )
    resolved_parent = realpath(parent)
    root = realpath(repository_root)
    output = joinpath(resolved_parent, basename(path))
    relative = relpath(output, root)
    outside =
        relative == ".." ||
        startswith(relative, ".." * Base.Filesystem.path_separator)
    outside ||
        throw(ArgumentError("external output resolves inside the repository"))
    return output
end

function selected_step(report, index)
    matches = filter(step -> step.index == index, report.steps)
    length(matches) == 1 ||
        throw(ArgumentError("selected fixture step is missing or duplicated"))
    return only(matches)
end

const FIXTURE_PROVENANCE_HASHES = (
    "source_archive_sha256",
    "source_tree_sha256",
    "executable_sha256",
    "parameter_namelist_sha256",
    "job_options_sha256",
    "initial_condition_sha256",
    "instrumentation_patch_sha256",
    "schema_sha256",
    "source_receipt_sha256",
    "source_package_sha256",
    "consumer_code_sha256",
)

function checked_fixture_provenance(report, schema_path)
    provenance = report.fixture_provenance
    all(
        key -> valid_sha256(get(provenance, key, nothing)),
        FIXTURE_PROVENANCE_HASHES,
    ) || throw(ArgumentError("compact fixture provenance is incomplete"))
    valid_commit(get(provenance, "source_commit", nothing)) ||
        throw(ArgumentError("compact fixture source commit is invalid"))
    provenance["schema_sha256"] == sha256_file(schema_path) ||
        throw(ArgumentError("compact fixture schema hash differs"))
    provenance["consumer_code_sha256"] == sha256_file(@__FILE__) ||
        throw(ArgumentError("compact fixture consumer code hash differs"))
    return provenance
end

function canonical_values(values, field, dimensions)
    shape = Tuple(dimensions[name] for name in field["dimensions"])
    count = prod(shape; init = 1)
    length(values) == count ||
        throw(ArgumentError("$(field["name"]) fixture shape differs"))
    element_type = field["dtype"] == "float64" ? Float64 : Int32
    return reshape(element_type.(vec(values)), shape)
end

function write_little_endian_fixture(path, values, dtype)
    mkpath(dirname(path))
    open(path, "w") do io
        if dtype == "float64"
            write(
                io,
                [htol(reinterpret(UInt64, value)) for value in vec(values)],
            )
        else
            write(
                io,
                [htol(reinterpret(UInt32, value)) for value in vec(values)],
            )
        end
    end
end

function fixture_record(bundle, field, dimensions, suffix, values)
    canonical = canonical_values(values, field, dimensions)
    relative = joinpath(
        "payloads",
        suffix,
        replace(field["name"], "." => "_") * ".bin",
    )
    path = joinpath(bundle, relative)
    write_little_endian_fixture(path, canonical, field["dtype"])
    return Dict(
        "name" => field["name"],
        "section" => field["section"],
        "role" => field["role"],
        "units" => field["units"],
        "dtype" => field["dtype"],
        "dimensions" => field["dimensions"],
        "shape" => collect(size(canonical)),
        "sampling" => field["sampling"],
        "application_phase" => field["application_phase"],
        "path" => relative,
        "bytes" => filesize(path),
        "sha256" => sha256_file(path),
    )
end

function fixture_values(report, step, field)
    section = field["section"]
    values = if section == "static_data"
        report.fixture_static_data
    elseif section == "initial_state"
        step.initial_state
    elseif section == "drivers"
        step.drivers
    elseif section == "reference_state"
        step.reference_state
    else
        step.audit_diagnostics
    end
    haskey(values, field["name"]) ||
        throw(ArgumentError("fixture lacks canonical field $(field["name"])"))
    return values[field["name"]]
end

function write_fixture_bundle(bundle, report, step, schema, schema_path)
    mkpath(bundle)
    dimensions =
        Dict(String(name) => value for (name, value) in schema["dimensions"])
    fixed_fields = filter(
        field -> field["section"] in ("static_data", "initial_state"),
        schema["field"],
    )
    dynamic_fields = filter(
        field -> field["section"] in
        ("drivers", "reference_state", "audit_diagnostics"),
        schema["field"],
    )
    fixed = [
        fixture_record(
            bundle,
            field,
            dimensions,
            "fixed",
            fixture_values(report, step, field),
        ) for field in fixed_fields
    ]
    dynamic = [
        fixture_record(
            bundle,
            field,
            dimensions,
            "step_00000001",
            fixture_values(report, step, field),
        ) for field in dynamic_fields
    ]
    source = checked_fixture_provenance(report, schema_path)
    provenance = Dict(String(key) => value for (key, value) in source)
    manifest = Dict(
        "schema_version" => 1,
        "storage_order" => schema["storage_order"],
        "endianness" => schema["endianness"],
        "trajectory" => Dict(
            "site" => report.site,
            "calendar" => schema["time"]["calendar"],
            "time_standard" => schema["time"]["time_standard"],
            "timestamp_format" => schema["time"]["timestamp_format"],
            "evidence_status" => "synthetic",
        ),
        "provenance" => provenance,
        "dimensions" => dimensions,
        "field" => fixed,
        "step" => [
            Dict(
                "index" => 1,
                "source_step_index" => step.index,
                "time_start" => string(step.time_start),
                "time_end" => string(step.time_end),
                "duration_days" => schema["time"]["step_days"],
                "field" => dynamic,
            ),
        ],
    )
    manifest_path = joinpath(bundle, "manifest.toml")
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted = true)
    end
    return manifest_path
end

"""
    pack_synthetic_compact_fixture(
        path,
        reports,
        inventory,
        schema_path;
        repository_root,
    )

Pack policy-cleared synthetic ordinary/difficult process steps as canonical
one-step bundles outside the Git repository. Real trajectory data and
scientific parity claims are rejected.
"""
function pack_synthetic_compact_fixture(
    path,
    reports,
    inventory,
    schema_path;
    repository_root,
)
    path = external_output_path(path, repository_root)
    ispath(path) && throw(ArgumentError("fixture archive already exists"))
    schema = load_expanded_schema(schema_path)
    candidates = select_fixture_candidates(reports, inventory)
    isempty(candidates) &&
        throw(ArgumentError("no policy-cleared fixture candidates"))
    difficult_coverage = Set{String}()
    for candidate in candidates
        union!(difficult_coverage, candidate.difficult_event_coverage)
    end
    difficult_coverage == Set(DIFFICULT_EVENT_NAMES) || throw(
        ArgumentError("compact fixtures do not cover every difficult event"),
    )
    by_site = Dict(report.site => report for report in reports)
    records = Dict{String, Any}[]
    mktempdir(dirname(path)) do stage
        for candidate in candidates
            report = by_site[candidate.site]
            getproperty(report, :reference_kind) == "synthetic" &&
            getproperty(report, :synthetic_data_used) === true || throw(
                ArgumentError(
                    "compact fixture input must be generated synthetic data",
                ),
            )
            for (role, index) in (
                "ordinary" => candidate.ordinary_step,
                "difficult" => candidate.difficult_step,
            )
                step = selected_step(report, index)
                bundle_relative =
                    joinpath("fixtures", "$(candidate.site)_$(role)")
                bundle = joinpath(stage, bundle_relative)
                manifest_path = write_fixture_bundle(
                    bundle,
                    report,
                    step,
                    schema,
                    schema_path,
                )
                provenance = checked_fixture_provenance(report, schema_path)
                push!(
                    records,
                    Dict(
                        "site" => candidate.site,
                        "role" => role,
                        "source_step_index" => index,
                        "event_metrics" => step.event_metrics,
                        "event_coverage" => sort!([
                            name for
                            (name, value) in step.event_metrics if value > 0
                        ]),
                        "process_activity" => step.process_activity,
                        "bundle_path" => bundle_relative,
                        "bundle_manifest_sha256" => sha256_file(manifest_path),
                        "source_identifier" => candidate.source_identifier,
                        "license_identifier" => candidate.license_identifier,
                        "source_receipt_sha256" =>
                            provenance["source_receipt_sha256"],
                        "source_package_sha256" =>
                            provenance["source_package_sha256"],
                        "consumer_code_sha256" =>
                            provenance["consumer_code_sha256"],
                    ),
                )
            end
        end
        manifest = Dict(
            "schema_version" => 1,
            "artifact_kind" => "synthetic_compact_fixture",
            "synthetic_data_used" => true,
            "scientific_parity_claimed" => false,
            "source_site_data_embedded" => false,
            "trajectory_schema_sha256" => sha256_file(schema_path),
            "fixture_packer_sha256" => sha256_file(@__FILE__),
            "selection_basis" => "explicit_event_coverage_then_process_magnitude",
            "fixture" => records,
        )
        open(joinpath(stage, "manifest.toml"), "w") do io
            TOML.print(io, manifest; sorted = true)
        end
        Tar.create(stage, path)
    end
    return (;
        path,
        sha256 = sha256_file(path),
        candidate_count = length(candidates),
        fixture_count = length(records),
        scientific_parity_claimed = false,
    )
end

end
