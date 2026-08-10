module ClassicMatrixExecution

import SHA
import TOML
import Tar

using Main.ClassicFreeReplay: FREE_REPLAY_UNITS, free_replay
using Main.ClassicToleranceContract:
    evaluate_replay_report, load_tolerance_contract
using Main.ClassicTrajectoryBundle: load_bundle_schema, verify_replay_acceptance
using Main.ClassicCallbackAdapter: classic_callback_transition

export archive_root_from_env,
    discover_matrix_archives,
    evaluate_replay_report,
    load_archive_manifest,
    load_tolerance_contract,
    run_real_matrix,
    selected_matrix_sites,
    validate_archive_member_paths,
    validate_field_activity,
    validate_site_archive_receipt

const SHA256_PATTERN = r"^[0-9a-f]{64}$"
const REQUIRED_REFERENCE_KIND = "fresh_local_fortran"
const REQUIRED_ORACLE_CONTRACT = "stage_b_v5"
const ARCHIVE_PATH_ROOT = "CLASSIC_STAGE_B_ARCHIVE_ROOT"

valid_sha256(value) =
    value isa AbstractString && occursin(SHA256_PATTERN, value)
sha256_file(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

function required_regular_file(path, label)
    isfile(path) || throw(ArgumentError("missing $label: $path"))
    islink(path) && throw(ArgumentError("$label must not be a symlink: $path"))
    filesize(path) > 0 || throw(ArgumentError("empty $label: $path"))
    return abspath(path)
end

function selected_matrix_sites(matrix)
    selections = get(matrix, "selection", Any[])
    classes = getindex.(selections, "class")
    expected_classes =
        ["tropical_warm_wet", "seasonal_dry", "wet_mineral", "cold_freeze_thaw"]
    classes == expected_classes ||
        throw(ArgumentError("process matrix classes or order differ"))
    sites = getindex.(selections, "site")
    length(sites) == 4 && length(unique(sites)) == 4 ||
        throw(ArgumentError("process matrix must select four unique sites"))
    return String.(sites)
end

function discover_matrix_archives(root, sites)
    isdir(root) || throw(ArgumentError("archive root does not exist: $root"))
    expected_archives = Set(site * ".tar" for site in sites)
    expected_receipts = Set(site * ".receipt.toml" for site in sites)
    actual_archives = Set(filter(name -> endswith(name, ".tar"), readdir(root)))
    actual_receipts = Set(
        filter(readdir(root)) do name
            endswith(name, ".receipt.toml") &&
                name != "campaign_extraction_receipt.toml"
        end,
    )
    actual_archives == expected_archives || throw(
        ArgumentError("archive inventory differs from the four-site matrix"),
    )
    actual_receipts == expected_receipts || throw(
        ArgumentError(
            "archive receipt inventory differs from the four-site matrix",
        ),
    )
    return Dict(
        site => (;
            archive = joinpath(root, site * ".tar"),
            receipt = joinpath(root, site * ".receipt.toml"),
        ) for site in sites
    )
end

"""
    archive_root_from_env([environment])

Return the explicit external root containing the canonical Stage B archives.
"""
function archive_root_from_env(environment = ENV)
    root = get(environment, ARCHIVE_PATH_ROOT, nothing)
    isnothing(root) && throw(
        ArgumentError("set $ARCHIVE_PATH_ROOT to the canonical archive root"),
    )
    return required_archive_root(root)
end

function required_archive_root(root)
    root isa AbstractString && isabspath(root) ||
        throw(ArgumentError("canonical archive root must be absolute"))
    isdir(root) || throw(ArgumentError("canonical archive root is unavailable"))
    islink(root) &&
        throw(ArgumentError("canonical archive root must not be a symlink"))
    return realpath(root)
end

function canonical_archive_identifier(identifier, label)
    identifier isa AbstractString && !isempty(identifier) ||
        throw(ArgumentError("$label identifier must be a nonempty string"))
    isabspath(identifier) &&
        throw(ArgumentError("$label identifier must be root relative"))
    normalized = normpath(identifier)
    normalized == identifier ||
        throw(ArgumentError("$label identifier must be normalized"))
    first(splitpath(normalized)) == ".." &&
        throw(ArgumentError("$label identifier escapes the archive root"))
    return normalized
end

function resolve_archive_identifier(root, identifier, label)
    relative = canonical_archive_identifier(identifier, label)
    candidate = required_regular_file(joinpath(root, relative), label)
    resolved = realpath(candidate)
    first(splitpath(normpath(relpath(resolved, root)))) == ".." &&
        throw(ArgumentError("$label resolves outside the archive root"))
    return resolved
end

"""
    load_archive_manifest(path, sites; archive_root)

Load the exact ordered four-site canonical archive inventory. Every checked
identifier is root-relative and resolves beneath an explicit, non-symlink
external archive root. Archive and receipt hashes must match the manifest.
"""
function load_archive_manifest(path, sites; archive_root = nothing)
    isnothing(archive_root) &&
        throw(ArgumentError("canonical archive root is required"))
    root = required_archive_root(archive_root)
    path = required_regular_file(path, "canonical archive manifest")
    document = TOML.parsefile(path)
    get(document, "schema_version", nothing) == 2 ||
        throw(ArgumentError("unsupported canonical archive manifest"))
    get(document, "path_root", nothing) == ARCHIVE_PATH_ROOT ||
        throw(ArgumentError("canonical archive manifest root label differs"))
    records = get(document, "site", Any[])
    names = [get(record, "site", "") for record in records]
    names == sites ||
        throw(ArgumentError("canonical archive manifest site order differs"))
    length(unique(names)) == length(names) ||
        throw(ArgumentError("canonical archive manifest has duplicates"))
    archives = Dict{String, NamedTuple}()
    for record in records
        site = record["site"]
        archive_path = resolve_archive_identifier(
            root,
            get(record, "archive_id", ""),
            "$site canonical archive",
        )
        receipt_path = resolve_archive_identifier(
            root,
            get(record, "receipt_id", ""),
            "$site canonical receipt",
        )
        archive_sha = get(record, "archive_sha256", "")
        receipt_sha = get(record, "receipt_sha256", "")
        valid_sha256(archive_sha) && sha256_file(archive_path) == archive_sha ||
            throw(ArgumentError("$site canonical archive SHA-256 differs"))
        valid_sha256(receipt_sha) && sha256_file(receipt_path) == receipt_sha ||
            throw(ArgumentError("$site canonical receipt SHA-256 differs"))
        archives[site] = (; archive = archive_path, receipt = receipt_path)
    end
    return (; archives, sites = names, sha256 = sha256_file(path), path)
end

function validate_site_archive_receipt(
    receipt_path,
    archive_path,
    expected_site,
    expected_schema_sha256,
)
    receipt_path = required_regular_file(receipt_path, "$expected_site receipt")
    archive_path = required_regular_file(archive_path, "$expected_site archive")
    receipt = TOML.parsefile(receipt_path)
    required = (
        "schema_version",
        "site",
        "status",
        "reference_kind",
        "oracle_contract",
        "synthetic_data_used",
        "complete_seasonal_cycle",
        "step_count",
        "archive_path",
        "archive_sha256",
        "archive_bytes",
        "trajectory_schema_sha256",
        "capture_receipt_sha256",
        "activity_report_sha256",
        "missing_fields",
        "inactive_fields",
        "artifact_policy",
    )
    all(haskey(receipt, key) for key in required) ||
        throw(ArgumentError("$expected_site archive receipt is incomplete"))
    receipt["schema_version"] == 1 ||
        throw(ArgumentError("unsupported archive receipt schema"))
    receipt["site"] == expected_site ||
        throw(ArgumentError("archive receipt site differs"))
    receipt["status"] == "complete" ||
        throw(ArgumentError("site archive is not complete"))
    receipt["reference_kind"] == REQUIRED_REFERENCE_KIND ||
        throw(ArgumentError("site archive is not fresh local Fortran"))
    receipt["oracle_contract"] == REQUIRED_ORACLE_CONTRACT ||
        throw(ArgumentError("site archive does not use Stage B v5"))
    receipt["synthetic_data_used"] === false ||
        throw(ArgumentError("synthetic site archive cannot be accepted"))
    receipt["complete_seasonal_cycle"] === true ||
        throw(ArgumentError("site archive lacks a complete seasonal cycle"))
    receipt["step_count"] isa Integer && receipt["step_count"] >= 365 ||
        throw(ArgumentError("site archive has fewer than 365 daily steps"))
    normpath(receipt["archive_path"]) == normpath(archive_path) ||
        throw(ArgumentError("archive receipt path differs"))
    receipt["archive_bytes"] == filesize(archive_path) ||
        throw(ArgumentError("archive receipt byte count differs"))
    valid_sha256(receipt["archive_sha256"]) &&
        receipt["archive_sha256"] == sha256_file(archive_path) ||
        throw(ArgumentError("archive SHA-256 differs"))
    receipt["trajectory_schema_sha256"] == expected_schema_sha256 ||
        throw(ArgumentError("trajectory schema SHA-256 differs"))
    for key in ("capture_receipt_sha256", "activity_report_sha256")
        valid_sha256(receipt[key]) ||
            throw(ArgumentError("archive receipt lacks valid $key"))
    end
    isempty(receipt["missing_fields"]) ||
        throw(ArgumentError("site archive has missing fields"))
    receipt["inactive_fields"] isa AbstractVector ||
        throw(ArgumentError("site archive lacks explicit inactive fields"))
    receipt["artifact_policy"] == "external_only" ||
        throw(ArgumentError("site archive is not external-only"))
    return receipt
end

function validate_field_activity(path, schema)
    path = required_regular_file(path, "field activity report")
    report = TOML.parsefile(path)
    get(report, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported field activity schema"))
    fields = get(report, "field", Any[])
    expected = Dict(field["name"] => field for field in schema["field"])
    names = [get(field, "name", "") for field in fields]
    length(names) == length(unique(names)) ||
        throw(ArgumentError("field activity contains duplicates"))
    Set(names) == Set(keys(expected)) ||
        throw(ArgumentError("field activity inventory differs from schema"))
    active_fields = String[]
    inactive_fields = String[]
    active_pathways = String[]
    inactive_pathways = String[]
    for record in fields
        name = record["name"]
        all(
            haskey(record, key) for key in
            ("present", "active", "nonzero_count", "maximum_absolute_value")
        ) || throw(ArgumentError("$name activity metadata is incomplete"))
        record["present"] === true ||
            throw(ArgumentError("$name is absent from the packed bundle"))
        record["active"] isa Bool ||
            throw(ArgumentError("$name active flag is not Boolean"))
        count = record["nonzero_count"]
        maximum = record["maximum_absolute_value"]
        count isa Integer && count >= 0 ||
            throw(ArgumentError("$name nonzero count is invalid"))
        maximum isa Real && isfinite(maximum) && maximum >= 0 ||
            throw(ArgumentError("$name maximum magnitude is invalid"))
        (count == 0) == iszero(maximum) || throw(
            ArgumentError("$name activity count and magnitude contradict"),
        )
        observed_active = count > 0 && maximum > 0
        record["active"] == observed_active || throw(
            ArgumentError("$name active flag contradicts measured values"),
        )
        push!(record["active"] ? active_fields : inactive_fields, name)
        section = expected[name]["section"]
        if section in ("drivers", "audit_diagnostics")
            push!(record["active"] ? active_pathways : inactive_pathways, name)
        end
    end
    return (;
        active_fields = sort!(active_fields),
        inactive_fields = sort!(inactive_fields),
        active_pathways = sort!(active_pathways),
        inactive_pathways = sort!(inactive_pathways),
    )
end

function validate_archive_member_paths(paths)
    isempty(paths) && throw(ArgumentError("site archive is empty"))
    length(paths) == length(unique(paths)) ||
        throw(ArgumentError("site archive contains duplicate members"))
    for path in paths
        path isa AbstractString ||
            throw(ArgumentError("archive member path is not a string"))
        isabspath(path) && throw(ArgumentError("archive member is absolute"))
        normalized = normpath(path)
        (isempty(path) || normalized == ".") &&
            throw(ArgumentError("archive member path is empty"))
        (
            normalized == ".." ||
            startswith(normalized, ".." * Base.Filesystem.path_separator)
        ) && throw(ArgumentError("archive member escapes extraction root"))
    end
    allowed_roots = Set((
        "manifest.toml",
        "capture_receipt.toml",
        "field_activity.toml",
        "payloads",
        "evidence",
    ))
    all(first(splitpath(normpath(path))) in allowed_roots for path in paths) ||
        throw(
            ArgumentError(
                "site archive contains an unexpected top-level member",
            ),
        )

    required =
        Set(("manifest.toml", "capture_receipt.toml", "field_activity.toml"))
    required ⊆ Set(paths) ||
        throw(ArgumentError("site archive lacks required control files"))
    return true
end

function extract_site_archive(archive_path, destination)
    ispath(destination) &&
        throw(ArgumentError("extraction destination already exists"))
    headers = Tar.list(archive_path)
    validate_archive_member_paths([header.path for header in headers])
    all(header -> header.type in (:file, :directory), headers) ||
        throw(ArgumentError("site archive contains links or special files"))
    mkpath(destination)
    Tar.extract(archive_path, destination)
    for (root, directories, files) in walkdir(destination)
        all(name -> !islink(joinpath(root, name)), directories) ||
            throw(ArgumentError("extracted archive contains a directory link"))
        all(name -> !islink(joinpath(root, name)), files) ||
            throw(ArgumentError("extracted archive contains a file link"))
    end
    return destination
end

function run_site_archive(
    site,
    paths,
    schema_path,
    schema,
    schema_sha256,
    tolerances,
)
    receipt = validate_site_archive_receipt(
        paths.receipt,
        paths.archive,
        site,
        schema_sha256,
    )
    return mktempdir() do directory
        root = extract_site_archive(paths.archive, joinpath(directory, site))
        capture_receipt = required_regular_file(
            joinpath(root, "capture_receipt.toml"),
            "$site embedded capture receipt",
        )
        activity_path = required_regular_file(
            joinpath(root, "field_activity.toml"),
            "$site field activity report",
        )
        sha256_file(capture_receipt) == receipt["capture_receipt_sha256"] ||
            throw(
                ArgumentError("$site embedded capture receipt SHA-256 differs"),
            )
        sha256_file(activity_path) == receipt["activity_report_sha256"] ||
            throw(ArgumentError("$site field activity SHA-256 differs"))
        activity = validate_field_activity(activity_path, schema)
        sort!(copy(receipt["inactive_fields"])) == activity.inactive_fields ||
            throw(ArgumentError("$site inactive field receipt differs"))
        acceptance = verify_replay_acceptance(root, schema_path)
        acceptance.ok || throw(
            ArgumentError(
                "$site trajectory evidence failed: $(join(acceptance.issues, "; "))",
            ),
        )
        acceptance.validation.manifest["trajectory"]["site"] == site ||
            throw(ArgumentError("trajectory manifest site differs"))
        length(acceptance.replay.steps) == receipt["step_count"] ||
            throw(ArgumentError("trajectory step count differs from receipt"))
        max_tolerance = maximum(
            Iterators.flatten((
                values(tolerances.state),
                values(tolerances.flux),
                values(tolerances.budget),
                values(tolerances.drift),
            ));
            init = 0.0,
        )
        transition = classic_callback_transition(acceptance.replay)
        report = free_replay(
            acceptance.replay,
            transition;
            atol = max_tolerance,
            rtol = 0.0,
        )
        evaluation = evaluate_replay_report(report, tolerances, schema)
        return (;
            site,
            receipt,
            receipt_sha256 = sha256_file(paths.receipt),
            activity,
            evaluation,
        )
    end
end

function write_matrix_receipt(
    path,
    matrix,
    results,
    tolerances,
    schema_sha256,
    tolerance_sha256,
    archive_manifest_sha256,
)
    ispath(path) && throw(ArgumentError("matrix receipt already exists"))
    all_green = all(result -> result.evaluation.ok, results)
    receipt = Dict{String, Any}(
        "schema_version" => 1,
        "status" => all_green ? "complete" : "failed",
        "reference_kind" => REQUIRED_REFERENCE_KIND,
        "oracle_contract" => REQUIRED_ORACLE_CONTRACT,
        "synthetic_data_used" => false,
        "site_count" => length(results),
        "sites" => getproperty.(results, :site),
        "state_comparisons_passed" =>
            all(result -> result.evaluation.state_ok, results),
        "flux_comparisons_passed" =>
            all(result -> result.evaluation.flux_ok, results),
        "budget_comparisons_passed" =>
            all(result -> result.evaluation.budget_ok, results),
        "drift_comparisons_passed" =>
            all(result -> result.evaluation.drift_ok, results),
        "tolerance_rationale" => tolerances.rationale,
        "units" => FREE_REPLAY_UNITS,
        "matrix_selection_sha256" => sha256_file(matrix),
        "trajectory_schema_sha256" => schema_sha256,
        "tolerance_contract_sha256" => tolerance_sha256,
        "archive_manifest_sha256" => archive_manifest_sha256,
        "tolerances" => Dict(
            "contract_sha256" => tolerances.sha256,
            "measurement_receipts" => [
                Dict(
                    "evidence_id" => receipt.evidence_id,
                    "sha256" => receipt.sha256,
                ) for receipt in tolerances.measurement_receipts
            ],
        ),
        "site" => [
            Dict(
                "name" => result.site,
                "status" => result.evaluation.ok ? "pass" : "fail",
                "archive_sha256" => result.receipt["archive_sha256"],
                "archive_receipt_sha256" => result.receipt_sha256,
                "capture_receipt_sha256" =>
                    result.receipt["capture_receipt_sha256"],
                "activity_report_sha256" =>
                    result.receipt["activity_report_sha256"],
                "active_pathways" => result.activity.active_pathways,
                "inactive_pathways" => result.activity.inactive_pathways,
                "max_state_errors" => result.evaluation.max_state_errors,
                "max_flux_errors" => result.evaluation.max_flux_errors,
                "max_budget_errors" => result.evaluation.max_budget_errors,
                "max_drift_errors" => result.evaluation.max_drift_errors,
                "failure_localization" =>
                    result.evaluation.failure_localization,
            ) for result in results
        ],
    )
    open(path, "w") do io
        TOML.print(io, receipt; sorted = true)
    end
    return receipt
end

function run_real_matrix(
    archive_source,
    output_receipt;
    evidence_root,
    archive_root = nothing,
    matrix_path = joinpath(@__DIR__, "selection_matrix.toml"),
    schema_path = joinpath(@__DIR__, "..", "trajectory_bundle", "schema.toml"),
    tolerance_path = joinpath(@__DIR__, "tolerances.toml"),
)
    matrix = TOML.parsefile(matrix_path)
    sites = selected_matrix_sites(matrix)
    source = if isfile(archive_source)
        load_archive_manifest(archive_source, sites; archive_root)
    else
        (; archives = discover_matrix_archives(archive_source, sites), sha256 = "")
    end
    inventory = source.archives
    schema = load_bundle_schema(schema_path)
    schema_sha256 = sha256_file(schema_path)
    tolerances = load_tolerance_contract(tolerance_path, schema; evidence_root)
    results = [
        run_site_archive(
            site,
            inventory[site],
            schema_path,
            schema,
            schema_sha256,
            tolerances,
        ) for site in sites
    ]
    return write_matrix_receipt(
        output_receipt,
        matrix_path,
        results,
        tolerances,
        schema_sha256,
        sha256_file(tolerance_path),
        source.sha256,
    )
end

end
