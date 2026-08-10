if !isdefined(@__MODULE__, :TestbedReferenceHarness)
    include(joinpath(@__DIR__, "reference_harness.jl"))
end

module TestbedCandidateReconstruction

import SHA
import TOML
import Test

const CANDIDATE_SPEC_PATH = joinpath(@__DIR__, "candidate_reconstruction.toml")

# ============================================================================
# Hashes and path safety
# ============================================================================

sha256sum(path) = bytes2hex(SHA.sha256(read(path)))

"""
    safe_relative_path(path, description)

Normalize a relative path and reject absolute or root-escaping values.
"""
function safe_relative_path(path, description)
    isabspath(path) && error("$description must be relative: $path")
    normalized = normpath(path)
    separator = string(Base.Filesystem.path_separator)
    (
        normalized == "." ||
        normalized == ".." ||
        startswith(normalized, ".." * separator)
    ) && error("$description escapes its root: $path")
    return normalized
end

"""
    canonical_path(path)

Resolve existing path prefixes so missing descendants still expose aliases.
"""
function canonical_path(path)
    current = abspath(path)
    suffix = String[]
    while !ispath(current)
        pushfirst!(suffix, basename(current))
        parent = dirname(current)
        parent == current && break
        current = parent
    end
    resolved = realpath(current)
    return isempty(suffix) ? resolved : normpath(joinpath(resolved, suffix...))
end

"""
    path_is_within(path, root)

Return whether `path` is contained by `root`, including through symlinks.
"""
function path_is_within(path, root)
    relative = relpath(canonical_path(path), canonical_path(root))
    separator = string(Base.Filesystem.path_separator)
    return relative == "." ||
           !(relative == ".." || startswith(relative, ".." * separator))
end

"""
    assert_disjoint_roots(left, right, left_name, right_name)

Reject overlapping or aliased roots that could overwrite immutable inputs.
"""
function assert_disjoint_roots(left, right, left_name, right_name)
    (path_is_within(left, right) || path_is_within(right, left)) && error(
        "$left_name and $right_name roots must not overlap or alias: " *
        "$(canonical_path(left)) and $(canonical_path(right))",
    )
    return nothing
end

# ============================================================================
# Candidate mutations and derivation
# ============================================================================

"""
    replace_control_value(line, before, after)

Replace one parsed control value while preserving comments and whitespace.
"""
function replace_control_value(line, before, after)
    parts = split(line, '!'; limit = 2)
    strip(parts[1]) == before || error(
        "Control value mismatch: expected '$before', found '$(strip(parts[1]))'",
    )
    if isempty(strip(parts[1]))
        newline =
            endswith(parts[1], "\r\n") ? "\r\n" :
            endswith(parts[1], "\n") ? "\n" : ""
        suffix = length(parts) == 2 ? "!" * parts[2] : ""
        return after * suffix * newline
    end
    whitespace = match(r"^(\s*).*?(\s*)$"s, parts[1])
    leading, trailing = whitespace.captures
    suffix = length(parts) == 2 ? "!" * parts[2] : ""
    return leading * after * trailing * suffix
end

"""
    mutation_record(mutation, line; extra = Dict{String, Any}())

Return the machine-readable audit record for one candidate mutation.
"""
function mutation_record(mutation, line; extra = Dict{String, Any}())
    record = Dict{String, Any}(
        "type" => mutation["type"],
        "line" => line,
        "before" => mutation["before"],
        "after" => mutation["after"],
        "changed" => mutation["before"] != mutation["after"],
    )
    merge!(record, extra)
    return record
end

"""
    apply_control_mutation(lines, mutation)

Apply one asserted line mutation to a Fortran control.
"""
function apply_control_mutation(lines, mutation)
    line_number = mutation["line"]
    1 <= line_number <= length(lines) ||
        error("Control mutation line $line_number is outside the file")
    derived = copy(lines)
    derived[line_number] = replace_control_value(
        lines[line_number],
        mutation["before"],
        mutation["after"],
    )
    record = mutation_record(
        mutation,
        line_number;
        extra = Dict("field" => mutation["field"]),
    )
    return derived, record
end

"""
    apply_named_parameter_mutation(lines, mutation)

Apply one asserted mutation to a uniquely named MIMICS parameter.

Called from [`apply_mutation`](@ref).
"""
function apply_named_parameter_mutation(lines, mutation)
    matches = Int[]
    for (line_number, line) in enumerate(lines)
        columns = split(line, ','; keepempty = true)
        length(columns) >= 2 || continue
        strip(columns[2]) == mutation["name"] && push!(matches, line_number)
    end
    length(matches) == 1 || error(
        "Expected one parameter named $(mutation["name"]); found $(length(matches))",
    )
    line_number = only(matches)
    columns = split(lines[line_number], ','; keepempty = true)
    strip(columns[1]) == mutation["before"] || error(
        "Parameter $(mutation["name"]) mismatch: expected " *
        "'$(mutation["before"])', found '$(strip(columns[1]))'",
    )
    leading = first(match(r"^(\s*)", columns[1]).captures)
    trailing = first(match(r"(\s*)$", columns[1]).captures)
    columns[1] = leading * mutation["after"] * trailing
    derived = copy(lines)
    derived[line_number] = join(columns, ',')
    record = mutation_record(
        mutation,
        line_number;
        extra = Dict("name" => mutation["name"]),
    )
    return derived, record
end

"""
    apply_casa_pft_mutation(lines, mutation)

Apply one asserted field mutation to a CASA PFT row.

Called from [`apply_mutation`](@ref).
"""
function apply_casa_pft_mutation(lines, mutation)
    header_matches = Int[]
    for (line_number, line) in enumerate(lines)
        columns = strip.(split(line, ','; keepempty = true))
        mutation["section"] in columns && push!(header_matches, line_number)
    end
    length(header_matches) == 1 || error(
        "Expected one CASA section $(mutation["section"]); found " *
        string(length(header_matches)),
    )
    header_line = only(header_matches)
    header = strip.(split(lines[header_line], ','; keepempty = true))
    field_matches = findall(==(mutation["field"]), header)
    length(field_matches) == 1 || error(
        "Expected one CASA field $(mutation["field"]); found " *
        string(length(field_matches)),
    )
    field_index = only(field_matches)
    row_matches = Int[]
    started_rows = false
    for line_number in (header_line + 1):length(lines)
        columns = split(lines[line_number], ','; keepempty = true)
        isempty(columns) && continue
        pft = tryparse(Int, strip(columns[1]))
        if isnothing(pft)
            started_rows && break
        else
            started_rows = true
            pft == mutation["pft"] && push!(row_matches, line_number)
        end
    end
    isempty(row_matches) && error(
        "CASA section $(mutation["section"]) has no PFT $(mutation["pft"])",
    )
    line_number = first(row_matches)
    columns = split(lines[line_number], ','; keepempty = true)
    length(columns) >= field_index ||
        error("CASA PFT row is shorter than its section header")
    strip(columns[field_index]) == mutation["before"] || error(
        "CASA $(mutation["field"]) mismatch for PFT $(mutation["pft"]): " *
        "expected '$(mutation["before"])', found " *
        "'$(strip(columns[field_index]))'",
    )
    leading = first(match(r"^(\s*)", columns[field_index]).captures)
    trailing = first(match(r"(\s*)$", columns[field_index]).captures)
    columns[field_index] = leading * mutation["after"] * trailing
    derived = copy(lines)
    derived[line_number] = join(columns, ',')
    record = mutation_record(
        mutation,
        line_number;
        extra = Dict(
            "section" => mutation["section"],
            "pft" => mutation["pft"],
            "field" => mutation["field"],
        ),
    )
    return derived, record
end

"""
    apply_mutation(lines, mutation)

Dispatch a specification mutation to its format-specific implementation.
"""
function apply_mutation(lines, mutation)
    mutation_type = mutation["type"]
    if mutation_type == "control_line"
        return apply_control_mutation(lines, mutation)
    elseif mutation_type == "named_parameter"
        return apply_named_parameter_mutation(lines, mutation)
    elseif mutation_type == "casa_pft_field"
        return apply_casa_pft_mutation(lines, mutation)
    end
    error("Unsupported candidate mutation type: $mutation_type")
end

"""
    checkout_commit(source_root)

Return the source checkout commit, or `"unavailable"` outside a Git checkout.
"""
function checkout_commit(source_root)
    git = Sys.which("git")
    isnothing(git) && return "unavailable"
    isdir(joinpath(source_root, ".git")) || return "unavailable"
    return try
        readchomp(Cmd([git, "-C", source_root, "rev-parse", "HEAD"]))
    catch
        "unavailable"
    end
end

"""
    candidate_record(candidate, source, destination, diffs)

Return provenance, evidence, hashes, and mutations for a derived candidate.

Called from [`derive_candidates`](@ref).
"""
function candidate_record(candidate, source, destination, diffs)
    harness = reference_harness_module()
    return Dict(
        "id" => candidate["id"],
        "kind" => candidate["kind"],
        "confidence" => candidate["confidence"],
        "source" => candidate["source"],
        "source_bytes" => filesize(source),
        "source_md5" => harness.md5sum(source),
        "source_sha256" => sha256sum(source),
        "destination" => candidate["destination"],
        "derived_bytes" => filesize(destination),
        "derived_md5" => harness.md5sum(destination),
        "derived_sha256" => sha256sum(destination),
        "evidence" => candidate["evidence"],
        "rejected_alternative" =>
            get(candidate, "rejected_alternative", String[]),
        "diff" => diffs,
    )
end

"""
    verify_expected_hash(candidate, field, actual)

Reject a candidate whose pinned source or derived hash changed.
"""
function verify_expected_hash(candidate, field, actual)
    expected = get(candidate, field, actual)
    actual == expected || error(
        "Candidate $(candidate["id"]) $field mismatch: expected " *
        "$expected, found $actual",
    )
    return actual
end

"""
    write_candidate_atomic(destination, content, candidate)

Write and hash-check candidate bytes before atomically replacing a destination.

Called from [`derive_candidates`](@ref).
"""
function write_candidate_atomic(destination, content, candidate)
    mkpath(dirname(destination))
    temporary, io = mktemp(dirname(destination))
    try
        write(io, content)
        close(io)
        verify_expected_hash(
            candidate,
            "expected_derived_sha256",
            sha256sum(temporary),
        )
        mv(temporary, destination; force = true)
    finally
        isopen(io) && close(io)
        ispath(temporary) && rm(temporary; force = true)
    end
    return destination
end

"""
    derive_candidate(source_root, candidate_id, destination,
                     spec_path = CANDIDATE_SPEC_PATH)

Derive one hash-pinned candidate directly from the immutable source checkout.

This is the production entry point for workflows that need one reconstructed
input without materializing the complete candidate matrix.
"""
function derive_candidate(
    source_root,
    candidate_id,
    destination,
    spec_path = CANDIDATE_SPEC_PATH,
)
    spec = TOML.parsefile(spec_path)
    get(spec, "schema_version", 0) == 1 ||
        error("Unsupported candidate specification schema")
    actual_commit = checkout_commit(source_root)
    expected_commit = spec["source_commit"]
    actual_commit in ("unavailable", expected_commit) || error(
        "Candidate source must be pinned to $expected_commit; found $actual_commit",
    )
    candidates = filter(
        candidate -> get(candidate, "id", nothing) == candidate_id,
        spec["candidate"],
    )
    length(candidates) == 1 ||
        error("Candidate specification does not uniquely define $candidate_id")
    candidate = only(candidates)
    source_relative =
        safe_relative_path(candidate["source"], "candidate source")
    source = joinpath(source_root, source_relative)
    isfile(source) || error("Missing candidate source: $source")
    path_is_within(source, source_root) ||
        error("Candidate source escapes its immutable source root: $source")
    path_is_within(destination, source_root) &&
        error("Candidate generation cannot write into its source tree")
    verify_expected_hash(candidate, "expected_source_sha256", sha256sum(source))

    lines = readlines(source; keep = true)
    diffs = Dict{String, Any}[]
    for mutation in candidate["mutation"]
        lines, record = apply_mutation(lines, mutation)
        push!(diffs, record)
    end
    write_candidate_atomic(destination, join(lines), candidate)
    return candidate_record(candidate, source, destination, diffs)
end

"""
    verify_validation_inputs(source_root, spec; expected_paths = nothing)

Verify every pinned upstream input staged by reduced validation.

Called from [`validate_candidates`](@ref).
"""
function verify_validation_inputs(source_root, spec; expected_paths = nothing)
    inputs = get(spec, "validation_input", Any[])
    records = Dict{String, Any}[]
    seen = String[]
    for input in inputs
        relative = safe_relative_path(input["path"], "validation input")
        relative in seen && error("Duplicate validation input: $relative")
        push!(seen, relative)
        path = joinpath(source_root, relative)
        isfile(path) || error("Missing validation input: $path")
        path_is_within(path, source_root) ||
            error("Validation input escapes its source root: $path")
        actual = sha256sum(path)
        actual == input["sha256"] || error(
            "Validation input $relative hash mismatch: expected " *
            "$(input["sha256"]), found $actual",
        )
        push!(records, Dict("path" => relative, "sha256" => actual))
    end
    if !isnothing(expected_paths)
        Set(seen) == Set(expected_paths) || error(
            "Validation input hash specification does not match the staged " *
            "source inputs",
        )
    end
    return records
end

"""
    verify_fixture_inputs(fixture_dir)

Verify the byte counts and SHA-256 hashes in a reduced fixture manifest.
"""
function verify_fixture_inputs(fixture_dir)
    manifest_path = joinpath(fixture_dir, "fixture.toml")
    isfile(manifest_path) || error("Missing fixture manifest: $manifest_path")
    fixture = TOML.parsefile(manifest_path)["fixture"]
    records = Dict{String, Any}[]
    for id in ("grid", "soil", "driver")
        haskey(fixture, id) || error("Fixture manifest has no $id entry")
        entry = fixture[id]
        relative = safe_relative_path(entry["filename"], "fixture $id")
        path = joinpath(fixture_dir, relative)
        isfile(path) || error("Missing fixture $id file: $path")
        path_is_within(path, fixture_dir) ||
            error("Fixture $id escapes its fixture root: $path")
        filesize(path) == entry["bytes"] || error(
            "Fixture $id byte count mismatch: expected $(entry["bytes"]), " *
            "found $(filesize(path))",
        )
        actual = sha256sum(path)
        actual == entry["sha256"] || error(
            "Fixture $id hash mismatch: expected $(entry["sha256"]), " *
            "found $actual",
        )
        push!(
            records,
            Dict(
                "id" => id,
                "filename" => relative,
                "bytes" => filesize(path),
                "sha256" => actual,
            ),
        )
    end
    return records
end

"""
    derive_candidates(source_root, output_root, spec_path = CANDIDATE_SPEC_PATH)

Generate the auditable candidate set without writing into the source checkout.

# Returns
The path to the generated `derivation_report.toml`.
"""
function derive_candidates(
    source_root,
    output_root,
    spec_path = CANDIDATE_SPEC_PATH,
)
    spec = TOML.parsefile(spec_path)
    get(spec, "schema_version", 0) == 1 ||
        error("Unsupported candidate specification schema")
    assert_disjoint_roots(
        source_root,
        output_root,
        "Candidate source",
        "candidate output",
    )
    actual_commit = checkout_commit(source_root)
    expected_commit = spec["source_commit"]
    actual_commit in ("unavailable", expected_commit) || error(
        "Candidate source must be pinned to $expected_commit; found $actual_commit",
    )

    records = Dict{String, Any}[]
    for candidate in spec["candidate"]
        destination_relative = safe_relative_path(
            candidate["destination"],
            "candidate destination",
        )
        destination = joinpath(output_root, destination_relative)
        path_is_within(destination, output_root) ||
            error("Candidate destination escapes its output root: $destination")
        push!(
            records,
            derive_candidate(
                source_root,
                candidate["id"],
                destination,
                spec_path,
            ),
        )
    end

    report = Dict(
        "schema_version" => 1,
        "classification" => "derived candidates, not upstream originals",
        "source_commit_expected" => expected_commit,
        "source_commit_actual" => actual_commit,
        "specification" => abspath(spec_path),
        "specification_sha256" => sha256sum(spec_path),
        "candidate" => records,
    )
    return reference_harness_module().write_toml_atomic(
        joinpath(output_root, "derivation_report.toml"),
        report,
    )
end

# ============================================================================
# Reduced-prespin validation
# ============================================================================

"""
    validation_cases(spec_path = CANDIDATE_SPEC_PATH)

Return the candidate-to-control matrix exercised by reduced validation.
"""
function validation_cases(spec_path = CANDIDATE_SPEC_PATH)
    candidates = TOML.parsefile(spec_path)["candidate"]
    return map(candidates) do candidate
        kind = candidate["kind"]
        candidate_reference = "candidate:" * candidate["destination"]
        casa_parameter =
            kind == "casa_parameter" ? candidate_reference :
            candidate["validation_casa_parameter"]
        mimics_parameter =
            kind == "mimics_parameter" ? candidate_reference :
            get(candidate, "validation_mimics_parameter", nothing)
        control_candidate = kind == "control" ? candidate_reference : nothing
        return (;
            id = candidate["id"],
            soil_model = candidate["validation_soil_model"],
            cycle = candidate["validation_cycle"],
            casa_parameter,
            mimics_parameter,
            control_candidate,
        )
    end
end

"""
    validation_source_paths(spec_path = CANDIDATE_SPEC_PATH)

Return the complete set of upstream files required by the validation matrix.

Called from [`validate_candidates`](@ref).
"""
function validation_source_paths(spec_path = CANDIDATE_SPEC_PATH)
    paths =
        ["GRID_CN/modis_phenology_wtundra.txt", "GRID_CN/co2delta_control.txt"]
    for case in validation_cases(spec_path)
        for reference in (case.casa_parameter, case.mimics_parameter)
            isnothing(reference) && continue
            prefix, relative = split(reference, ':'; limit = 2)
            prefix == "source" && push!(paths, relative)
        end
    end
    return sort!(unique!(paths))
end

"""
    reference_harness_module()

Return the loaded pinned-Fortran reference harness module.
"""
function reference_harness_module()
    parent = parentmodule(@__MODULE__)
    isdefined(parent, :TestbedReferenceHarness) ||
        error("TestbedReferenceHarness was not loaded before reconstruction")
    return getfield(parent, :TestbedReferenceHarness)
end

"""
    resolve_validation_parameter(reference, source_root, candidate_root)

Resolve a `source:` or `candidate:` parameter reference to a verified file.
"""
function resolve_validation_parameter(reference, source_root, candidate_root)
    prefix, relative = split(reference, ':'; limit = 2)
    root = if prefix == "source"
        source_root
    elseif prefix == "candidate"
        candidate_root
    else
        error("Unsupported validation parameter origin: $prefix")
    end
    path = joinpath(root, safe_relative_path(relative, "validation parameter"))
    isfile(path) || error("Missing validation parameter: $path")
    return abspath(path)
end

"""
    write_reduced_candidate_control(source, destination, case)

Reduce only runtime extent, required input, and output fields for one case.

The candidate's model, nutrient cycle, vegetation count, daily-output mode,
initial-path fields, and NetCDF interval are preserved for the pinned Fortran
parser and executor.

Called from [`write_validation_workflow`](@ref).
"""
function write_reduced_candidate_control(source, destination, case)
    harness = reference_harness_module()
    parsed = harness.parse_control(source)
    parsed[:soil_model] == case.soil_model || error(
        "Candidate control $(case.id) has soil model $(parsed[:soil_model]); " *
        "expected $(case.soil_model)",
    )
    parsed[:cycle] == case.cycle || error(
        "Candidate control $(case.id) has cycle $(parsed[:cycle]); " *
        "expected $(case.cycle)",
    )

    mktempdir() do temporary
        target = harness.write_smoke_control(
            temporary;
            points = 1,
            loops = 1,
            daily_output = 0,
            initialization = 0,
            years = (1901, 1901),
            soil_model = case.soil_model,
            cycle = case.cycle,
            casa_parameters = "casa_parameters.csv",
            meteorology = "met_1901_1901.nc",
            casa_final = "casa_final.csv",
            casa_flux_final = "casa_flux_final.csv",
            casa_netcdf = "casaclm_pool_flux_yyyy.nc",
            mimics_parameters = "mimics_parameters.csv",
            mimics_final = "mimics_final.csv",
            mimics_netcdf = "mimics_pool_flux_yyyy.nc",
        )
        source_lines = readlines(source; keep = true)
        target_lines = readlines(target; keep = true)
        reduction_fields = Set((
            :points,
            :loops,
            :initialization,
            :years,
            :grid_info,
            :casa_parameters,
            :phenology,
            :soil_properties,
            :meteorology,
            :casa_final,
            :casa_flux_final,
            :casa_netcdf,
            :mimics_parameters,
            :mimics_final,
            :mimics_netcdf,
            :perturbation,
        ))
        diffs = Dict{String, Any}[]
        for (line, field) in enumerate(harness.CONTROL_FIELDS)
            field in reduction_fields || continue
            mutation = Dict(
                "type" => "control_line",
                "line" => line,
                "field" => string(field),
                "before" => harness.control_value(source_lines[line]),
                "after" => harness.control_value(target_lines[line]),
            )
            source_lines, record =
                apply_control_mutation(source_lines, mutation)
            push!(diffs, record)
        end
        mkpath(dirname(abspath(destination)))
        write(destination, join(source_lines))
        return Dict(
            "candidate" => case.id,
            "source" => abspath(source),
            "source_sha256" => sha256sum(source),
            "destination" => abspath(destination),
            "derived_sha256" => sha256sum(destination),
            "diff" => diffs,
        )
    end
end

"""
    assert_validation_roots(source_root, fixture_dir, candidate_root, run_root)

Reject validation roots that could overwrite source, candidates, or fixtures.
"""
function assert_validation_roots(
    source_root,
    fixture_dir,
    candidate_root,
    run_root,
)
    assert_disjoint_roots(
        source_root,
        run_root,
        "Candidate source",
        "validation run",
    )
    assert_disjoint_roots(
        candidate_root,
        run_root,
        "Candidate output",
        "validation run",
    )
    assert_disjoint_roots(
        fixture_dir,
        run_root,
        "Validation fixture",
        "validation run",
    )
    assert_disjoint_roots(
        fixture_dir,
        candidate_root,
        "Validation fixture",
        "candidate output",
    )
    return nothing
end

"""
    write_validation_workflow(source_root, fixture_dir, candidate_root, run_root,
                              spec_path = CANDIDATE_SPEC_PATH)

Materialize the two-repeat workflow and auditable minimal control reductions.

Called from [`validate_candidates`](@ref).
"""
function write_validation_workflow(
    source_root,
    fixture_dir,
    candidate_root,
    run_root,
    spec_path = CANDIDATE_SPEC_PATH,
)
    assert_validation_roots(source_root, fixture_dir, candidate_root, run_root)
    verify_fixture_inputs(fixture_dir)
    harness = reference_harness_module()
    fixture_manifest = TOML.parsefile(joinpath(fixture_dir, "fixture.toml"))
    fixture = fixture_manifest["fixture"]
    fixture_file(key) = abspath(joinpath(fixture_dir, fixture[key]["filename"]))
    source_file(relative) = abspath(joinpath(source_root, relative))
    configuration = joinpath(run_root, "candidate_validation_configuration")
    controls = joinpath(configuration, "controls")
    mkpath(controls)
    stages = Dict{String, Any}[]
    reductions = Dict{String, Any}[]

    for case in validation_cases(spec_path), repeat in 1:2
        control_name = "$(case.id)-repeat-$repeat.lst"
        control_path = joinpath(controls, control_name)
        if isnothing(case.control_candidate)
            control = harness.write_smoke_control(
                controls;
                points = 1,
                loops = 1,
                daily_output = 0,
                initialization = 0,
                years = (1901, 1901),
                soil_model = case.soil_model,
                cycle = case.cycle,
                casa_parameters = "casa_parameters.csv",
                meteorology = "met_1901_1901.nc",
                casa_final = "casa_final.csv",
                casa_flux_final = "casa_flux_final.csv",
                casa_netcdf = "casaclm_pool_flux_yyyy.nc",
                mimics_parameters = "mimics_parameters.csv",
                mimics_final = "mimics_final.csv",
                mimics_netcdf = "mimics_pool_flux_yyyy.nc",
            )
            mv(control, control_path; force = true)
        else
            source_control = resolve_validation_parameter(
                case.control_candidate,
                source_root,
                candidate_root,
            )
            reduction = write_reduced_candidate_control(
                source_control,
                control_path,
                case,
            )
            repeat == 1 && push!(reductions, reduction)
        end

        inputs = [
            harness.workflow_input(fixture_file("grid"), "grid.csv"),
            harness.workflow_input(fixture_file("soil"), "soil.csv"),
            harness.workflow_input(
                fixture_file("driver"),
                "met_1901_1901.nc";
                mode = "symlink",
            ),
            harness.workflow_input(
                source_file("GRID_CN/modis_phenology_wtundra.txt"),
                "phenology.txt",
            ),
            harness.workflow_input(
                source_file("GRID_CN/co2delta_control.txt"),
                "perturbation.txt",
            ),
            harness.workflow_input(
                resolve_validation_parameter(
                    case.casa_parameter,
                    source_root,
                    candidate_root,
                ),
                "casa_parameters.csv",
            ),
        ]
        outputs = ["casa_final.csv", "casa_flux_final.csv"]
        if case.soil_model == 2
            push!(
                inputs,
                harness.workflow_input(
                    resolve_validation_parameter(
                        case.mimics_parameter,
                        source_root,
                        candidate_root,
                    ),
                    "mimics_parameters.csv",
                ),
            )
            push!(outputs, "mimics_final.csv")
        end
        push!(
            stages,
            Dict(
                "name" => "$(case.id)-repeat-$repeat",
                "control" => relpath(control_path, configuration),
                "outputs" => outputs,
                "input" => inputs,
            ),
        )
    end

    workflow = Dict(
        "schema_version" => 1,
        "name" => "candidate-reduced-prespin-validation",
        "source_commit" => checkout_commit(source_root),
        "stage" => stages,
    )
    workflow_path = joinpath(configuration, "workflow.toml")
    harness.write_toml_atomic(workflow_path, workflow)
    reduction_report = joinpath(configuration, "control_reduction_report.toml")
    harness.write_toml_atomic(
        reduction_report,
        Dict(
            "schema_version" => 1,
            "source_commit" => checkout_commit(source_root),
            "reduction" => reductions,
        ),
    )
    return (; workflow_path, reduction_report)
end

"""
    validation_records(results, spec_path = CANDIDATE_SPEC_PATH)

Verify repeat hashes and return one auditable record per candidate case.

Called from [`validate_candidates`](@ref).
"""
function validation_records(results, spec_path = CANDIDATE_SPEC_PATH)
    records = Dict{String, Any}[]
    by_name = Dict(result.name => result for result in results)
    for case in validation_cases(spec_path)
        repeats = Dict{String, Any}[]
        hashes = Dict{String, String}[]
        for repeat in 1:2
            result = by_name["$(case.id)-repeat-$repeat"]
            metadata = TOML.parsefile(
                joinpath(result.directory, "stage_metadata.toml"),
            )
            output_hashes = Dict(
                name => output["md5"] for (name, output) in metadata["outputs"]
            )
            push!(hashes, output_hashes)
            push!(
                repeats,
                Dict(
                    "repeat" => repeat,
                    "stage_directory" => result.directory,
                    "control_md5" => metadata["control"]["materialized_md5"],
                    "outputs" => output_hashes,
                ),
            )
        end
        hashes[1] == hashes[2] ||
            error("Reduced prespin is not deterministic for $(case.id)")
        push!(
            records,
            Dict(
                "id" => case.id,
                "soil_model" => case.soil_model,
                "cycle" => case.cycle,
                "status" => "pass_deterministic_reduced_prespin",
                "repeat" => repeats,
            ),
        )
    end
    return records
end

"""
    validate_candidates(source_root, fixture_dir, candidate_root, run_root,
                        spec_path = CANDIDATE_SPEC_PATH)

Generate every candidate and run two deterministic reduced prespins with the
pinned Fortran executable.

# Returns
The path to `reduced_prespin_validation.toml`.
"""
function validate_candidates(
    source_root,
    fixture_dir,
    candidate_root,
    run_root,
    spec_path = CANDIDATE_SPEC_PATH,
)
    assert_validation_roots(source_root, fixture_dir, candidate_root, run_root)
    spec = TOML.parsefile(spec_path)
    validation_inputs = verify_validation_inputs(
        source_root,
        spec;
        expected_paths = validation_source_paths(spec_path),
    )
    fixture_inputs = verify_fixture_inputs(fixture_dir)
    derivation_report =
        derive_candidates(source_root, candidate_root, spec_path)
    harness = reference_harness_module()
    executable = harness.ensure_fortran_build(source_root, run_root)
    validation_workflow = write_validation_workflow(
        source_root,
        fixture_dir,
        candidate_root,
        run_root,
        spec_path,
    )
    results = harness.run_stage_workflow(
        executable,
        validation_workflow.workflow_path,
        run_root,
    )
    report = Dict(
        "schema_version" => 1,
        "status" => "pass",
        "scope" => "parameter parsing and deterministic one-cell one-year prespin",
        "source_commit" => checkout_commit(source_root),
        "derivation_report" => abspath(derivation_report),
        "derivation_report_sha256" => sha256sum(derivation_report),
        "fixture" => abspath(joinpath(fixture_dir, "fixture.toml")),
        "fixture_sha256" =>
            sha256sum(joinpath(fixture_dir, "fixture.toml")),
        "fixture_input" => fixture_inputs,
        "validation_input" => validation_inputs,
        "executable" => harness.executable_provenance(executable),
        "control_reduction_report" =>
            abspath(validation_workflow.reduction_report),
        "control_reduction_report_sha256" =>
            sha256sum(validation_workflow.reduction_report),
        "case" => validation_records(results, spec_path),
    )
    report_path = joinpath(candidate_root, "reduced_prespin_validation.toml")
    harness.write_toml_atomic(report_path, report)
    println("Candidate reduced-prespin validation: $report_path")
    return report_path
end

"""
    self_test()

Run the standalone candidate-reconstruction test set.
"""
function self_test()
    include(joinpath(@__DIR__, "candidate_reconstruction_tests.jl"))
end

# ============================================================================
# Command-line interface
# ============================================================================

"""
    usage(io = stdout)

Print candidate-reconstruction command usage.
"""
function usage(io = stdout)
    println(
        io,
        "usage: julia candidate_reconstruction.jl generate " *
        "<testbed-source-root> <output-root> [spec.toml]",
    )
    println(
        io,
        "       julia candidate_reconstruction.jl validate " *
        "<testbed-source-root> <fixture-dir> <output-root> <run-root> " *
        "[spec.toml]",
    )
    println(io, "       julia candidate_reconstruction.jl self-test")
end

"""
    main(args)

Run candidate generation, pinned validation, or standalone self-tests.

# Returns
Process exit status `0` on success, `1` on runtime failure, or `2` for usage
errors.
"""
function main(args)
    try
        if !isempty(args) && args[1] == "generate" && length(args) in (3, 4)
            spec_path = length(args) == 4 ? args[4] : CANDIDATE_SPEC_PATH
            report = derive_candidates(args[2], args[3], spec_path)
            println("Candidate derivation report: $report")
        elseif !isempty(args) && args[1] == "validate" && length(args) in (5, 6)
            spec_path = length(args) == 6 ? args[6] : CANDIDATE_SPEC_PATH
            validate_candidates(args[2], args[3], args[4], args[5], spec_path)
        elseif args == ["self-test"]
            self_test()
        else
            usage(stderr)
            return 2
        end
        return 0
    catch error_value
        println(stderr, "error: ", sprint(showerror, error_value))
        return 1
    end
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(TestbedCandidateReconstruction.main(ARGS))
end
