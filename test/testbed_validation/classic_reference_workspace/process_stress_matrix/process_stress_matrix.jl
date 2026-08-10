module CLASSICProcessStressMatrix

import SHA
import TOML

export matrix_acceptance_ready,
    root_relative_path,
    selection_passes,
    verify_input_receipt,
    write_input_receipt

const INPUT_PATH_ROOT = "CLASSIC_REFERENCE_ROOT"

const CLASS_CRITERIA = Dict(
    "tropical_warm_wet" => (
        "absolute_latitude_max_deg",
        "mean_air_temperature_min_c",
        "annual_precipitation_min_mm",
        "dry_month_fraction_max",
    ),
    "seasonal_dry" => (
        "mean_air_temperature_min_c",
        "dry_month_fraction_min",
        "maximum_dry_spell_min_days",
    ),
    "wet_mineral" => (
        "absolute_latitude_min_deg",
        "annual_precipitation_min_mm",
        "dry_month_fraction_max",
        "mineral_layer_fraction_min",
        "initial_mineral_liquid_water_min_m3_m3",
    ),
    "cold_freeze_thaw" => (
        "mean_air_temperature_max_c",
        "minimum_air_temperature_max_c",
        "subzero_day_fraction_min",
        "freeze_thaw_transition_count_min",
    ),
)

const CRITERION_METRIC = Dict(
    "absolute_latitude_max_deg" => "absolute_latitude_deg",
    "absolute_latitude_min_deg" => "absolute_latitude_deg",
    "mean_air_temperature_min_c" => "air_temperature_mean_c",
    "mean_air_temperature_max_c" => "air_temperature_mean_c",
    "minimum_air_temperature_max_c" => "air_temperature_min_c",
    "annual_precipitation_min_mm" => "annual_precipitation_mean_mm",
    "dry_month_fraction_min" => "dry_month_fraction",
    "dry_month_fraction_max" => "dry_month_fraction",
    "maximum_dry_spell_min_days" => "maximum_dry_spell_days",
    "mineral_layer_fraction_min" => "mineral_layer_fraction",
    "initial_mineral_liquid_water_min_m3_m3" => "initial_mineral_liquid_water_mean_m3_m3",
    "subzero_day_fraction_min" => "subzero_day_fraction",
    "freeze_thaw_transition_count_min" => "freeze_thaw_transition_count",
)

function required_regular_file(path, label)
    isfile(path) || throw(ArgumentError("missing $label: $path"))
    islink(path) && throw(ArgumentError("$label must not be a symlink: $path"))
    filesize(path) > 0 || throw(ArgumentError("empty $label: $path"))
    return abspath(path)
end

function required_external_root(path)
    isdir(path) ||
        throw(ArgumentError("missing external reference root: $path"))
    return realpath(path)
end

function validated_relative_identifier(identifier, label)
    identifier isa AbstractString ||
        throw(ArgumentError("$label identifier must be a string"))
    isempty(identifier) && throw(ArgumentError("empty $label identifier"))
    isabspath(identifier) &&
        throw(ArgumentError("$label identifier must be root relative"))
    normalized = normpath(identifier)
    normalized == identifier ||
        throw(ArgumentError("$label identifier must be normalized"))
    first(splitpath(normalized)) == ".." &&
        throw(ArgumentError("$label identifier escapes the external root"))
    return normalized
end

function root_relative_path(path, external_root, label)
    root = required_external_root(external_root)
    resolved = realpath(required_regular_file(path, label))
    identifier = normpath(relpath(resolved, root))
    first(splitpath(identifier)) == ".." &&
        throw(ArgumentError("$label is outside the external reference root"))
    return identifier
end

function resolve_input_path(identifier, external_root, label)
    relative = validated_relative_identifier(identifier, label)
    root = required_external_root(external_root)
    resolved = realpath(required_regular_file(joinpath(root, relative), label))
    first(splitpath(normpath(relpath(resolved, root)))) == ".." && throw(
        ArgumentError("$label resolves outside the external reference root"),
    )
    return resolved
end

sha256_file(path) = bytes2hex(open(SHA.sha256, path))

function selection_passes(class_name, metrics, criteria)
    expected = get(CLASS_CRITERIA, class_name, nothing)
    isnothing(expected) &&
        throw(ArgumentError("unknown process class: $class_name"))
    for criterion in keys(criteria)
        criterion in expected ||
            throw(ArgumentError("unexpected $class_name criterion: $criterion"))
    end
    for criterion in expected
        haskey(criteria, criterion) ||
            throw(ArgumentError("missing $class_name criterion: $criterion"))
        metric_name = CRITERION_METRIC[criterion]
        haskey(metrics, metric_name) ||
            throw(ArgumentError("missing metric: $metric_name"))
        value = metrics[metric_name]
        threshold = criteria[criterion]
        isfinite(value) ||
            throw(ArgumentError("non-finite metric: $metric_name"))
        if occursin("_min_", criterion) || endswith(criterion, "_min")
            value >= threshold || return false
        elseif occursin("_max_", criterion) || endswith(criterion, "_max")
            value <= threshold || return false
        else
            throw(
                ArgumentError("criterion has no min/max direction: $criterion"),
            )
        end
    end
    return true
end

function write_input_receipt(
    output,
    site,
    inputs,
    external_root;
    provenance = Dict{String, Any}(),
)
    required_labels = Set((
        "site_metadata",
        "air_temperature_forcing",
        "precipitation_forcing",
        "prepared_initialization",
    ))
    Set(keys(inputs)) == required_labels || throw(
        ArgumentError(
            "input labels must be exactly $(sort!(collect(required_labels)))",
        ),
    )
    absolute_paths = Dict(
        label => required_regular_file(path, label) for (label, path) in inputs
    )
    paths = Dict(
        label => root_relative_path(path, external_root, label) for
        (label, path) in absolute_paths
    )
    receipt = Dict{String, Any}(
        "schema_version" => 2,
        "path_root" => INPUT_PATH_ROOT,
        "site" => site,
        "raw_data_embedded" => false,
        "input_path" => paths,
        "input_sha256" => Dict(
            label => sha256_file(path) for (label, path) in absolute_paths
        ),
        "provenance" => provenance,
    )
    mkpath(dirname(output))
    temporary = output * ".tmp"
    open(temporary, "w") do io
        TOML.print(io, receipt; sorted = true)
    end
    mv(temporary, output; force = true)
    return output
end

function verify_input_receipt(path, external_root)
    required_regular_file(path, "input receipt")
    receipt = TOML.parsefile(path)
    get(receipt, "schema_version", 0) == 2 ||
        throw(ArgumentError("unsupported input receipt schema"))
    get(receipt, "path_root", "") == INPUT_PATH_ROOT ||
        throw(ArgumentError("unsupported input path root"))
    get(receipt, "raw_data_embedded", true) == false ||
        throw(ArgumentError("receipt must not embed raw data"))
    paths = get(receipt, "input_path", nothing)
    hashes = get(receipt, "input_sha256", nothing)
    paths isa AbstractDict || throw(ArgumentError("missing input paths"))
    hashes isa AbstractDict || throw(ArgumentError("missing input hashes"))
    Set(keys(paths)) == Set(keys(hashes)) ||
        throw(ArgumentError("input path/hash label mismatch"))
    for (label, identifier) in paths
        regular_path = resolve_input_path(identifier, external_root, label)
        sha256_file(regular_path) == hashes[label] ||
            throw(ArgumentError("input checksum mismatch: $label"))
    end
    return true
end

function matrix_acceptance_ready(
    matrix,
    seasonal_receipt_path;
    matrix_path,
    manifest_path,
    tolerance_path,
    schema_path,
)
    acceptance = get(matrix, "acceptance", Dict{String, Any}())
    get(acceptance, "status", "blocked") == "ready_for_acceptance" ||
        return false
    get(acceptance, "seasonal_parity_claimed", false) || return false
    isnothing(seasonal_receipt_path) && return false
    checked = try
        (
            matrix = required_regular_file(matrix_path, "matrix selection"),
            manifest = required_regular_file(
                manifest_path,
                "canonical archive manifest",
            ),
            tolerance = required_regular_file(
                tolerance_path,
                "tolerance contract",
            ),
            schema = required_regular_file(schema_path, "trajectory schema"),
            receipt = required_regular_file(
                seasonal_receipt_path,
                "seasonal receipt",
            ),
        )
    catch
        return false
    end
    checked_matrix = try
        TOML.parsefile(checked.matrix)
    catch
        return false
    end
    checked_matrix == matrix || return false
    manifest_identifier = try
        validated_relative_identifier(
            get(acceptance, "canonical_archive_manifest", ""),
            "canonical archive manifest",
        )
    catch
        return false
    end
    expected_manifest = try
        required_regular_file(
            joinpath(dirname(checked.matrix), manifest_identifier),
            "canonical archive manifest",
        )
    catch
        return false
    end
    realpath(checked.manifest) == realpath(expected_manifest) || return false
    checked_hashes = (
        matrix = sha256_file(checked.matrix),
        manifest = sha256_file(checked.manifest),
        tolerance = sha256_file(checked.tolerance),
        schema = sha256_file(checked.schema),
    )
    get(acceptance, "canonical_archive_manifest_sha256", "") ==
    checked_hashes.manifest || return false
    manifest = try
        TOML.parsefile(checked.manifest)
    catch
        return false
    end
    get(manifest, "schema_version", 0) == 2 || return false
    get(manifest, "path_root", "") == "CLASSIC_STAGE_B_ARCHIVE_ROOT" ||
        return false
    manifest_sites = get(manifest, "site", nothing)
    manifest_sites isa AbstractVector || return false
    selections = get(matrix, "selection", Any[])
    selected_sites = [selection["site"] for selection in selections]
    [get(site, "site", "") for site in manifest_sites] == selected_sites || return false
    manifest_by_site = Dict(
        site["site"] => site for site in manifest_sites if haskey(site, "site")
    )
    length(manifest_by_site) == length(selected_sites) || return false
    receipt = try
        TOML.parsefile(checked.receipt)
    catch
        return false
    end
    get(receipt, "schema_version", 0) == 1 || return false
    get(receipt, "status", "incomplete") == "complete" || return false
    get(receipt, "reference_kind", "") == "fresh_local_fortran" || return false
    get(receipt, "oracle_contract", "") ==
    get(acceptance, "required_oracle_contract", "stage_b_v5") || return false
    get(receipt, "synthetic_data_used", true) == false || return false
    get(receipt, "matrix_selection_sha256", "") == checked_hashes.matrix ||
        return false
    get(receipt, "archive_manifest_sha256", "") == checked_hashes.manifest ||
        return false
    get(receipt, "tolerance_contract_sha256", "") == checked_hashes.tolerance ||
        return false
    get(receipt, "trajectory_schema_sha256", "") == checked_hashes.schema ||
        return false
    tolerance_evidence = get(receipt, "tolerances", nothing)
    tolerance_evidence isa AbstractDict || return false
    get(tolerance_evidence, "contract_sha256", "") ==
    checked_hashes.tolerance || return false
    get(receipt, "site_count", 0) == length(selections) || return false
    receipt_sites = get(receipt, "sites", String[])
    sort!(String.(receipt_sites)) == sort(selected_sites) || return false
    get(receipt, "state_comparisons_passed", false) || return false
    get(receipt, "flux_comparisons_passed", false) || return false
    get(receipt, "budget_comparisons_passed", false) || return false
    get(receipt, "drift_comparisons_passed", false) || return false
    isempty(get(receipt, "tolerance_rationale", "")) && return false
    site_results = get(receipt, "site", Any[])
    length(site_results) == length(selected_sites) || return false
    sort!([get(site, "name", "") for site in site_results]) == sort(selected_sites) ||
        return false
    for site in site_results
        get(site, "status", "fail") == "pass" || return false
        name = get(site, "name", "")
        haskey(manifest_by_site, name) || return false
        manifest_site = manifest_by_site[name]
        archive_hash = get(site, "archive_sha256", "")
        occursin(r"^[0-9a-f]{64}$", archive_hash) || return false
        archive_hash == get(manifest_site, "archive_sha256", "") || return false
        get(site, "archive_receipt_sha256", "") ==
        get(manifest_site, "receipt_sha256", "") || return false
        for key in (
            "max_state_errors",
            "max_flux_errors",
            "max_budget_errors",
            "max_drift_errors",
        )
            errors = get(site, key, nothing)
            errors isa AbstractDict && !isempty(errors) || return false
            all(
                value isa Real && isfinite(value) for value in values(errors)
            ) || return false
        end
        isempty(get(site, "failure_localization", Any[])) || return false
    end
    return true
end

end
