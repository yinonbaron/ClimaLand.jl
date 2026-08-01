module TestbedPinnedCORPSEAdapter

import SHA
import Tar
import TOML

const CORPSE_ROLES = (
    "boundaries",
    "boundaries_manifest",
    "reduced_history",
    "reduced_history_manifest",
)
const COMPATIBILITY_KEYS = (
    "scope_manifest_sha256",
    "forcing_sha256",
    "shared_parameter_sha256",
    "comparison_schema",
)
const CORPSE_STAGES = Dict(
    "prespin" => "01-prespin",
    "spin" => "02-spin",
    "spin_continuation" => "03-spin_continuation",
    "historical" => "04-historical",
)
const BOUNDARY_MEMBER_NAMES =
    ("casa_final.csv", "corpse_final.csv", "grid.csv", "stage_metadata.toml")
const EXPECTED_BOUNDARY_MEMBERS = Set((
    "reconstruction_report.toml",
    (
        "stages/$directory/$name" for directory in values(CORPSE_STAGES) for
        name in BOUNDARY_MEMBER_NAMES
    )...,
))
const REDUCERS =
    Set(("annual_mean", "end_of_year", "annual_total", "fixed_daily_sample"))

struct AdapterError <: Exception
    message::String
end

Base.showerror(io::IO, error::AdapterError) = print(io, error.message)

fail(message) = throw(AdapterError(message))

sha256sum(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

function parse_toml(path, description)
    isfile(path) || fail("$description is missing at $path")
    islink(path) && fail("$description must not be a symbolic link")
    try
        return TOML.parsefile(path)
    catch error
        fail("$description is unreadable: $(sprint(showerror, error))")
    end
end

valid_sha256(value) =
    value isa AbstractString && occursin(r"^[0-9a-f]{64}$", value)

function safe_payload_path(root, relative, description)
    relative isa AbstractString && !isempty(relative) ||
        fail("$description has an invalid payload path")
    isabspath(relative) && fail("$description has an unsafe payload path")
    parts = splitpath(relative)
    any(part -> part in (".", ".."), parts) &&
        fail("$description has an unsafe payload path")
    path = joinpath(root, parts...)
    current = root
    for part in parts
        current = joinpath(current, part)
        islink(current) && fail("$description must not contain symbolic links")
    end
    isfile(path) || fail("$description is missing at $path")
    return path
end

"""
    validate_bundle(root, kind, roles; model = nothing)

Verify a bundle manifest, required payload roles, checksums, and provenance.

Called from `pinned_corpse_bundle` and `forcing_bundle` before payload resolution.
"""
function validate_bundle(root, kind, roles; model = nothing)
    isdir(root) || fail("$kind bundle is missing at $root")
    islink(root) && fail("$kind bundle must not be a symbolic link")
    description = isnothing(model) ? kind : "$model reference"
    manifest =
        parse_toml(joinpath(root, "manifest.toml"), "$description manifest")
    get(manifest, "schema_version", nothing) == 1 ||
        fail("$description manifest has an incompatible schema")
    get(manifest, "kind", nothing) == kind ||
        fail("$description manifest declares the wrong kind")
    get(manifest, "scope", nothing) == "representative" ||
        fail("$description manifest is not Representative")
    if isnothing(model)
        haskey(manifest, "model") &&
            fail("$description manifest must not declare a model")
    else
        get(manifest, "model", nothing) == model ||
            fail("$description manifest declares the wrong model")
    end
    files = get(manifest, "files", nothing)
    files isa AbstractDict || fail("$description manifest lacks files")
    payload = get(manifest, "payload", nothing)
    payload isa AbstractDict ||
        fail("$description manifest lacks payload roles")
    Set(String.(keys(payload))) == Set(roles) ||
        fail("$description manifest has incompatible payload roles")

    paths = Dict{String, String}()
    for role in roles
        relative = payload[role]
        haskey(files, relative) ||
            fail("$description $role payload is not declared as a file")
        expected = files[relative]
        valid_sha256(expected) ||
            fail("$description $role payload has an invalid SHA-256")
        path = safe_payload_path(root, relative, "$description $role payload")
        sha256sum(path) == expected ||
            fail("$description $role payload differs from its manifest")
        paths[role] = path
    end
    length(unique(values(paths))) == length(paths) ||
        fail("$description payload roles must identify distinct files")
    provenance = get(manifest, "provenance", nothing)
    provenance isa AbstractDict ||
        fail("$description manifest lacks provenance")
    all(haskey(provenance, key) for key in COMPATIBILITY_KEYS) ||
        fail("$description manifest lacks compatibility provenance")
    return (; manifest, paths, provenance)
end

function pinned_corpse_bundle(root)
    verified =
        validate_bundle(root, "reference", CORPSE_ROLES; model = "CORPSE")
    boundary_manifest = parse_toml(
        verified.paths["boundaries_manifest"],
        "CORPSE boundaries_manifest payload",
    )
    validate_boundary_manifest(boundary_manifest)
    reduced_manifest = parse_toml(
        verified.paths["reduced_history_manifest"],
        "CORPSE reduced_history_manifest payload",
    )
    validate_reduced_manifest(
        reduced_manifest,
        verified.paths["reduced_history"],
    )
    return (;
        boundaries = verified.paths["boundaries"],
        boundaries_manifest = verified.paths["boundaries_manifest"],
        boundary_manifest,
        reduced_history = verified.paths["reduced_history"],
        reduced_history_manifest = verified.paths["reduced_history_manifest"],
        reduced_manifest,
        manifest = verified.manifest,
        provenance = verified.provenance,
    )
end

function validate_boundary_manifest(manifest)
    get(manifest, "schema_version", nothing) == 1 &&
    get(manifest, "schema", nothing) == "corpse-boundary-archive-v1" &&
    get(manifest, "model", nothing) == "CORPSE" &&
    get(manifest, "scope", nothing) == "representative" &&
    get(manifest, "scope_cell_count", nothing) == 80 &&
    get(manifest, "eligible_cell_count", nothing) == 78 &&
    get(manifest, "archive_format", nothing) == "tar" ||
        fail("CORPSE boundaries_manifest payload has an incompatible schema")
    get(manifest, "stage", nothing) == CORPSE_STAGES ||
        fail("CORPSE boundary stages are incompatible")
    members = get(manifest, "members", nothing)
    members isa AbstractDict &&
    Set(String.(keys(members))) == EXPECTED_BOUNDARY_MEMBERS ||
        fail("CORPSE boundary archive declares incompatible members")
    all(valid_sha256, values(members)) ||
        fail("CORPSE boundary archive declares an invalid SHA-256")
    return nothing
end

function validate_reduced_manifest(manifest, reduced_history)
    get(manifest, "schema_version", nothing) == 1 &&
    get(manifest, "reference_id", nothing) ==
    "corpse-c-representative-fortran-reduced-v1" &&
    get(manifest, "scope", nothing) == "representative" &&
    get(manifest, "scope_cell_count", nothing) == 80 &&
    get(manifest, "eligible_cell_count", nothing) == 78 || fail(
        "CORPSE reduced_history_manifest payload has an incompatible schema",
    )
    reducers = get(manifest, "reducers", nothing)
    reducers isa AbstractDict && Set(String.(keys(reducers))) == REDUCERS ||
        fail("CORPSE reduced history declares incompatible reducers")
    artifact = get(manifest, "artifact", nothing)
    artifact isa AbstractDict &&
    get(artifact, "sha256", nothing) == sha256sum(reduced_history) &&
    get(artifact, "bytes", nothing) == filesize(reduced_history) ||
        fail("CORPSE reduced history differs from its companion manifest")
    return nothing
end

function boundary_archive_headers(path)
    try
        return Tar.list(path; strict = true)
    catch error
        fail(
            "CORPSE boundary archive is unreadable: $(sprint(showerror, error))",
        )
    end
end

function materialize_boundaries(callback, bundle)
    headers = boundary_archive_headers(bundle.boundaries)
    files = Set(header.path for header in headers if header.type == :file)
    files == EXPECTED_BOUNDARY_MEMBERS ||
        fail("CORPSE boundary archive members differ from their manifest")
    all(
        header ->
            header.type in (:file, :directory) &&
            isempty(header.link) &&
            !isabspath(header.path) &&
            all(part -> part ∉ (".", ".."), splitpath(header.path)),
        headers,
    ) || fail("CORPSE boundary archive contains an unsafe member")
    return mktempdir() do root
        Tar.extract(bundle.boundaries, root; set_permissions = false)
        for (relative, expected) in bundle.boundary_manifest["members"]
            path = safe_payload_path(root, relative, "CORPSE boundary member")
            sha256sum(path) == expected ||
                fail("CORPSE boundary member differs from its manifest")
        end
        callback(root)
    end
end

"""
    forcing_bundle(root)

Resolve and verify the Representative forcing fixture bundle.

Called from `run_pinned_corpse` before the scientific executor starts.
"""
function forcing_bundle(root)
    verified = validate_bundle(root, "forcing", ("fixture_manifest",))
    fixture_manifest = verified.paths["fixture_manifest"]
    fixture =
        parse_toml(fixture_manifest, "Representative forcing fixture manifest")
    get(fixture, "schema_version", nothing) == 1 || fail(
        "Representative forcing fixture manifest has an incompatible schema",
    )
    return (;
        fixture_manifest,
        fixture,
        manifest = verified.manifest,
        provenance = verified.provenance,
    )
end

"""
    representative_scope(path)

Verify and return the immutable, ordered 80-cell Representative Scope Manifest.

Called from `run_pinned_corpse` before bundle compatibility is checked.
"""
function representative_scope(path)
    manifest = parse_toml(path, "Representative Scope Manifest")
    cell_ids = try
        Int.(manifest["cell_ids"])
    catch
        fail("Representative Scope Manifest has invalid cell IDs")
    end
    get(manifest, "schema_version", nothing) == 1 &&
    get(manifest, "name", nothing) == "representative" &&
    length(cell_ids) == 80 &&
    cell_ids == sort(unique(cell_ids)) ||
        fail("CORPSE requires the immutable 80-cell Representative Scope")
    return (; path, manifest, cell_ids, sha256 = sha256sum(path))
end

"""
    verify_compatibility(scope, forcing, reference)

Require the scope, forcing, and CORPSE reference to share one compatibility set.

Called from `run_pinned_corpse` before the scientific executor starts.
"""
function verify_compatibility(scope, forcing, reference)
    for provenance in (forcing.provenance, reference.provenance)
        get(provenance, "scope_manifest_sha256", nothing) == scope.sha256 ||
            fail(
                "CORPSE bundle does not match the Representative Scope Manifest",
            )
    end
    selection = get(forcing.fixture, "selection", Dict{String, Any}())
    get(selection, "scope_manifest_sha256", nothing) == scope.sha256 ||
        fail("Representative forcing does not match the Scope Manifest")
    get(selection, "representative_cell_ids", nothing) == scope.cell_ids ||
        fail("Representative forcing cell IDs differ from the Scope Manifest")
    all(
        forcing.provenance[key] == reference.provenance[key] for
        key in COMPATIBILITY_KEYS
    ) || fail("CORPSE forcing and reference belong to mixed compatibility sets")
    return nothing
end

"""
    validate_result(result)

Verify the CORPSE executor result and complete 78-cell eligible coverage.

Called from `run_pinned_corpse` after the scientific executor finishes.
"""
function validate_result(result)
    all(
        hasproperty(result, name) for
        name in (:passed, :report, :seconds, :coverage)
    ) || fail("CORPSE executor returned an incomplete result")
    result.passed isa Bool ||
        fail("CORPSE executor returned an invalid outcome")
    result.report isa AbstractString && isfile(result.report) ||
        fail("CORPSE executor did not produce its report")
    result.seconds isa Real &&
    isfinite(result.seconds) &&
    result.seconds >= 0 || fail("CORPSE executor returned an invalid duration")
    coverage = result.coverage
    coverage isa AbstractDict ||
        fail("CORPSE executor returned invalid coverage")
    get(coverage, "scope_cells", nothing) == 80 &&
    get(coverage, "eligible_cells", nothing) == 78 &&
    get(coverage, "compared_cells", nothing) == 78 || fail(
        "CORPSE executor did not compare every eligible Representative cell",
    )
    gaps = get(coverage, "eligibility_gaps", nothing)
    gaps isa AbstractVector && length(gaps) == 2 || fail(
        "CORPSE executor did not report both Representative eligibility gaps",
    )
    gap_ids = Set(
        Int(get(gap, "cell_id", 0)) for
        gap in gaps if get(gap, "model", nothing) == "CORPSE" &&
            get(gap, "reviewed", false) === true
    )
    gap_ids == Set((51, 3442)) ||
        fail("CORPSE executor did not report the reviewed Representative gaps")
    return result
end

"""
    run_pinned_corpse(output_root; scope_manifest, forcing_artifact_root,
                      reference_artifact_root, workers = 1, executor = nothing)

Verify the immutable Representative forcing and CORPSE reference bundles, then
pass their resolved payloads to the supplied scientific executor. No payload is
used and no simulation starts unless every declared role and checksum matches.
"""
function run_pinned_corpse(
    output_root;
    scope_manifest,
    forcing_artifact_root,
    reference_artifact_root,
    workers = 1,
    executor = nothing,
)
    workers isa Integer && workers > 0 ||
        throw(ArgumentError("workers must be positive"))
    scope = representative_scope(scope_manifest)
    forcing = forcing_bundle(forcing_artifact_root)
    reference = pinned_corpse_bundle(reference_artifact_root)
    verify_compatibility(scope, forcing, reference)
    selected_executor = if isnothing(executor)
        parent = parentmodule(@__MODULE__)
        isdefined(parent, :TestbedPinnedCORPSEExecutor) ||
            fail("the pinned CORPSE scientific executor is unavailable")
        getfield(parent, :TestbedPinnedCORPSEExecutor).execute
    else
        executor
    end
    result = materialize_boundaries(reference) do boundary_root
        selected_executor(
            output_root;
            bundle = reference,
            boundary_root,
            fixture_manifest = forcing.fixture_manifest,
            scope_manifest = scope.path,
            workers,
        )
    end
    return validate_result(result)
end

end
