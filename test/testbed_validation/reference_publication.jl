module TestbedReferencePublication

import Pkg
import SHA
import TOML

if !isdefined(@__MODULE__, :TestbedFreshReferenceOrchestration)
    include(joinpath(@__DIR__, "fresh_reference_orchestration.jl"))
end
const FreshReferenceOrchestration = TestbedFreshReferenceOrchestration

const MODELS = ("CORPSE", "MIMICS-C", "MIMICS-CN", "CASA-C", "CASA-CN")
const CANONICAL_TOOLCHAIN_IDENTITY =
    FreshReferenceOrchestration.CANONICAL_TOOLCHAIN_IDENTITY
const CANONICAL_BUILD_PLATFORM = "x86_64-linux-gnu"
const PINNED_FORTRAN_SOURCE_COMMIT =
    FreshReferenceOrchestration.PINNED_FORTRAN_SOURCE_COMMIT
const DEFAULT_ARTIFACTS_TOML =
    joinpath(@__DIR__, "validation", "Artifacts.toml")
const REPRESENTATIVE_SCOPE_MANIFEST =
    joinpath(@__DIR__, "validation", "scopes", "representative.toml")
const BINDINGS = Dict(
    "CORPSE" => "representative_corpse_reference",
    "MIMICS-C" => "representative_mimics_c_reference",
    "MIMICS-CN" => "representative_mimics_cn_reference",
    "CASA-C" => "representative_casa_c_reference",
    "CASA-CN" => "representative_casa_cn_reference",
)
const REFERENCE_PAYLOAD_ROLES = Dict(
    "CORPSE" => (
        "boundaries",
        "boundaries_manifest",
        "reduced_history",
        "reduced_history_manifest",
    ),
    "MIMICS-C" => ("oracle",),
    "MIMICS-CN" => ("oracle",),
    "CASA-C" => ("oracle",),
    "CASA-CN" => ("oracle",),
)
const FORCING_FIXTURE_ROLES = ("forcing", "grid", "soil")
const SHARED_PARAMETER_FIXTURE_ROLES = ("phenology", "perturbation")
const MODEL_PARAMETER_FIXTURE_ROLES = Dict(
    "CORPSE" => ("casa_c_parameters", "corpse_parameters"),
    "MIMICS-C" => ("casa_cn_parameters", "mimics_parameters"),
    "MIMICS-CN" => ("casa_cn_parameters", "mimics_parameters"),
    "CASA-C" => ("casa_c_parameters",),
    "CASA-CN" => ("casa_c_parameters", "casa_cn_parameters"),
)
const MODEL_VERSIONED_INPUTS = Dict(
    "CORPSE" => ("validation/corpse_c_representative_calibration.toml",),
    "MIMICS-C" => (
        "candidate_reconstruction.toml",
        "fixtures/selected_cells/mimics_cn_parameters.csv",
        "validation/mimics_c_full_grid_calibration.toml",
        "validation/mimics_c_historical_calibration.toml",
    ),
    "MIMICS-CN" => (
        "candidate_reconstruction.toml",
        "validation/mimics_cn_boundary_calibration.toml",
        "validation/mimics_cn_historical_calibration.toml",
        "fixtures/selected_cells/mimics_cn_parameters.csv",
        "fixtures/selected_cells/mimics_cn_prespin_parameters.csv",
    ),
    "CASA-C" => (
        "candidate_reconstruction.toml",
        "validation/casa_c_full_grid_calibration.toml",
    ),
    "CASA-CN" => (
        "candidate_reconstruction.toml",
        "validation/casa_cn_full_grid_calibration.toml",
    ),
)
const MODEL_GENERATORS = Dict(
    "CORPSE" => "generate_representative_corpse_reference.jl",
    "MIMICS-C" => "generate_selected_mimics_c_reference.jl",
    "MIMICS-CN" => "generate_selected_mimics_cn_reference.jl",
    "CASA-C" => "generate_selected_casa_workflow_reference.jl",
    "CASA-CN" => "generate_selected_casa_workflow_reference.jl",
)
const COMPARISON_SCHEMA = "reduced-comparison-oracle-v1"

struct PublicationError <: Exception
    message::String
end

# ============================================================================
# Validation Utilities
# ============================================================================

Base.showerror(io::IO, error::PublicationError) = print(io, error.message)

fail(message) = throw(PublicationError(message))

sha256sum(path) =
    open(path) do io
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
valid_sha1(value) =
    value isa AbstractString && occursin(r"^[0-9a-f]{40}$", value)
valid_revision(value) =
    value isa AbstractString &&
    occursin(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$", value)

function validate_hashes(values, description)
    values isa AbstractDict && !isempty(values) ||
        fail("$description must declare at least one SHA-256")
    all(
        pair ->
            pair.first isa AbstractString &&
                !isempty(pair.first) &&
                valid_sha256(pair.second),
        pairs(values),
    ) || fail("$description contains an invalid SHA-256")
    return Dict{String, String}(
        String(key) => String(value) for (key, value) in values
    )
end

function payload_files(payload)
    files = String[]
    for (root, directories, names) in walkdir(payload; follow_symlinks = false)
        for name in (directories..., names...)
            islink(joinpath(root, name)) &&
                fail("publication payloads must not contain symbolic links")
        end
        append!(files, relpath(joinpath(root, name), payload) for name in names)
    end
    sort!(files)
    return files
end

function compatibility_document(provenance)
    return Dict(
        "scope_manifest_sha256" => provenance["scope_manifest_sha256"],
        "forcing_sha256" => provenance["forcing_sha256"],
        "shared_parameter_sha256" => provenance["shared_parameter_sha256"],
        "comparison_schema" => provenance["comparison_schema"],
    )
end

function compatibility_identity(provenance)
    io = IOBuffer()
    TOML.print(io, compatibility_document(provenance); sorted = true)
    return bytes2hex(SHA.sha256(take!(io)))
end

# ============================================================================
# Canonical Fresh Evidence
# ============================================================================

function representative_scope()
    manifest = parse_toml(
        REPRESENTATIVE_SCOPE_MANIFEST,
        "Representative Scope Manifest",
    )
    cell_ids = Int.(get(manifest, "cell_ids", Int[]))
    get(manifest, "schema_version", nothing) == 1 &&
        get(manifest, "name", nothing) == "representative" &&
        length(cell_ids) == 80 &&
        length(unique(cell_ids)) == 80 ||
        fail("Representative Scope Manifest is incompatible")
    return (; cell_ids, sha256 = sha256sum(REPRESENTATIVE_SCOPE_MANIFEST))
end

function write_toml(path, document)
    temporary = "$path.tmp"
    open(temporary, "w") do io
        TOML.print(io, document; sorted = true)
    end
    mv(temporary, path; force = true)
    return path
end

function file_hashes(root; excluded = ())
    excluded_set = Set(excluded)
    return Dict(
        relative => sha256sum(joinpath(root, relative)) for
        relative in payload_files(root) if !(relative in excluded_set)
    )
end

function named_hashes(paths)
    return Dict(relpath(path, @__DIR__) => sha256sum(path) for path in paths)
end

function copy_selected_payload(source, destination, relative_paths)
    mkpath(destination)
    for relative in relative_paths
        relative isa AbstractString && !isempty(relative) ||
            fail("publication payload has an invalid path")
        normalized = normpath(relative)
        isabspath(relative) && fail("publication payload has an unsafe path")
        any(part -> part in (".", ".."), splitpath(normalized)) &&
            fail("publication payload has an unsafe path")
        normalized == relative ||
            fail("publication payload path is not normalized")
        source_path = joinpath(source, normalized)
        isfile(source_path) ||
            fail("publication payload file is missing at $source_path")
        current = source
        for part in splitpath(normalized)
            current = joinpath(current, part)
            islink(current) &&
                fail("publication payloads must not contain symbolic links")
        end
        destination_path = joinpath(destination, normalized)
        mkpath(dirname(destination_path))
        cp(source_path, destination_path)
    end
    return destination
end

function candidate_provenance(
    metadata,
    forcing_sha256,
    parameter_sha256,
    shared_parameter_sha256,
    scope_sha256,
    generator_revision,
)
    verification = metadata["verification"]
    return Dict(
        "scope_manifest_sha256" => scope_sha256,
        "forcing_sha256" => forcing_sha256,
        "shared_parameter_sha256" => shared_parameter_sha256,
        "source_revision" => String(verification["source_commit"]),
        "parameter_sha256" => parameter_sha256,
        "comparison_schema" => COMPARISON_SCHEMA,
        "generator_revision" => generator_revision,
        "compiler_identity" => String(metadata["compiler_identity"]),
        "build_platform" => String(metadata["build_platform"]),
        "toolchain_identity" => String(metadata["toolchain_identity"]),
    )
end

function write_candidate_payload(
    destination,
    kind,
    generation,
    payload,
    provenance;
    model = nothing,
)
    files = file_hashes(destination)
    document = Dict{String, Any}(
        "schema_version" => 1,
        "kind" => kind,
        "scope" => "representative",
        "generation" => generation,
        "outcome" => "passed",
        "canonical" => true,
        "files" => files,
        "payload" => payload,
        "provenance" => provenance,
    )
    isnothing(model) || (document["model"] = model)
    write_toml(joinpath(destination, "manifest.toml"), document)
    return destination
end

function fixture_hashes(records, roles)
    return Dict{String, String}(
        map(roles) do role
            haskey(records, role) || fail("Representative forcing lacks $role")
            record = records[role]
            filename = get(record, "filename", nothing)
            digest = get(record, "sha256", nothing)
            filename isa AbstractString && valid_sha256(digest) ||
                fail("Representative forcing has invalid $role provenance")
            String(filename) => String(digest)
        end,
    )
end

function copy_forcing_payload(forcing_root, destination, scope)
    isdir(forcing_root) || fail("Representative forcing bundle is missing")
    fixture_path = joinpath(forcing_root, "fixture.toml")
    fixture =
        parse_toml(fixture_path, "Representative forcing fixture manifest")
    get(fixture, "schema_version", nothing) == 1 || fail(
        "Representative forcing fixture manifest has an incompatible schema",
    )
    selection = get(fixture, "selection", Dict{String, Any}())
    Int.(get(selection, "representative_cell_ids", Int[])) == scope.cell_ids &&
        get(selection, "scope_manifest_sha256", nothing) == scope.sha256 ||
        fail("Representative forcing differs from the exact Scope Manifest")
    audit = get(fixture, "audit", nothing)
    audit isa AbstractDict && !isempty(audit) && all(values(audit)) ||
        fail("Representative forcing fixture did not pass its generation audit")
    records = get(fixture, "fixture", nothing)
    records isa AbstractDict && !isempty(records) ||
        fail("Representative forcing fixture manifest lacks payload records")
    required_roles = Set((
        FORCING_FIXTURE_ROLES...,
        SHARED_PARAMETER_FIXTURE_ROLES...,
        (
            role for roles in values(MODEL_PARAMETER_FIXTURE_ROLES) for
            role in roles
        )...,
    ))
    all(role -> haskey(records, role), required_roles) ||
        fail("Representative forcing fixture manifest is incomplete")
    relative_paths = String["fixture.toml"]
    for (role, record) in records
        relative = get(record, "filename", nothing)
        expected_bytes = get(record, "bytes", nothing)
        expected_sha256 = get(record, "sha256", nothing)
        relative isa AbstractString && valid_sha256(expected_sha256) ||
            fail("Representative forcing has an invalid $role record")
        source_path = joinpath(forcing_root, relative)
        isfile(source_path) ||
            fail("Representative forcing $role is missing at $source_path")
        expected_bytes isa Integer && filesize(source_path) == expected_bytes ||
            fail("Representative forcing $role has the wrong byte count")
        sha256sum(source_path) == expected_sha256 ||
            fail("Representative forcing $role differs from its manifest")
        push!(relative_paths, String(relative))
    end
    length(unique(relative_paths)) == length(relative_paths) ||
        fail("Representative forcing payload paths are not unique")
    copy_selected_payload(forcing_root, destination, relative_paths)
    forcing_sha256 = fixture_hashes(records, FORCING_FIXTURE_ROLES)
    shared_parameter_sha256 =
        fixture_hashes(records, SHARED_PARAMETER_FIXTURE_ROLES)
    model_parameter_sha256 = Dict(
        model =>
            fixture_hashes(records, MODEL_PARAMETER_FIXTURE_ROLES[model])
        for model in MODELS
    )
    return (;
        payload = Dict("fixture_manifest" => "fixture.toml"),
        forcing_sha256,
        shared_parameter_sha256,
        model_parameter_sha256,
    )
end

function model_payload_sources(model, fresh_model, report)
    source_reference = abspath(String(report["reference"]["path"]))
    first(splitpath(relpath(source_reference, fresh_model))) == ".." &&
        fail("$model fresh comparison references an oracle outside its run")
    if model == "CORPSE"
        payload_root = joinpath(fresh_model, "payload")
        payload = Dict(
            "boundaries" => "boundaries.tar",
            "boundaries_manifest" => "boundaries.toml",
            "reduced_history" => "reduced_history.nc",
            "reduced_history_manifest" => "reduced_history.toml",
        )
        sha256sum(joinpath(payload_root, payload["reduced_history"])) ==
        sha256sum(source_reference) ||
            fail("CORPSE publication payload differs from its fresh oracle")
        return (; source = payload_root, payload)
    end
    return (;
        source = dirname(source_reference),
        payload = Dict("oracle" => basename(source_reference)),
    )
end

"""
    construct_candidate(fresh_root, forcing_root, candidate_root, generation)

Construct one atomic shared publication candidate from retained canonical fresh
evidence and the exact Representative forcing bundle. Only publication payloads
are copied; full Fortran and Julia run directories remain in `fresh_root`.
"""
function construct_candidate(
    fresh_root,
    forcing_root,
    candidate_root,
    generation,
    ;
    _machine = Sys.MACHINE,
)
    fresh_root = abspath(fresh_root)
    forcing_root = abspath(forcing_root)
    candidate_root = abspath(candidate_root)
    generation isa AbstractString &&
        occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", generation) ||
        fail("publication candidate has an invalid generation")
    ispath(candidate_root) &&
        fail("publication candidate output already exists")
    isdir(fresh_root) || fail("retained fresh evidence is missing")
    isdir(forcing_root) || fail("Representative forcing bundle is missing")
    for source in (fresh_root, forcing_root)
        relative = relpath(candidate_root, realpath(source))
        first(splitpath(relative)) == ".." ||
            fail("publication candidate output must be outside its inputs")
    end
    _machine == CANONICAL_BUILD_PLATFORM || fail(
        "publication candidates must be constructed on $CANONICAL_BUILD_PLATFORM",
    )
    build = canonical_build(fresh_root)
    metadata = build.metadata
    scope = representative_scope()
    executable_sha256 = build.executable_sha256
    parent = dirname(candidate_root)
    mkpath(parent)
    staging = mktempdir(parent; prefix = ".candidate-", cleanup = false)
    completed = false
    try
        forcing_destination = joinpath(staging, "forcing")
        forcing = copy_forcing_payload(forcing_root, forcing_destination, scope)
        forcing_provenance = candidate_provenance(
            metadata,
            forcing.forcing_sha256,
            file_hashes(forcing_destination),
            forcing.shared_parameter_sha256,
            scope.sha256,
            sha256sum(@__FILE__),
        )
        write_candidate_payload(
            forcing_destination,
            "forcing",
            generation,
            forcing.payload,
            forcing_provenance,
        )

        for model in MODELS
            fresh_model = joinpath(fresh_root, "model-$model")
            report = try
                FreshReferenceOrchestration.validated_comparison(
                    model,
                    joinpath(fresh_model, "comparison.toml");
                    expected_executable_sha256 = executable_sha256,
                    expected_scope_manifest_sha256 = scope.sha256,
                    fortran_path = joinpath(fresh_model, "fortran_output.toml"),
                )
            catch error
                fail(sprint(showerror, error))
            end
            scientific_checks(model, report)
            reference = get(report, "reference", Dict{String, Any}())
            get(reference, "kind", nothing) == "fresh_reduced_oracle" || fail(
                "$model fresh comparison lacks its reduced oracle identity",
            )
            source_reference = get(reference, "path", nothing)
            source_reference isa AbstractString ||
                fail("$model fresh comparison lacks its reduced oracle path")
            isfile(source_reference) ||
                fail("$model fresh reduced oracle is missing")
            sha256sum(source_reference) == get(reference, "sha256", nothing) ||
                fail("$model fresh reduced oracle differs from its comparison")
            sources = model_payload_sources(model, fresh_model, report)
            destination = joinpath(staging, "model-$model", "reference")
            copy_selected_payload(
                sources.source,
                destination,
                collect(values(sources.payload)),
            )
            provenance = candidate_provenance(
                metadata,
                forcing.forcing_sha256,
                merge(
                    forcing.model_parameter_sha256[model],
                    named_hashes(
                        map(
                            relative -> joinpath(@__DIR__, relative),
                            MODEL_VERSIONED_INPUTS[model],
                        ),
                    ),
                ),
                forcing.shared_parameter_sha256,
                scope.sha256,
                sha256sum(joinpath(@__DIR__, MODEL_GENERATORS[model])),
            )
            write_candidate_payload(
                destination,
                "reference",
                generation,
                sources.payload,
                provenance;
                model,
            )
        end
        write_toml(
            joinpath(staging, "publication_candidate.toml"),
            Dict(
                "schema_version" => 1,
                "operation" => "reference_publication",
                "outcome" => "passed",
                "scope" => "representative",
                "generation" => generation,
                "change_kind" => "shared",
                "models" => collect(MODELS),
            ),
        )
        ispath(candidate_root) && fail(
            "publication candidate output appeared before the atomic commit",
        )
        mv(staging, candidate_root)
        completed = true
    finally
        completed || (ispath(staging) && rm(staging; recursive = true))
    end
    return candidate_root
end

function canonical_build(fresh_root)
    build_root = joinpath(fresh_root, "build")
    metadata_path = joinpath(build_root, "build_metadata.toml")
    metadata = parse_toml(metadata_path, "verified shared-build metadata")
    get(metadata, "schema_version", nothing) == 1 &&
        get(metadata, "verified", nothing) === true ||
        fail("shared Fortran build metadata is not verified")
    get(metadata, "build_platform", nothing) == CANONICAL_BUILD_PLATFORM &&
        get(metadata, "toolchain_identity", nothing) ==
        CANONICAL_TOOLCHAIN_IDENTITY ||
        fail("shared Fortran build metadata is not canonical")
    compiler = get(metadata, "compiler_identity", nothing)
    compiler isa AbstractString &&
        occursin(r"^GNU Fortran(?: |$)", compiler) &&
        occursin(r"[0-9]", compiler) ||
        fail("shared Fortran build metadata is not GNU Fortran")
    verification = get(metadata, "verification", Dict{String, Any}())
    executable_name = get(verification, "executable", nothing)
    executable_name isa AbstractString &&
        basename(executable_name) == executable_name ||
        fail("shared Fortran build metadata has an unsafe executable")
    executable = joinpath(build_root, executable_name)
    isfile(executable) || fail("verified shared Fortran executable is missing")
    executable_sha256 = sha256sum(executable)
    executable_sha256 == get(verification, "executable_sha256", nothing) ||
        fail("verified shared Fortran executable differs from build metadata")
    get(verification, "source_code_clean", nothing) === true &&
        get(verification, "source_commit", nothing) ==
        PINNED_FORTRAN_SOURCE_COMMIT ||
        fail("shared Fortran build lacks clean pinned-source evidence")

    return (;
        build_root,
        metadata_path,
        metadata,
        compiler = String(compiler),
        verification,
        executable,
        executable_sha256,
    )
end

function canonical_build_receipt(fresh_root, candidate_root)
    build = canonical_build(fresh_root)

    copied_metadata = joinpath(candidate_root, "build_metadata.toml")
    cp(build.metadata_path, copied_metadata; force = true)
    receipt = Dict(
        "schema_version" => 1,
        "kind" => "canonical_fortran_build_receipt",
        "verified" => true,
        "canonical" => true,
        "compiler_identity" => build.compiler,
        "build_platform" => CANONICAL_BUILD_PLATFORM,
        "toolchain_identity" => CANONICAL_TOOLCHAIN_IDENTITY,
        "source_build_metadata_sha256" => sha256sum(copied_metadata),
        "verification" => Dict(
            "source_commit" => String(build.verification["source_commit"]),
            "source_code_clean" => true,
            "executable_sha256" => build.executable_sha256,
        ),
    )
    path = write_toml(
        joinpath(candidate_root, "canonical_build_receipt.toml"),
        receipt,
    )
    return (; path, receipt, sha256 = sha256sum(path))
end

all_match(records) =
    records isa AbstractDict &&
    !isempty(records) &&
    all(get(record, "all_match", false) === true for record in values(records))

is_true(record, key) =
    record isa AbstractDict && get(record, key, false) === true

function scientific_checks(model, report)
    if model == "CORPSE"
        stages = get(report, "stage", nothing)
        boundaries =
            stages isa AbstractDict &&
            !isempty(stages) &&
            all(
                all_match(get(stage, "comparison", nothing)) for
                stage in values(stages)
            )
        historical = get(report, "reduced_historical", nothing)
        annual =
            historical isa AbstractDict && all(
                haskey(historical, name) && all_match(historical[name]) for
                name in ("annual_summaries", "end_of_year", "annual_budgets")
            )
        daily =
            historical isa AbstractDict &&
            haskey(historical, "fixed_daily_samples") &&
            all_match(historical["fixed_daily_samples"])
        budget =
            get(get(report, "budget", Dict{String, Any}()), "verified", false)
        checks = (boundaries, annual, budget, daily)
    else
        boundaries = all_match(get(report, "boundary_comparison", nothing))
        historical = get(report, "historical_comparison", nothing)
        annual =
            historical isa AbstractDict &&
            is_true(get(historical, "annual", nothing), "all_match")
        daily_record =
            historical isa AbstractDict ?
            get(
                historical,
                "fixed_daily_samples",
                get(
                    historical,
                    "selected_dates",
                    get(historical, "daily", nothing),
                ),
            ) : nothing
        daily = is_true(daily_record, "all_match")
        carbon = get(
            get(report, "carbon_budget", Dict{String, Any}()),
            "all_close",
            false,
        )
        nitrogen =
            model in ("MIMICS-CN", "CASA-CN") ?
            get(
                get(report, "nitrogen_budget", Dict{String, Any}()),
                "all_close",
                false,
            ) : true
        checks = (boundaries, annual, carbon && nitrogen, daily)
    end
    names = (
        "boundaries",
        "annual_summaries",
        "budget_diagnostics",
        "fixed_daily_samples",
    )
    result = Dict(name => value for (name, value) in zip(names, checks))
    all(values(result)) ||
        fail("$model fresh comparison lacks successful scientific checks")
    return result
end

function comparison_receipt(fresh_root, candidate_root, model, build, scope)
    fresh_model = joinpath(fresh_root, "model-$model")
    source_path = joinpath(fresh_model, "comparison.toml")
    source_fortran_path = joinpath(fresh_model, "fortran_output.toml")
    report = try
        FreshReferenceOrchestration.validated_comparison(
            model,
            source_path;
            expected_executable_sha256 = build.receipt["verification"]["executable_sha256"],
            expected_scope_manifest_sha256 = scope.sha256,
            fortran_path = source_fortran_path,
        )
    catch error
        fail(sprint(showerror, error))
    end
    reference = get(report, "reference", Dict{String, Any}())
    get(reference, "kind", nothing) == "fresh_reduced_oracle" ||
        fail("$model fresh comparison lacks its reduced oracle identity")
    source_reference = get(reference, "path", nothing)
    source_reference isa AbstractString ||
        fail("$model fresh comparison lacks its reduced oracle path")
    relative_reference =
        relpath(abspath(source_reference), abspath(fresh_model))
    startswith(relative_reference, "..") &&
        fail("$model fresh comparison references an oracle outside its run")
    isfile(source_reference) || fail("$model fresh reduced oracle is missing")
    sha256sum(source_reference) == get(reference, "sha256", nothing) ||
        fail("$model fresh reduced oracle differs from its comparison")

    payload_root = joinpath(candidate_root, "model-$model", "reference")
    bundle = validate_payload(
        payload_root,
        "reference",
        TOML.parsefile(joinpath(candidate_root, "publication_candidate.toml"))["generation"];
        model,
    )
    role = model == "CORPSE" ? "reduced_history" : "oracle"
    published_reference =
        joinpath(payload_root, bundle.manifest["payload"][role])
    sha256sum(published_reference) == sha256sum(source_reference) ||
        fail("$model publication payload differs from its fresh reduced oracle")
    if model == "CORPSE"
        fresh_payload = joinpath(fresh_model, "payload")
        for relative in values(bundle.manifest["payload"])
            source = joinpath(fresh_payload, relative)
            isfile(source) &&
                sha256sum(source) ==
                sha256sum(joinpath(payload_root, relative)) ||
                fail("CORPSE publication payload differs from its fresh run")
        end
    end

    checks = scientific_checks(model, report)
    destination = joinpath(candidate_root, "model-$model")
    source_copy = joinpath(destination, "source_comparison.toml")
    source_fortran_copy = joinpath(destination, "source_fortran_output.toml")
    cp(source_path, source_copy; force = true)
    cp(source_fortran_path, source_fortran_copy; force = true)
    receipt = Dict(
        "schema_version" => 1,
        "kind" => "reference_comparison_receipt",
        "model" => model,
        "scope" => "representative",
        "scope_manifest_sha256" => scope.sha256,
        "build_receipt_sha256" => build.sha256,
        "source_comparison_sha256" => sha256sum(source_copy),
        "source_fortran_output_sha256" => sha256sum(source_fortran_copy),
        "outcome" => "passed",
        "coverage" => report["coverage"],
        "check" => checks,
        "reference_files" => bundle.manifest["files"],
    )
    path = write_toml(joinpath(destination, "comparison.toml"), receipt)
    return (; path, sha256 = sha256sum(path))
end

function bind_canonical_evidence!(fresh_root, candidate_root)
    fresh_root = abspath(fresh_root)
    candidate_root = abspath(candidate_root)
    candidate = parse_toml(
        joinpath(candidate_root, "publication_candidate.toml"),
        "publication candidate",
    )
    raw_models = get(candidate, "models", nothing)
    raw_models isa AbstractVector || fail("publication candidate lacks models")
    models = String.(raw_models)
    length(models) == length(unique(models)) &&
        all(model -> model in MODELS, models) ||
        fail("publication candidate has invalid models")
    build = canonical_build_receipt(fresh_root, candidate_root)
    scope = representative_scope()
    receipts = Dict(
        model => comparison_receipt(
            fresh_root,
            candidate_root,
            model,
            build,
            scope,
        ) for model in models
    )
    bundle_paths = [
        joinpath(candidate_root, "model-$model", "reference", "manifest.toml") for model in models
    ]
    get(candidate, "change_kind", nothing) == "shared" && push!(
        bundle_paths,
        joinpath(candidate_root, "forcing", "manifest.toml"),
    )
    for path in bundle_paths
        manifest = parse_toml(path, "publication bundle manifest")
        provenance = manifest["provenance"]
        provenance["build_receipt_sha256"] = build.sha256
        provenance["source_revision"] =
            build.receipt["verification"]["source_commit"]
        provenance["compiler_identity"] = build.receipt["compiler_identity"]
        provenance["build_platform"] = build.receipt["build_platform"]
        provenance["toolchain_identity"] = build.receipt["toolchain_identity"]
        if get(manifest, "kind", nothing) == "reference"
            provenance["comparison_report_sha256"] =
                receipts[manifest["model"]].sha256
        end
        write_toml(path, manifest)
    end
    return candidate_root
end

# ============================================================================
# Publication Candidate Validation
# ============================================================================

function validate_build_receipt(candidate_root)
    path = joinpath(candidate_root, "canonical_build_receipt.toml")
    receipt = parse_toml(path, "canonical build receipt")
    get(receipt, "schema_version", nothing) == 1 &&
        get(receipt, "kind", nothing) == "canonical_fortran_build_receipt" &&
        get(receipt, "verified", nothing) === true &&
        get(receipt, "canonical", nothing) === true || fail(
        "canonical build receipt was not generated by canonical Linux/GNU Fortran",
    )
    get(receipt, "build_platform", nothing) == CANONICAL_BUILD_PLATFORM &&
        get(receipt, "toolchain_identity", nothing) ==
        CANONICAL_TOOLCHAIN_IDENTITY ||
        fail("canonical build receipt has the wrong platform or toolchain")
    verification = get(receipt, "verification", nothing)
    verification isa AbstractDict &&
        get(verification, "source_code_clean", nothing) === true &&
        valid_revision(get(verification, "source_commit", nothing)) &&
        valid_sha256(get(verification, "executable_sha256", nothing)) || fail(
        "canonical build receipt lacks verified source and executable evidence",
    )
    compiler_identity = get(receipt, "compiler_identity", nothing)
    compiler_identity isa AbstractString &&
        occursin(r"^GNU Fortran(?: |$)", compiler_identity) &&
        occursin(r"[0-9]", compiler_identity) || fail(
        "canonical build receipt was not generated by canonical Linux/GNU Fortran",
    )
    metadata_path = joinpath(candidate_root, "build_metadata.toml")
    metadata = parse_toml(metadata_path, "source shared-build metadata")
    get(receipt, "source_build_metadata_sha256", nothing) ==
    sha256sum(metadata_path) ||
        fail("canonical build receipt differs from its source build metadata")
    metadata_verification = get(metadata, "verification", Dict{String, Any}())
    get(metadata, "build_platform", nothing) == receipt["build_platform"] &&
        get(metadata, "toolchain_identity", nothing) ==
        receipt["toolchain_identity"] &&
        get(metadata, "compiler_identity", nothing) == compiler_identity &&
        get(metadata_verification, "source_commit", nothing) ==
        verification["source_commit"] &&
        get(metadata_verification, "source_code_clean", nothing) === true &&
        get(metadata_verification, "executable_sha256", nothing) ==
        verification["executable_sha256"] ||
        fail("canonical build receipt does not derive from its source metadata")
    return (; path, receipt, sha256 = sha256sum(path))
end

function validate_payload_schema(bundle, scope)
    payload = bundle.manifest["payload"]
    if bundle.kind == "forcing"
        fixture = parse_toml(
            joinpath(bundle.payload, payload["fixture_manifest"]),
            "Representative forcing fixture manifest",
        )
        selection = get(fixture, "selection", Dict{String, Any}())
        Int.(get(selection, "representative_cell_ids", Int[])) ==
        scope.cell_ids &&
            get(selection, "scope_manifest_sha256", nothing) == scope.sha256 ||
            fail(
                "Representative forcing payload differs from the exact Scope Manifest",
            )
        return nothing
    end
    model = bundle.model
    if model == "CORPSE"
        boundaries = parse_toml(
            joinpath(bundle.payload, payload["boundaries_manifest"]),
            "CORPSE boundary payload manifest",
        )
        get(boundaries, "schema_version", nothing) == 1 &&
            get(boundaries, "schema", nothing) ==
            "corpse-boundary-archive-v1" &&
            get(boundaries, "model", nothing) == model &&
            get(boundaries, "scope", nothing) == "representative" &&
            get(boundaries, "scope_cell_count", nothing) == 80 &&
            get(boundaries, "eligible_cell_count", nothing) == 78 ||
            fail("CORPSE boundary payload has an incompatible schema")
        reduced = parse_toml(
            joinpath(bundle.payload, payload["reduced_history_manifest"]),
            "CORPSE reduced-history payload manifest",
        )
        get(reduced, "schema_version", nothing) == 1 &&
            get(reduced, "reference_id", nothing) ==
            "corpse-c-representative-fortran-reduced-v1" &&
            get(reduced, "scope", nothing) == "representative" &&
            get(reduced, "scope_cell_count", nothing) == 80 &&
            get(reduced, "eligible_cell_count", nothing) == 78 ||
            fail("CORPSE reduced-history payload has an incompatible schema")
        return nothing
    end
    oracle = parse_toml(
        joinpath(bundle.payload, payload["oracle"]),
        "$model reduced Comparison Oracle",
    )
    get(oracle, "schema_version", nothing) == 1 &&
        Int.(get(oracle, "cell_ids", Int[])) == scope.cell_ids || fail(
        "$model Comparison Oracle differs from the exact Representative scope",
    )
    if model in ("MIMICS-C", "MIMICS-CN")
        get(oracle, "model", nothing) == model &&
            get(oracle, "scope", nothing) == "representative" &&
            Set(String.(keys(get(oracle, "oracle", Dict{String, Any}())))) ==
            Set(("boundary", "annual", "daily", "budget")) ||
            fail("$model Comparison Oracle has an incompatible schema")
    else
        configuration = model == "CASA-C" ? "carbon_only" : "carbon_nitrogen"
        get(oracle, "tier", nothing) == "representative" && haskey(
            get(oracle, "configuration", Dict{String, Any}()),
            configuration,
        ) || fail("$model Comparison Oracle has an incompatible schema")
    end
    return nothing
end

function validate_comparison_receipt(candidate_root, bundle, build, scope)
    path = joinpath(candidate_root, "model-$(bundle.model)", "comparison.toml")
    report = parse_toml(path, "$(bundle.model) comparison receipt")
    get(report, "schema_version", nothing) == 1 &&
        get(report, "kind", nothing) == "reference_comparison_receipt" &&
        get(report, "model", nothing) == bundle.model &&
        get(report, "scope", nothing) == "representative" &&
        get(report, "scope_manifest_sha256", nothing) == scope.sha256 &&
        get(report, "build_receipt_sha256", nothing) == build.sha256 &&
        get(report, "outcome", nothing) == "passed" || fail(
        "$(bundle.model) comparison receipt is not a successful canonical comparison",
    )
    expected_eligible = bundle.model == "CORPSE" ? 78 : 80
    coverage = get(report, "coverage", Dict{String, Any}())
    get(coverage, "scope_cells", nothing) == 80 &&
        get(coverage, "eligible_cells", nothing) == expected_eligible &&
        get(coverage, "compared_cells", nothing) == expected_eligible ||
        fail("$(bundle.model) comparison receipt has incomplete coverage")
    checks = get(report, "check", Dict{String, Any}())
    required = (
        "boundaries",
        "annual_summaries",
        "budget_diagnostics",
        "fixed_daily_samples",
    )
    Set(String.(keys(checks))) == Set(required) &&
        all(checks[name] === true for name in required) || fail(
        "$(bundle.model) comparison receipt lacks complete scientific checks",
    )
    get(report, "reference_files", nothing) == bundle.manifest["files"] || fail(
        "$(bundle.model) comparison receipt does not identify the published payload",
    )
    source_path = joinpath(
        candidate_root,
        "model-$(bundle.model)",
        "source_comparison.toml",
    )
    source_fortran_path = joinpath(
        candidate_root,
        "model-$(bundle.model)",
        "source_fortran_output.toml",
    )
    source = try
        FreshReferenceOrchestration.validated_comparison(
            bundle.model,
            source_path;
            expected_executable_sha256 = build.receipt["verification"]["executable_sha256"],
            expected_scope_manifest_sha256 = scope.sha256,
            fortran_path = source_fortran_path,
        )
    catch error
        fail(sprint(showerror, error))
    end
    get(report, "source_comparison_sha256", nothing) ==
    sha256sum(source_path) ||
        fail("$(bundle.model) receipt differs from its source comparison")
    get(report, "source_fortran_output_sha256", nothing) ==
    sha256sum(source_fortran_path) ||
        fail("$(bundle.model) receipt differs from its source Fortran evidence")
    scientific_checks(bundle.model, source) == checks ||
        fail("$(bundle.model) receipt differs from its scientific comparison")
    provenance = bundle.manifest["provenance"]
    get(provenance, "build_receipt_sha256", nothing) == build.sha256 &&
        get(provenance, "comparison_report_sha256", nothing) ==
        sha256sum(path) || fail(
        "$(bundle.model) reference manifest is not bound to its canonical evidence",
    )
    get(provenance, "source_revision", nothing) ==
    build.receipt["verification"]["source_commit"] &&
        get(provenance, "compiler_identity", nothing) ==
        build.receipt["compiler_identity"] || fail(
        "$(bundle.model) reference provenance differs from its canonical build receipt",
    )
    return report
end

function validate_provenance(provenance, description)
    provenance isa AbstractDict || fail("$description lacks provenance")
    valid_sha256(get(provenance, "scope_manifest_sha256", nothing)) ||
        fail("$description has an invalid Scope Manifest identity")
    forcing_sha256 = validate_hashes(
        get(provenance, "forcing_sha256", nothing),
        "$description forcing provenance",
    )
    shared_parameter_sha256 = validate_hashes(
        get(provenance, "shared_parameter_sha256", nothing),
        "$description shared-parameter provenance",
    )
    parameter_sha256 = validate_hashes(
        get(provenance, "parameter_sha256", nothing),
        "$description parameter provenance",
    )
    for key in (
        "comparison_schema",
        "compiler_identity",
        "build_platform",
        "toolchain_identity",
    )
        value = get(provenance, key, nothing)
        value isa AbstractString && !isempty(strip(value)) ||
            fail("$description lacks $key")
    end
    for key in ("source_revision", "generator_revision")
        valid_revision(get(provenance, key, nothing)) ||
            fail("$description has an invalid $key")
    end
    compiler_identity = strip(provenance["compiler_identity"])
    provenance["build_platform"] == CANONICAL_BUILD_PLATFORM &&
        provenance["toolchain_identity"] == CANONICAL_TOOLCHAIN_IDENTITY &&
        occursin(r"^GNU Fortran(?: |$)", compiler_identity) &&
        occursin(r"[0-9]", compiler_identity) || fail(
        "$description was not generated by the canonical Linux/GNU Fortran toolchain",
    )
    normalized =
        Dict{String, Any}(String(key) => value for (key, value) in provenance)
    normalized["forcing_sha256"] = forcing_sha256
    normalized["shared_parameter_sha256"] = shared_parameter_sha256
    normalized["parameter_sha256"] = parameter_sha256
    return normalized
end

function validate_payload(payload, kind, generation; model = nothing)
    isdir(payload) ||
        fail("$kind publication lacks a complete reference bundle")
    islink(payload) && fail("publication payloads must not be symbolic links")
    description = isnothing(model) ? kind : "$model reference"
    manifest_path = joinpath(payload, "manifest.toml")
    manifest = parse_toml(manifest_path, "$description manifest")
    get(manifest, "schema_version", nothing) == 1 ||
        fail("$description manifest has an incompatible schema")
    get(manifest, "kind", nothing) == kind ||
        fail("$description manifest declares the wrong bundle kind")
    get(manifest, "scope", nothing) == "representative" ||
        fail("$description manifest is not Representative")
    get(manifest, "generation", nothing) == generation ||
        fail("$description manifest belongs to a partially mixed generation")
    get(manifest, "outcome", nothing) == "passed" ||
        fail("$description fresh comparison did not pass")
    get(manifest, "canonical", nothing) === true || fail(
        "$description was not generated by the canonical Linux/GNU Fortran toolchain",
    )
    if kind == "reference"
        get(manifest, "model", nothing) == model ||
            fail("$description manifest declares the wrong model")
    elseif haskey(manifest, "model")
        fail("forcing manifest must not declare a model")
    end
    provenance = validate_provenance(
        get(manifest, "provenance", nothing),
        "$description manifest",
    )
    declared_files = validate_hashes(
        get(manifest, "files", nothing),
        "$description manifest files",
    )
    payload_roles = get(manifest, "payload", nothing)
    payload_roles isa AbstractDict ||
        fail("$description manifest lacks payload roles")
    required_roles =
        kind == "forcing" ? ("fixture_manifest",) :
        REFERENCE_PAYLOAD_ROLES[model]
    Set(String.(keys(payload_roles))) == Set(required_roles) ||
        fail("$description manifest has incompatible payload roles")
    all(
        path -> path isa AbstractString && haskey(declared_files, path),
        values(payload_roles),
    ) || fail("$description payload roles must identify declared files")
    length(unique(values(payload_roles))) == length(payload_roles) ||
        fail("$description payload roles must identify distinct files")
    actual_files = setdiff(payload_files(payload), ["manifest.toml"])
    sort!(collect(keys(declared_files))) == actual_files ||
        fail("$description manifest does not declare the complete bundle")
    for (relative_path, expected_sha256) in declared_files
        isabspath(relative_path) &&
            fail("$description manifest contains an unsafe file path")
        startswith(relative_path, "..") &&
            fail("$description manifest contains an unsafe file path")
        sha256sum(joinpath(payload, relative_path)) == expected_sha256 ||
            fail("$description bundle differs from its manifest")
    end
    normalized =
        Dict{String, Any}(String(key) => value for (key, value) in manifest)
    normalized["provenance"] = provenance
    normalized["files"] = declared_files
    normalized["payload"] = Dict{String, String}(
        String(role) => String(path) for (role, path) in payload_roles
    )
    return (;
        payload,
        kind,
        model,
        manifest = normalized,
        compatibility_identity = compatibility_identity(provenance),
    )
end

"""
    validate_candidate(candidate_root)

Verify a publication candidate and return its compatible forcing/reference bundles.

Called from `_stage_prepared_publication` after fresh evidence is bound and before
any archives are created.
"""
function validate_candidate(candidate_root)
    isdir(candidate_root) ||
        fail("publication candidate is missing at $candidate_root")
    candidate = parse_toml(
        joinpath(candidate_root, "publication_candidate.toml"),
        "publication candidate",
    )
    get(candidate, "schema_version", nothing) == 1 ||
        fail("publication candidate has an incompatible schema")
    get(candidate, "operation", nothing) == "reference_publication" ||
        fail("ordinary fresh runs are not publication candidates")
    get(candidate, "outcome", nothing) == "passed" ||
        fail("publication candidate did not pass")
    get(candidate, "scope", nothing) == "representative" || fail(
        "only Representative references can be published by this operation",
    )
    build = validate_build_receipt(candidate_root)
    scope = representative_scope()
    generation = get(candidate, "generation", nothing)
    generation isa AbstractString &&
        occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", generation) ||
        fail("publication candidate has an invalid generation")
    change_kind = get(candidate, "change_kind", nothing)
    change_kind in ("shared", "model") ||
        fail("publication candidate has an invalid change kind")
    raw_models = get(candidate, "models", nothing)
    raw_models isa AbstractVector || fail("publication candidate lacks models")
    models = String.(raw_models)
    length(models) == length(unique(models)) &&
        all(model -> model in MODELS, models) ||
        fail("publication candidate has invalid models")
    if change_kind == "shared"
        models == collect(MODELS) ||
            fail("shared publication requires all five models")
    else
        length(models) == 1 ||
            fail("model-only publication requires exactly one model")
        isdir(joinpath(candidate_root, "forcing")) &&
            fail("model-only publication must not replace shared forcing")
    end
    model_directories = sort(
        filter(
            name ->
                startswith(name, "model-") &&
                    isdir(joinpath(candidate_root, name)),
            readdir(candidate_root),
        ),
    )
    model_directories == sort(map(model -> "model-$model", models)) ||
        fail("publication candidate contains a partially mixed model set")

    bundles = Any[]
    if change_kind == "shared"
        push!(
            bundles,
            validate_payload(
                joinpath(candidate_root, "forcing"),
                "forcing",
                generation,
            ),
        )
    end
    for model in models
        push!(
            bundles,
            validate_payload(
                joinpath(candidate_root, "model-$model", "reference"),
                "reference",
                generation;
                model,
            ),
        )
    end
    for bundle in bundles
        validate_payload_schema(bundle, scope)
        if bundle.kind == "reference"
            validate_comparison_receipt(candidate_root, bundle, build, scope)
        else
            provenance = bundle.manifest["provenance"]
            get(provenance, "build_receipt_sha256", nothing) == build.sha256 ||
                fail(
                    "forcing manifest is not bound to the canonical build receipt",
                )
        end
        provenance = bundle.manifest["provenance"]
        get(provenance, "scope_manifest_sha256", nothing) == scope.sha256 ||
            fail(
                "$(isnothing(bundle.model) ? "forcing" : bundle.model) provenance differs from the exact Representative scope",
            )
    end
    identities = unique(getproperty.(bundles, :compatibility_identity))
    length(identities) == 1 ||
        fail("publication candidate is not one compatibility set")
    return (;
        generation,
        change_kind,
        models,
        bundles,
        compatibility_identity = only(identities),
    )
end

# ============================================================================
# Existing Publication Compatibility
# ============================================================================

function validate_expected_manifest(
    manifest,
    binding,
    kind,
    bindings;
    model = nothing,
)
    description =
        isnothing(model) ? "forcing expected manifest" :
        "$model expected reference manifest"
    get(manifest, "schema_version", nothing) == 1 ||
        fail("$description has an incompatible schema")
    get(manifest, "kind", nothing) == kind ||
        fail("$description declares the wrong bundle kind")
    get(manifest, "scope", nothing) == "representative" ||
        fail("$description is not Representative")
    generation = get(manifest, "generation", nothing)
    generation isa AbstractString &&
        occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", generation) ||
        fail("$description has an invalid generation")
    get(manifest, "outcome", nothing) == "passed" ||
        fail("$description did not pass")
    get(manifest, "canonical", nothing) === true || fail(
        "$description was not generated by the canonical Linux/GNU Fortran toolchain",
    )
    if kind == "reference"
        get(manifest, "model", nothing) == model ||
            fail("$description declares the wrong model")
    elseif haskey(manifest, "model")
        fail("forcing expected manifest must not declare a model")
    end

    provenance =
        validate_provenance(get(manifest, "provenance", nothing), description)
    valid_sha256(get(provenance, "build_receipt_sha256", nothing)) ||
        fail("$description lacks canonical build evidence")
    kind == "reference" &&
        !valid_sha256(get(provenance, "comparison_report_sha256", nothing)) &&
        fail("$description lacks successful comparison evidence")
    calculated = compatibility_identity(provenance)
    get(manifest, "compatibility_identity", nothing) == calculated ||
        fail("$description has stale compatibility provenance")

    declared_files =
        validate_hashes(get(manifest, "files", nothing), "$description files")
    payload = get(manifest, "payload", nothing)
    payload isa AbstractDict || fail("$description lacks payload roles")
    required_roles =
        kind == "forcing" ? ("fixture_manifest",) :
        REFERENCE_PAYLOAD_ROLES[model]
    Set(String.(keys(payload))) == Set(required_roles) ||
        fail("$description has incompatible payload roles")
    all(
        path -> path isa AbstractString && haskey(declared_files, path),
        values(payload),
    ) || fail("$description payload roles must identify declared files")

    artifact = get(manifest, "artifact", nothing)
    artifact isa AbstractDict || fail("$description lacks artifact identity")
    get(artifact, "binding", nothing) == binding ||
        fail("$description declares the wrong artifact binding")
    tree_sha1 = get(artifact, "git_tree_sha1", nothing)
    valid_sha1(tree_sha1) || fail("$description has an invalid artifact tree")
    archive_sha256 = get(artifact, "sha256", nothing)
    valid_sha256(archive_sha256) ||
        fail("$description has an invalid artifact SHA-256")
    filename = get(artifact, "filename", nothing)
    filename isa AbstractString &&
        basename(filename) == filename &&
        !isempty(filename) || fail("$description has an invalid asset filename")
    url = get(artifact, "url", nothing)
    url isa AbstractString &&
        occursin(
            r"^https://github\.com/[^/]+/[^/]+/releases/download/[^/?#]+/[^/?#]+$",
            url,
        ) &&
        endswith(url, "/$filename") ||
        fail("$description does not identify an immutable release asset")

    binding_record = get(bindings, binding, nothing)
    binding_record isa AbstractDict ||
        fail("$description artifact binding is missing")
    get(binding_record, "git-tree-sha1", nothing) == tree_sha1 ||
        fail("$description artifact binding has a different tree")
    downloads = get(binding_record, "download", nothing)
    downloads isa AbstractVector && length(downloads) == 1 ||
        fail("$description artifact binding must declare exactly one download")
    download = only(downloads)
    download isa AbstractDict &&
        get(download, "url", nothing) == url &&
        get(download, "sha256", nothing) == archive_sha256 ||
        fail("$description artifact binding differs from its review manifest")
    return calculated
end

function validate_existing_compatibility(
    expected_manifest_directory,
    artifacts_toml,
)
    isnothing(expected_manifest_directory) &&
        fail("model-only publication requires the existing expected manifests")
    bindings = parse_toml(artifacts_toml, "existing artifact bindings")
    all(
        name -> haskey(bindings, name),
        ("representative_forcing", values(BINDINGS)...),
    ) || fail(
        "existing artifact bindings do not contain a complete compatibility set",
    )
    identities = String[]
    forcing_binding = "representative_forcing"
    forcing_manifest = parse_toml(
        joinpath(expected_manifest_directory, "$forcing_binding.toml"),
        "forcing expected manifest",
    )
    push!(
        identities,
        validate_expected_manifest(
            forcing_manifest,
            forcing_binding,
            "forcing",
            bindings,
        ),
    )
    for model in MODELS
        binding = BINDINGS[model]
        manifest = parse_toml(
            joinpath(expected_manifest_directory, "$binding.toml"),
            "$model expected reference manifest",
        )
        push!(
            identities,
            validate_expected_manifest(
                manifest,
                binding,
                "reference",
                bindings;
                model,
            ),
        )
    end
    length(unique(identities)) == 1 ||
        fail("existing expected manifests are a partially mixed generation")
    return only(unique(identities))
end

function binding_name(bundle)
    return bundle.kind == "forcing" ? "representative_forcing" :
           BINDINGS[bundle.model]
end

function copy_payload(source, destination)
    for name in readdir(source)
        cp(joinpath(source, name), joinpath(destination, name); force = true)
    end
    return nothing
end

function normalize_gzip_header!(archive)
    open(archive, "r+") do io
        header = read(io, 10)
        length(header) == 10 || fail("archive has a truncated gzip header")
        header[1:3] == UInt8[0x1f, 0x8b, 0x08] ||
            fail("archive does not have the expected gzip header")
        seek(io, 4)
        write(io, zeros(UInt8, 4))
    end
    return archive
end

function create_archive(bundle, asset_directory, generation)
    tree_hash = Pkg.Artifacts.create_artifact() do artifact_directory
        copy_payload(bundle.payload, artifact_directory)
    end
    tree_sha1 = bytes2hex(tree_hash.bytes)
    binding = binding_name(bundle)
    filename = "$generation-$binding-$tree_sha1.tar.gz"
    archive = joinpath(asset_directory, filename)
    Pkg.Artifacts.archive_artifact(tree_hash, archive)
    normalize_gzip_header!(archive)
    sha256 = sha256sum(archive)
    chmod(archive, 0o444)
    return (; binding, filename, tree_hash, tree_sha1, sha256)
end

function write_expected_manifest(path, bundle, archive, release_base_url)
    manifest = deepcopy(bundle.manifest)
    manifest["compatibility_identity"] = bundle.compatibility_identity
    manifest["artifact"] = Dict(
        "binding" => archive.binding,
        "filename" => archive.filename,
        "git_tree_sha1" => archive.tree_sha1,
        "sha256" => archive.sha256,
        "url" => "$release_base_url/$(archive.filename)",
    )
    open(path, "w") do io
        TOML.print(io, manifest; sorted = true)
    end
    return manifest
end

# ============================================================================
# Atomic Publication Staging
# ============================================================================

"""
    _stage_prepared_publication(candidate_root, output, artifacts_toml,
                                release_base_url;
                                expected_manifest_directory = nothing)

Stage immutable archives, expected manifests, and artifact bindings atomically.

Return the output path, generation, and published model names. Existing output is
never overwritten.
"""
function _stage_prepared_publication(
    candidate_root,
    output,
    artifacts_toml,
    release_base_url;
    expected_manifest_directory = nothing,
)
    ispath(output) &&
        fail("publication output already exists and cannot be overwritten")
    occursin(
        r"^https://github\.com/[^/]+/[^/]+/releases/download/[^/?#]+$",
        release_base_url,
    ) || fail("release base URL must identify one immutable GitHub release")
    parse_toml(artifacts_toml, "existing artifact bindings")
    candidate_root = abspath(candidate_root)
    candidate = validate_candidate(candidate_root)
    if candidate.change_kind == "model"
        existing_identity = validate_existing_compatibility(
            expected_manifest_directory,
            artifacts_toml,
        )
        candidate.compatibility_identity == existing_identity || fail(
            "model-only publication differs from the existing compatibility set",
        )
    end

    output = abspath(output)
    parent = dirname(output)
    mkpath(parent)
    staging =
        mktempdir(parent; prefix = ".reference-publication-", cleanup = false)
    completed = false
    try
        assets = joinpath(staging, "assets")
        manifests = joinpath(staging, "manifests")
        evidence = joinpath(staging, "evidence")
        mkpath(assets)
        mkpath(manifests)
        mkpath(evidence)
        build_receipt = joinpath(candidate_root, "canonical_build_receipt.toml")
        staged_build_receipt =
            joinpath(evidence, "canonical_build_receipt.toml")
        cp(build_receipt, staged_build_receipt)
        chmod(staged_build_receipt, 0o444)
        evidence_records = Dict{String, String}(
            "canonical_build_receipt.toml" =>
                sha256sum(staged_build_receipt),
        )
        metadata_source = joinpath(candidate_root, "build_metadata.toml")
        metadata_destination = joinpath(evidence, "build_metadata.toml")
        cp(metadata_source, metadata_destination)
        chmod(metadata_destination, 0o444)
        evidence_records["build_metadata.toml"] =
            sha256sum(metadata_destination)
        for model in candidate.models
            source = joinpath(candidate_root, "model-$model", "comparison.toml")
            name = "$model-comparison.toml"
            destination = joinpath(evidence, name)
            cp(source, destination)
            chmod(destination, 0o444)
            evidence_records[name] = sha256sum(destination)
            source_comparison = joinpath(
                candidate_root,
                "model-$model",
                "source_comparison.toml",
            )
            source_name = "$model-source-comparison.toml"
            source_destination = joinpath(evidence, source_name)
            cp(source_comparison, source_destination)
            chmod(source_destination, 0o444)
            evidence_records[source_name] = sha256sum(source_destination)
            source_fortran = joinpath(
                candidate_root,
                "model-$model",
                "source_fortran_output.toml",
            )
            source_fortran_name = "$model-source-fortran-output.toml"
            source_fortran_destination = joinpath(evidence, source_fortran_name)
            cp(source_fortran, source_fortran_destination)
            chmod(source_fortran_destination, 0o444)
            evidence_records[source_fortran_name] =
                sha256sum(source_fortran_destination)
        end
        staged_artifacts = joinpath(staging, "Artifacts.toml")
        cp(artifacts_toml, staged_artifacts; force = true)
        asset_records = Dict{String, Any}[]
        for bundle in candidate.bundles
            archive = create_archive(bundle, assets, candidate.generation)
            url = "$release_base_url/$(archive.filename)"
            Pkg.Artifacts.bind_artifact!(
                staged_artifacts,
                archive.binding,
                archive.tree_hash;
                download_info = [(url, archive.sha256)],
                force = true,
            )
            write_expected_manifest(
                joinpath(manifests, "$(archive.binding).toml"),
                bundle,
                archive,
                release_base_url,
            )
            push!(
                asset_records,
                Dict(
                    "binding" => archive.binding,
                    "filename" => archive.filename,
                    "git_tree_sha1" => archive.tree_sha1,
                    "sha256" => archive.sha256,
                    "url" => url,
                ),
            )
        end
        open(joinpath(staging, "publication.toml"), "w") do io
            TOML.print(
                io,
                Dict(
                    "schema_version" => 1,
                    "operation" => "reference_publication",
                    "scope" => "representative",
                    "generation" => candidate.generation,
                    "change_kind" => candidate.change_kind,
                    "models" => candidate.models,
                    "compatibility_identity" =>
                        candidate.compatibility_identity,
                    "atomic_compatibility_set" =>
                        candidate.change_kind == "shared",
                    "evidence_sha256" => evidence_records,
                    "asset" => asset_records,
                );
                sorted = true,
            )
        end
        ispath(output) &&
            fail("publication output appeared before the atomic commit")
        mv(staging, output)
        completed = true
    finally
        completed || (ispath(staging) && rm(staging; recursive = true))
    end
    return (;
        output,
        generation = candidate.generation,
        models = candidate.models,
    )
end

function stage_publication(
    fresh_root,
    candidate_root,
    output,
    artifacts_toml,
    release_base_url;
    expected_manifest_directory = nothing,
)
    ispath(output) &&
        fail("publication output already exists and cannot be overwritten")
    candidate_root = abspath(candidate_root)
    prepared_root = mktempdir(; prefix = "reference-publication-candidate-")
    prepared_candidate = joinpath(prepared_root, "candidate")
    try
        cp(candidate_root, prepared_candidate)
        bind_canonical_evidence!(fresh_root, prepared_candidate)
        return _stage_prepared_publication(
            prepared_candidate,
            output,
            artifacts_toml,
            release_base_url;
            expected_manifest_directory,
        )
    finally
        rm(prepared_root; recursive = true, force = true)
    end
end

"""
    main(args = ARGS)

Run the explicit `construct` or `stage` publication command and return a
successful exit code.

Called from the script entry point after command-line arguments are collected.
"""
function main(args = ARGS)
    isempty(args) && fail("usage: reference_publication.jl construct|stage ...")
    if first(args) == "construct"
        length(args) == 5 || fail(
            "usage: reference_publication.jl construct FRESH_RUN FORCING " *
            "CANDIDATE GENERATION",
        )
        construct_candidate(args[2], args[3], args[4], args[5])
        return 0
    end
    first(args) == "stage" || fail("unknown reference-publication operation")
    5 <= length(args) <= 7 || fail(
        "usage: reference_publication.jl stage FRESH_RUN CANDIDATE OUTPUT " *
        "RELEASE_BASE_URL [ARTIFACTS_TOML [EXPECTED_MANIFEST_DIRECTORY]]",
    )
    fresh_root, candidate, output, release_base_url = args[2:5]
    artifacts_toml = length(args) >= 6 ? args[6] : DEFAULT_ARTIFACTS_TOML
    expected_manifest_directory = length(args) == 7 ? args[7] : nothing
    stage_publication(
        fresh_root,
        candidate,
        output,
        artifacts_toml,
        release_base_url;
        expected_manifest_directory,
    )
    return 0
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    try
        exit(TestbedReferencePublication.main())
    catch error
        error isa TestbedReferencePublication.PublicationError || rethrow()
        println(stderr, "ERROR: ", sprint(showerror, error))
        exit(2)
    end
end
