module TestbedReferenceHarness

import TOML
import Test
import SHA

const HARNESS_DIR = @__DIR__
const MANIFEST_PATH = joinpath(HARNESS_DIR, "experiments.toml")
const PROVENANCE_PATH = joinpath(HARNESS_DIR, "provenance_attempts.toml")
const CONTROL_FIELDS = (
    :points,
    :vegetation_types,
    :loops,
    :daily_output,
    :initialization,
    :years,
    :soil_model,
    :cycle,
    :grid_info,
    :casa_parameters,
    :phenology,
    :soil_properties,
    :meteorology,
    :casa_initial,
    :casa_final,
    :casa_flux_final,
    :casa_netcdf,
    :mimics_parameters,
    :mimics_initial,
    :mimics_final,
    :mimics_netcdf,
    :corpse_initial,
    :corpse_final,
    :corpse_parameters,
    :corpse_netcdf,
    :perturbation,
    :point_output_index,
    :point_output_directory,
    :netcdf_interval,
)

# ============================================================================
# Manifest, controls, and artifacts
# ============================================================================

load_manifest(path = MANIFEST_PATH) = TOML.parsefile(path)

function control_value(line)
    value = strip(first(split(line, '!'; limit = 2)))
    isempty(value) && error("Control line has no value: $line")
    return value
end

function parse_control(path)
    lines = readlines(path)
    length(lines) >= length(CONTROL_FIELDS) || error(
        "Expected at least $(length(CONTROL_FIELDS)) control lines in $path",
    )
    values = map(control_value, lines[eachindex(CONTROL_FIELDS)])
    parsed = Dict{Symbol, Any}(zip(CONTROL_FIELDS, values))
    for field in (
        :points,
        :vegetation_types,
        :loops,
        :daily_output,
        :initialization,
        :soil_model,
        :cycle,
        :point_output_index,
        :netcdf_interval,
    )
        parsed[field] = parse(Int, first(split(parsed[field])))
    end
    parsed[:years] = Tuple(parse.(Int, split(parsed[:years])))
    return parsed
end

function control_dependencies(control)
    dependencies = [
        (:grid_info, control[:grid_info]),
        (:casa_parameters, control[:casa_parameters]),
        (:phenology, control[:phenology]),
        (:soil_properties, control[:soil_properties]),
        (:meteorology, control[:meteorology]),
        (:perturbation, control[:perturbation]),
    ]
    control[:initialization] > 0 &&
        push!(dependencies, (:casa_initial, control[:casa_initial]))
    if control[:soil_model] == 2
        push!(dependencies, (:mimics_parameters, control[:mimics_parameters]))
        control[:initialization] > 0 &&
            push!(dependencies, (:mimics_initial, control[:mimics_initial]))
    elseif control[:soil_model] == 3
        push!(dependencies, (:corpse_parameters, control[:corpse_parameters]))
        control[:initialization] > 0 &&
            push!(dependencies, (:corpse_initial, control[:corpse_initial]))
    end
    return dependencies
end

function audit_control(path)
    control = parse_control(path)
    root = dirname(abspath(path))
    println("control md5: ", md5sum(path))
    println(
        "points=$(control[:points]) model=$(control[:soil_model]) ",
        "cycle=$(control[:cycle]) init=$(control[:initialization]) ",
        "loops=$(control[:loops]) years=$(control[:years])",
    )
    all_present = true
    for (name, raw_path) in control_dependencies(control)
        resolved = normpath(joinpath(root, raw_path))
        present = isfile(resolved)
        all_present &= present
        println(
            rpad(string(name), 22),
            rpad(present ? "present" : "missing", 10),
            resolved,
        )
    end
    return all_present
end

function artifact_status(artifact, data_root)
    path = joinpath(data_root, artifact["filename"])
    isfile(path) ||
        return (; ok = false, status = :missing, path, detail = "missing")
    actual_bytes = filesize(path)
    expected_bytes = artifact["bytes"]
    actual_bytes == expected_bytes || return (;
        ok = false,
        status = :size_mismatch,
        path,
        detail = "expected $expected_bytes bytes, found $actual_bytes",
    )
    return (;
        ok = true,
        status = :present,
        path,
        detail = "$actual_bytes bytes",
    )
end

function md5sum(path)
    md5sum_exe = Sys.which("md5sum")
    if !isnothing(md5sum_exe)
        return first(split(read(Cmd([md5sum_exe, path]), String)))
    end
    md5_exe = Sys.which("md5")
    isnothing(md5_exe) && error("Neither md5sum nor md5 is available")
    output = read(Cmd([md5_exe, "-q", path]), String)
    return strip(output)
end

# ============================================================================
# Restart transformations
# ============================================================================

function increment_decimal_exponent(exponent)
    parsed = parse(Int, exponent)
    incremented = parsed + 1
    width = length(exponent) - (first(exponent) in ('+', '-') ? 1 : 0)
    digits = lpad(string(abs(incremented)), width, '0')
    sign = if incremented < 0
        "-"
    elseif startswith(exponent, "+") || startswith(exponent, "-")
        "+"
    else
        ""
    end
    return sign * digits
end

function multiply_decimal_by_ten(token)
    matched =
        match(r"^(\s*)([+-]?)(\d+)(?:\.(\d*))?([eEdD])([+-]?\d+)(\s*)$", token)
    if !isnothing(matched)
        leading, sign, integer, fraction, marker, exponent, trailing =
            matched.captures
        decimal = isnothing(fraction) ? integer : integer * "." * fraction
        return leading *
               sign *
               decimal *
               marker *
               increment_decimal_exponent(exponent) *
               trailing
    end

    matched = match(r"^(\s*)([+-]?)(\d+)(?:\.(\d*))?(\s*)$", token)
    isnothing(matched) && error("Unsupported decimal restart value: '$token'")
    leading, sign, integer, fraction, trailing = matched.captures
    if isnothing(fraction)
        return leading * sign * string(parse(BigInt, integer) * 10) * trailing
    elseif isempty(fraction)
        return leading *
               sign *
               string(parse(BigInt, integer) * 10) *
               "." *
               trailing
    end
    digits_after_decimal = length(fraction)
    scaled = string(parse(BigInt, integer * fraction) * 10)
    padded = lpad(scaled, digits_after_decimal + 1, '0')
    split_at = length(padded) - digits_after_decimal
    value = padded[1:split_at] * "." * padded[(split_at + 1):end]
    return leading * sign * value * trailing
end

"""
    restore_casa_passive_pools(source, destination, passive_fields)

Scale the named passive-pool fields by ten without changing other restart text.

Called from [`restore_casa_passive_carbon`](@ref) and
[`restore_casa_passive_carbon_nitrogen`](@ref).
"""
function restore_casa_passive_pools(source, destination, passive_fields)
    lines = readlines(source; keep = true)
    isempty(lines) && error("CASA restart file is empty: $source")
    header = split(lines[1], ',')
    passive_columns = map(passive_fields) do field
        matching = findall(value -> strip(value) == field, header)
        length(matching) == 1 || error(
            "Expected one $field column in $source; found " *
            string(length(matching)),
        )
        only(matching)
    end
    transformed = String[lines[1]]
    for (line_number, line) in zip(2:length(lines), lines[2:end])
        columns = split(line, ','; keepempty = true)
        valid_trailing_comma =
            length(columns) == length(header) + 1 &&
            isempty(strip(last(columns)))
        (length(columns) == length(header) || valid_trailing_comma) || error(
            "Restart row $line_number has $(length(columns)) columns; " *
            "expected $(length(header)) plus an optional trailing comma",
        )
        for passive_column in passive_columns
            columns[passive_column] =
                multiply_decimal_by_ten(columns[passive_column])
        end
        push!(transformed, join(columns, ','))
    end
    mkpath(dirname(abspath(destination)))
    write(destination, join(transformed))
    return destination
end

restore_casa_passive_carbon(source, destination) =
    restore_casa_passive_pools(source, destination, ("casapool%csoil(PASS)",))

restore_casa_passive_carbon_nitrogen(source, destination) =
    restore_casa_passive_pools(
        source,
        destination,
        ("casapool%csoil(PASS)", "casapool%nsoil(PASS)"),
    )

# ============================================================================
# Resumable workflow orchestration
# ============================================================================

function write_toml_atomic(path, value)
    mkpath(dirname(abspath(path)))
    temporary = path * ".tmp"
    open(temporary, "w") do io
        TOML.print(io, value; sorted = true)
    end
    mv(temporary, path; force = true)
    return path
end

function fingerprint(value)
    io = IOBuffer()
    TOML.print(io, value; sorted = true)
    return bytes2hex(SHA.sha256(take!(io)))
end

function safe_relative_path(path, description)
    isabspath(path) && error("$description must be relative: $path")
    normalized = normpath(path)
    normalized == "." && error("$description must name a file: $path")
    (
        normalized == ".." ||
        startswith(normalized, ".." * Base.Filesystem.path_separator)
    ) && error("$description escapes its stage directory: $path")
    return normalized
end

const RUNNER_OWNED_STAGE_PATHS =
    Set(("fcasacnp_clm_testbed.lst", "run.log", "stage_metadata.toml"))

function runner_owned_stage_path(path)
    separator = string(Base.Filesystem.path_separator)
    return any(RUNNER_OWNED_STAGE_PATHS) do owned
        path == owned || startswith(path, owned * separator)
    end
end

function stage_paths_overlap(first_path, second_path)
    separator = string(Base.Filesystem.path_separator)
    return first_path == second_path ||
           startswith(first_path, second_path * separator) ||
           startswith(second_path, first_path * separator)
end

function paths_are_disjoint(paths)
    return all(
        first_index >= second_index ||
        !stage_paths_overlap(paths[first_index], paths[second_index]) for
        first_index in eachindex(paths) for second_index in eachindex(paths)
    )
end

function validate_stage_paths(stage)
    destinations = [
        safe_relative_path(input["destination"], "input destination") for
        input in get(stage, "input", [])
    ]
    outputs = [
        safe_relative_path(output, "stage output") for
        output in stage["outputs"]
    ]
    paths_are_disjoint(destinations) ||
        error("Stage input destinations must be disjoint")
    paths_are_disjoint(outputs) || error("Stage outputs must be disjoint")
    paths_are_disjoint([destinations; outputs]) ||
        error("Stage inputs and outputs must use disjoint paths")
    reserved = filter(runner_owned_stage_path, [destinations; outputs])
    isempty(reserved) || error(
        "Stage paths are reserved for workflow provenance: " *
        join(reserved, ", "),
    )
    return outputs
end

function resolve_spec_path(spec_dir, path)
    return normpath(isabspath(path) ? path : joinpath(spec_dir, path))
end

function resolve_stage_input(source, spec_dir, stage_dirs)
    startswith(source, "stage:") || return resolve_spec_path(spec_dir, source)
    reference = source[(length("stage:") + 1):end]
    parts = split(reference, '/'; limit = 2)
    length(parts) == 2 ||
        error("Stage input must use stage:<name>/<output>: $source")
    stage_name, relative = parts
    haskey(stage_dirs, stage_name) ||
        error("Stage input references unavailable stage '$stage_name'")
    relative = safe_relative_path(relative, "stage input")
    return joinpath(stage_dirs[stage_name], relative)
end

function materialize_stage_input(input, spec_dir, stage_dir, stage_dirs)
    source = resolve_stage_input(input["source"], spec_dir, stage_dirs)
    isfile(source) || error("Missing workflow input: $source")
    destination_relative =
        safe_relative_path(input["destination"], "input destination")
    destination = joinpath(stage_dir, destination_relative)
    mkpath(dirname(destination))
    transform = get(input, "transform", "none")
    mode = get(input, "mode", "copy")
    transform != "none" &&
        mode != "copy" &&
        error("Transformed workflow inputs must use copy mode")
    if transform == "casa_passive_carbon_x10"
        restore_casa_passive_carbon(source, destination)
    elseif transform == "casa_passive_carbon_nitrogen_x10"
        restore_casa_passive_carbon_nitrogen(source, destination)
    elseif transform == "none"
        if mode == "copy"
            cp(source, destination; force = true)
        elseif mode == "symlink"
            ispath(destination) && rm(destination; force = true)
            symlink(abspath(source), destination)
        else
            error("Unsupported workflow input mode: $mode")
        end
    else
        error("Unsupported workflow input transform: $transform")
    end
    return Dict(
        "source" => abspath(source),
        "source_md5" => md5sum(source),
        "destination" => destination_relative,
        "materialized_md5" => md5sum(destination),
        "bytes" => filesize(destination),
        "mode" => mode,
        "transform" => transform,
    )
end

function output_records(stage_dir, outputs)
    return Dict(
        output => Dict(
            "bytes" => filesize(joinpath(stage_dir, output)),
            "md5" => md5sum(joinpath(stage_dir, output)),
        ) for output in outputs
    )
end

function reusable_stage(metadata_path, expected_fingerprint, stage_dir, outputs)
    isfile(metadata_path) || return false
    metadata = try
        TOML.parsefile(metadata_path)
    catch
        return false
    end
    get(metadata, "status", "") == "complete" || return false
    get(metadata, "fingerprint", "") == expected_fingerprint || return false
    recorded_outputs = get(metadata, "outputs", Dict())
    Set(keys(recorded_outputs)) == Set(outputs) || return false
    for output in outputs
        path = joinpath(stage_dir, output)
        isfile(path) || return false
        record = recorded_outputs[output]
        filesize(path) == record["bytes"] || return false
        md5sum(path) == record["md5"] || return false
    end
    return true
end

function recoverable_output_contract_stage(
    metadata_path,
    name,
    stage_dir,
    outputs,
    expected_execution_fingerprint,
)
    isfile(metadata_path) || return nothing
    metadata = try
        TOML.parsefile(metadata_path)
    catch
        return nothing
    end
    get(metadata, "status", "") == "failed" || return nothing
    startswith(get(metadata, "error", ""), "Stage '$name' did not create:") ||
        return nothing
    get(metadata, "execution_fingerprint", "") ==
    expected_execution_fingerprint || return nothing
    recorded_outputs = get(metadata, "outputs", Dict())
    issubset(Set(outputs), Set(keys(recorded_outputs))) || return nothing
    for output in outputs
        path = joinpath(stage_dir, output)
        isfile(path) || return nothing
        record = recorded_outputs[output]
        filesize(path) == record["bytes"] || return nothing
        md5sum(path) == record["md5"] || return nothing
    end
    return metadata
end

function stage_metadata(
    stage,
    stage_fingerprint,
    control,
    inputs,
    outputs,
    log,
    elapsed_seconds,
    status;
    error_message = nothing,
    execution_fingerprint = nothing,
)
    metadata = Dict(
        "schema_version" => 1,
        "name" => stage["name"],
        "status" => status,
        "fingerprint" => stage_fingerprint,
        "elapsed_seconds" => elapsed_seconds,
        "log" => basename(log),
        "control" => control,
        "inputs" => inputs,
        "outputs" => outputs,
    )
    isnothing(execution_fingerprint) ||
        (metadata["execution_fingerprint"] = execution_fingerprint)
    isnothing(error_message) || (metadata["error"] = error_message)
    return metadata
end

function executable_provenance(executable)
    record = Dict(
        "path" => abspath(executable),
        "bytes" => filesize(executable),
        "md5" => md5sum(executable),
    )
    cache_path = joinpath(dirname(executable), "cache_metadata.toml")
    if isfile(cache_path)
        cache = TOML.parsefile(cache_path)
        haskey(cache, "fingerprint") &&
            (record["build_fingerprint"] = cache["fingerprint"])
    end
    return record
end

function write_workflow_metadata(
    workflow,
    workflow_path,
    run_root,
    executable_record,
    results,
    status;
    error_message = nothing,
)
    metadata = Dict(
        "schema_version" => 1,
        "name" => workflow["name"],
        "status" => status,
        "source_commit" => workflow["source_commit"],
        "workflow" => abspath(workflow_path),
        "workflow_md5" => md5sum(workflow_path),
        "executable" => executable_record,
        "stages" => [
            Dict(
                "name" => result.name,
                "status" => string(result.status),
                "directory" => result.directory,
            ) for result in results
        ],
    )
    isnothing(error_message) || (metadata["error"] = error_message)
    return write_toml_atomic(
        joinpath(run_root, "workflow_metadata.toml"),
        metadata,
    )
end

function run_stage_workflow(
    executable,
    workflow_path,
    run_root;
    stage_hook = nothing,
)
    isfile(executable) || error("Missing workflow executable: $executable")
    workflow = TOML.parsefile(workflow_path)
    get(workflow, "schema_version", 0) == 1 ||
        error("Unsupported workflow schema version")
    stages = get(workflow, "stage", [])
    isempty(stages) && error("Workflow has no stages: $workflow_path")
    names = [stage["name"] for stage in stages]
    length(unique(names)) == length(names) ||
        error("Workflow stage names must be unique")
    all(name -> occursin(r"^[A-Za-z0-9_-]+$", name), names) || error(
        "Workflow stage names may contain only letters, digits, '_' and '-'",
    )

    spec_dir = dirname(abspath(workflow_path))
    stages_root = joinpath(run_root, "stages")
    mkpath(stages_root)
    stage_dirs = Dict{String, String}()
    results = NamedTuple[]
    executable_record = executable_provenance(executable)
    for (index, stage) in enumerate(stages)
        name = stage["name"]
        stage_dir = joinpath(stages_root, lpad(index, 2, '0') * "-" * name)
        mkpath(stage_dir)
        log = joinpath(stage_dir, "run.log")
        metadata_path = joinpath(stage_dir, "stage_metadata.toml")
        control = Dict{String, Any}()
        inputs = Dict{String, Any}[]
        outputs = String[]
        execution_fingerprint = nothing
        stage_fingerprint = fingerprint(
            Dict(
                "source_commit" => workflow["source_commit"],
                "stage" => stage,
            ),
        )
        started = time_ns()
        try
            outputs = validate_stage_paths(stage)
            control_source = resolve_spec_path(spec_dir, stage["control"])
            isfile(control_source) ||
                error("Missing stage control: $control_source")
            materialized_control =
                joinpath(stage_dir, "fcasacnp_clm_testbed.lst")
            cp(control_source, materialized_control; force = true)
            control = Dict(
                "source" => abspath(control_source),
                "source_md5" => md5sum(control_source),
                "materialized" => basename(materialized_control),
                "materialized_md5" => md5sum(materialized_control),
            )
            for input in get(stage, "input", [])
                push!(
                    inputs,
                    materialize_stage_input(
                        input,
                        spec_dir,
                        stage_dir,
                        stage_dirs,
                    ),
                )
            end
            execution_fingerprint = fingerprint(
                Dict(
                    "schema_version" => 1,
                    "source_commit" => workflow["source_commit"],
                    "executable" => executable_record,
                    "control" => control,
                    "inputs" => inputs,
                ),
            )
            stage_fingerprint = fingerprint(
                Dict(
                    "schema_version" => 1,
                    "source_commit" => workflow["source_commit"],
                    "executable" => executable_record,
                    "control" => control,
                    "inputs" => inputs,
                    "outputs" => outputs,
                ),
            )
            if reusable_stage(
                metadata_path,
                stage_fingerprint,
                stage_dir,
                outputs,
            )
                push!(
                    results,
                    (; name, status = :reused, directory = stage_dir),
                )
                stage_dirs[name] = stage_dir
                continue
            end
            recovery = recoverable_output_contract_stage(
                metadata_path,
                name,
                stage_dir,
                outputs,
                execution_fingerprint,
            )
            if !isnothing(recovery)
                records = Dict(
                    output => recovery["outputs"][output] for output in outputs
                )
                metadata = stage_metadata(
                    stage,
                    stage_fingerprint,
                    control,
                    inputs,
                    records,
                    log,
                    recovery["elapsed_seconds"],
                    "complete";
                    execution_fingerprint,
                )
                metadata["recovered_from_output_contract_error"] =
                    recovery["error"]
                write_toml_atomic(metadata_path, metadata)
                push!(
                    results,
                    (; name, status = :recovered, directory = stage_dir),
                )
                stage_dirs[name] = stage_dir
                continue
            end

            for output in outputs
                path = joinpath(stage_dir, output)
                ispath(path) && rm(path; force = true, recursive = true)
            end
            isnothing(stage_hook) ||
                stage_hook(stage, name, stage_dir, :before_run)
            try
                open(log, "w") do io
                    run(
                        pipeline(
                            Cmd(Cmd([executable]); dir = stage_dir);
                            stdout = io,
                            stderr = io,
                        ),
                    )
                end
            finally
                isnothing(stage_hook) ||
                    stage_hook(stage, name, stage_dir, :after_run)
            end
            missing =
                filter(output -> !isfile(joinpath(stage_dir, output)), outputs)
            isempty(missing) ||
                error("Stage '$name' did not create: $(join(missing, ", "))")
            elapsed_seconds = (time_ns() - started) / 1.0e9
            records = output_records(stage_dir, outputs)
            metadata = stage_metadata(
                stage,
                stage_fingerprint,
                control,
                inputs,
                records,
                log,
                elapsed_seconds,
                "complete";
                execution_fingerprint,
            )
            write_toml_atomic(metadata_path, metadata)
            push!(results, (; name, status = :ran, directory = stage_dir))
        catch error_value
            elapsed_seconds = (time_ns() - started) / 1.0e9
            error_message = sprint(showerror, error_value)
            open(log, "a") do io
                println(io, "workflow harness error: ", error_message)
            end
            records = Dict(
                output => Dict(
                    "bytes" => filesize(joinpath(stage_dir, output)),
                    "md5" => md5sum(joinpath(stage_dir, output)),
                ) for
                output in outputs if isfile(joinpath(stage_dir, output))
            )
            metadata = stage_metadata(
                stage,
                stage_fingerprint,
                control,
                inputs,
                records,
                log,
                elapsed_seconds,
                "failed";
                error_message,
                execution_fingerprint,
            )
            write_toml_atomic(metadata_path, metadata)
            push!(results, (; name, status = :failed, directory = stage_dir))
            write_workflow_metadata(
                workflow,
                workflow_path,
                run_root,
                executable_record,
                results,
                "failed";
                error_message,
            )
            rethrow()
        end
        stage_dirs[name] = stage_dir
    end

    write_workflow_metadata(
        workflow,
        workflow_path,
        run_root,
        executable_record,
        results,
        "complete",
    )
    return results
end

# ============================================================================
# Artifact verification
# ============================================================================

function verify_artifact(artifact, data_root; require_present)
    result = artifact_status(artifact, data_root)
    if result.status == :missing
        return merge(result, (; ok = !require_present))
    elseif !result.ok
        return result
    end
    actual_md5 = md5sum(result.path)
    expected_md5 = artifact["md5"]
    actual_md5 == expected_md5 || return (;
        ok = false,
        status = :checksum_mismatch,
        path = result.path,
        detail = "expected $expected_md5, found $actual_md5",
    )
    return (;
        ok = true,
        status = :verified,
        path = result.path,
        detail = actual_md5,
    )
end

function select_artifacts(manifest, ids)
    artifacts = manifest["artifact"]
    isempty(ids) && return artifacts
    by_id = Dict(artifact["id"] => artifact for artifact in artifacts)
    unknown = filter(id -> !haskey(by_id, id), ids)
    isempty(unknown) || error("Unknown artifact id(s): $(join(unknown, ", "))")
    return map(id -> by_id[id], ids)
end

function report_artifacts(manifest, data_root, ids; verify, require_present)
    all_ok = true
    for artifact in select_artifacts(manifest, ids)
        result = if verify
            verify_artifact(artifact, data_root; require_present)
        else
            status = artifact_status(artifact, data_root)
            status.status == :missing ? merge(status, (; ok = true)) : status
        end
        all_ok &= result.ok
        println(
            rpad(artifact["id"], 22),
            rpad(string(result.status), 20),
            result.detail,
        )
    end
    return all_ok
end

# ============================================================================
# Pinned Fortran builds
# ============================================================================

function require_tool(name)
    path = Sys.which(name)
    isnothing(path) && error("Required tool '$name' was not found on PATH")
    return path
end

function copy_fortran_sources(source_root, build_dir)
    source_dir = joinpath(source_root, "SOURCE_CODE")
    isdir(source_dir) ||
        error("Missing SOURCE_CODE directory under $source_root")
    files = filter(readdir(source_dir)) do filename
        filename == "Makefile.txt" || endswith(lowercase(filename), ".f90")
    end
    isempty(files) && error("No Fortran sources found in $source_dir")
    for filename in files
        cp(
            joinpath(source_dir, filename),
            joinpath(build_dir, filename);
            force = true,
        )
    end
    return build_dir
end

function apply_compat_patch(
    build_dir,
    patch_file = joinpath(HARNESS_DIR, "fortran_compat.patch"),
)
    patch_exe = require_tool("patch")
    isfile(patch_file) || error("Missing compatibility patch $patch_file")
    run(Cmd(Cmd([patch_exe, "-p0", "-i", patch_file]); dir = build_dir))
    return build_dir
end

function source_commit(source_root)
    git = require_tool("git")
    return readchomp(Cmd([git, "-C", source_root, "rev-parse", "HEAD"]))
end

function source_code_status(source_root)
    git = require_tool("git")
    return readchomp(
        Cmd([
            git,
            "-C",
            source_root,
            "status",
            "--porcelain",
            "--",
            "SOURCE_CODE",
        ]),
    )
end

tool_version(command) = first(split(readchomp(command), '\n'))

function write_build_metadata(
    build_dir,
    source_root,
    gfortran,
    nf_config,
    flags,
    patch_file,
)
    metadata = Dict(
        "source" => Dict(
            "root" => abspath(source_root),
            "commit" => source_commit(source_root),
            "source_code_status" => source_code_status(source_root),
        ),
        "build" => Dict(
            "compiler" => gfortran,
            "compiler_version" =>
                tool_version(Cmd([gfortran, "--version"])),
            "netcdf_config" => nf_config,
            "netcdf_fortran_version" =>
                readchomp(Cmd([nf_config, "--version"])),
            "netcdf_prefix" => readchomp(Cmd([nf_config, "--prefix"])),
            "netcdf_include" => readchomp(Cmd([nf_config, "--includedir"])),
            "flags" => flags,
            "compatibility_patch_md5" => md5sum(patch_file),
        ),
    )
    open(joinpath(build_dir, "build_metadata.toml"), "w") do io
        TOML.print(io, metadata; sorted = true)
    end
end

function build_fortran_at(source_root, build_dir; manifest = load_manifest())
    gfortran = require_tool(manifest["fortran"]["compiler"])
    nf_config = require_tool(manifest["fortran"]["netcdf_config"])
    make = require_tool("make")
    mkpath(build_dir)
    copy_fortran_sources(source_root, build_dir)
    patch_file =
        joinpath(HARNESS_DIR, manifest["fortran"]["compatibility_patch"])
    apply_compat_patch(build_dir, patch_file)

    netcdf_prefix = readchomp(Cmd([nf_config, "--prefix"]))
    netcdf_include = readchomp(Cmd([nf_config, "--includedir"]))
    flags = manifest["fortran"]["flags"]
    write_build_metadata(
        build_dir,
        source_root,
        gfortran,
        nf_config,
        flags,
        patch_file,
    )
    make_command = Cmd(
        Cmd([
            make,
            "-f",
            "Makefile.txt",
            "FC=$gfortran",
            "LIB_NETCDF=$(joinpath(netcdf_prefix, "lib"))",
            "INCS=$netcdf_include",
            "FFLAGS=$flags",
        ]);
        dir = build_dir,
    )

    println(
        "Building testbed commit $(source_commit(source_root)) in $build_dir",
    )
    build_log = joinpath(build_dir, "build.log")
    try
        open(build_log, "w") do io
            run(pipeline(make_command; stdout = io, stderr = io))
        end
    catch
        println(
            stderr,
            "Fortran build failed; compiler output is in $build_log",
        )
        rethrow()
    end
    executable = joinpath(build_dir, manifest["fortran"]["executable"])
    isfile(executable) || error("Build completed without producing $executable")
    println("Fortran executable: $executable")
    println("Build metadata: $(joinpath(build_dir, "build_metadata.toml"))")
    println("Compiler output: $build_log")
    return executable
end

function build_fortran(
    source_root,
    build_parent = tempdir();
    manifest = load_manifest(),
)
    build_dir = mktempdir(
        build_parent;
        prefix = "climaland_bgc_fortran_",
        cleanup = false,
    )
    return build_fortran_at(source_root, build_dir; manifest)
end

function fortran_build_inputs(source_root, manifest)
    gfortran = require_tool(manifest["fortran"]["compiler"])
    nf_config = require_tool(manifest["fortran"]["netcdf_config"])
    source_dir = joinpath(source_root, "SOURCE_CODE")
    source_files = sort(
        filter(readdir(source_dir)) do filename
            filename == "Makefile.txt" || endswith(lowercase(filename), ".f90")
        end,
    )
    patch_file =
        joinpath(HARNESS_DIR, manifest["fortran"]["compatibility_patch"])
    return Dict(
        "source_commit" => source_commit(source_root),
        "source_code_status" => source_code_status(source_root),
        "sources" => Dict(
            filename => md5sum(joinpath(source_dir, filename)) for
            filename in source_files
        ),
        "compiler" => abspath(gfortran),
        "compiler_version" => tool_version(Cmd([gfortran, "--version"])),
        "netcdf_config" => abspath(nf_config),
        "netcdf_fortran_version" => readchomp(Cmd([nf_config, "--version"])),
        "netcdf_prefix" => readchomp(Cmd([nf_config, "--prefix"])),
        "netcdf_include" => readchomp(Cmd([nf_config, "--includedir"])),
        "flags" => manifest["fortran"]["flags"],
        "compatibility_patch_md5" => md5sum(patch_file),
    )
end

function ensure_fortran_build(
    source_root,
    run_root;
    manifest = load_manifest(),
    expected_commit = manifest["source"]["local_checkout_commit"],
)
    actual_commit = source_commit(source_root)
    actual_commit == expected_commit || error(
        "Fortran source must be pinned to $expected_commit; found $actual_commit",
    )
    inputs = fortran_build_inputs(source_root, manifest)
    isempty(inputs["source_code_status"]) || error(
        "Pinned Fortran SOURCE_CODE checkout has local modifications:\n" *
        inputs["source_code_status"],
    )
    build_fingerprint = fingerprint(inputs)
    build_dir = joinpath(run_root, "build")
    cache_path = joinpath(build_dir, "cache_metadata.toml")
    executable = joinpath(build_dir, manifest["fortran"]["executable"])
    if isfile(cache_path) && isfile(executable)
        cache = try
            TOML.parsefile(cache_path)
        catch
            Dict()
        end
        if get(cache, "fingerprint", "") == build_fingerprint &&
           get(cache, "executable_md5", "") == md5sum(executable)
            println("Reusing pinned Fortran build: $executable")
            return executable
        end
    end

    isdir(build_dir) && rm(build_dir; recursive = true)
    mkpath(build_dir)
    executable = build_fortran_at(source_root, build_dir; manifest)
    write_toml_atomic(
        cache_path,
        Dict(
            "schema_version" => 1,
            "fingerprint" => build_fingerprint,
            "inputs" => inputs,
            "executable" => basename(executable),
            "executable_md5" => md5sum(executable),
        ),
    )
    return executable
end

# ============================================================================
# CASA prespin-to-history tracer
# ============================================================================

function stage_smoke_input(source_root, relative_path, run_dir, staged_name)
    source = joinpath(source_root, relative_path)
    isfile(source) || error("Missing smoke-test input $source")
    destination = joinpath(run_dir, staged_name)
    cp(source, destination; force = true)
    return destination
end

function write_smoke_control(
    run_dir;
    points = 4263,
    daily_output = 0,
    soil_model = 1,
    loops = 1,
    initialization = 0,
    years = (1901, 1901),
    cycle = 1,
    casa_parameters = "casa_parameters.csv",
    meteorology = "met.nc",
    casa_initial = "unused_casa_initial.csv",
    casa_final = "casa_final.csv",
    casa_flux_final = "casa_flux_final.csv",
    casa_netcdf = "casaclm_pool_flux_yyyy.nc",
    mimics_parameters = "unused_mimics_parameters.csv",
    mimics_initial = "unused_mimics_initial.csv",
    mimics_final = "unused_mimics_final.csv",
    mimics_netcdf = "unused_mimics_yyyy.nc",
)
    values = (
        string(points),
        "18",
        string(loops),
        string(daily_output),
        string(initialization),
        "$(first(years)) $(last(years))",
        string(soil_model),
        string(cycle),
        "grid.csv",
        casa_parameters,
        "phenology.txt",
        "soil.csv",
        meteorology,
        casa_initial,
        casa_final,
        casa_flux_final,
        casa_netcdf,
        mimics_parameters,
        mimics_initial,
        mimics_final,
        mimics_netcdf,
        "unused_corpse_initial.csv",
        "unused_corpse_final.csv",
        soil_model == 3 ? "corpse_parameters.nml" :
        "unused_corpse_parameters.nml",
        "corpse_pool_flux_yyyy.nc",
        "perturbation.txt",
        "-1",
        "./",
        "1",
    )
    path = joinpath(run_dir, "fcasacnp_clm_testbed.lst")
    write(path, join(values, '\n') * "\n")
    return path
end

workflow_input(source, destination; mode = "copy", transform = "none") = Dict(
    "source" => source,
    "destination" => destination,
    "mode" => mode,
    "transform" => transform,
)

function write_casa_tracer_workflow(source_root, fixture_dir, run_root)
    fixture_manifest = TOML.parsefile(joinpath(fixture_dir, "fixture.toml"))
    files = fixture_manifest["fixture"]
    configuration = joinpath(run_root, "configuration")
    controls = joinpath(configuration, "controls")
    mkpath(controls)
    write_smoke_control(
        controls;
        points = 1,
        initialization = 0,
        meteorology = "met_1901_1901.nc",
        casa_final = "casa_prespin.csv",
        casa_flux_final = "casa_prespin_flux.csv",
        casa_netcdf = "casaclm_prespin_yyyy.nc",
    )
    mv(
        joinpath(controls, "fcasacnp_clm_testbed.lst"),
        joinpath(controls, "prespin.lst");
        force = true,
    )
    write_smoke_control(
        controls;
        points = 1,
        initialization = 1,
        meteorology = "met_1901_1901.nc",
        casa_parameters = "casa_parameters_ad.csv",
        casa_initial = "casa_prespin.csv",
        casa_final = "casa_adspin.csv",
        casa_flux_final = "casa_adspin_flux.csv",
        casa_netcdf = "casaclm_adspin_yyyy.nc",
    )
    mv(
        joinpath(controls, "fcasacnp_clm_testbed.lst"),
        joinpath(controls, "adspin.lst");
        force = true,
    )
    write_smoke_control(
        controls;
        points = 1,
        daily_output = 1,
        initialization = 2,
        meteorology = "met_1901_1901.nc",
        casa_initial = "casa_history_initial.csv",
        casa_final = "casa_history.csv",
        casa_flux_final = "casa_history_flux.csv",
        casa_netcdf = "casaclm_history_yyyy.nc",
    )
    mv(
        joinpath(controls, "fcasacnp_clm_testbed.lst"),
        joinpath(controls, "historical.lst");
        force = true,
    )

    fixture_file(key) = abspath(joinpath(fixture_dir, files[key]["filename"]))
    source_file(relative) = abspath(joinpath(source_root, relative))
    common_inputs = [
        workflow_input(fixture_file("grid"), "grid.csv"),
        workflow_input(fixture_file("soil"), "soil.csv"),
        workflow_input(
            fixture_file("driver"),
            "met_1901_1901.nc";
            mode = "symlink",
        ),
        workflow_input(
            source_file("GRID_CN/modis_phenology_wtundra.txt"),
            "phenology.txt",
        ),
        workflow_input(
            source_file("GRID_CN/co2delta_control.txt"),
            "perturbation.txt",
        ),
    ]
    normal_parameters = workflow_input(
        source_file("GRID_CN/pftlookup_igbp_updated4_exud0.csv"),
        "casa_parameters.csv",
    )
    accelerated_parameters = workflow_input(
        source_file("GRID_CN/pftlookup_igbp_updated4_exud0AD.csv"),
        "casa_parameters_ad.csv",
    )
    stages = [
        Dict(
            "name" => "prespin",
            "control" => "controls/prespin.lst",
            "outputs" => [
                "casa_prespin.csv",
                "casa_prespin_flux.csv",
                "casaclm_prespin_0001.nc",
            ],
            "input" => [common_inputs..., normal_parameters],
        ),
        Dict(
            "name" => "adspin",
            "control" => "controls/adspin.lst",
            "outputs" => [
                "casa_adspin.csv",
                "casa_adspin_flux.csv",
                "casaclm_adspin_0001.nc",
            ],
            "input" => [
                common_inputs...,
                accelerated_parameters,
                workflow_input(
                    "stage:prespin/casa_prespin.csv",
                    "casa_prespin.csv",
                ),
            ],
        ),
        Dict(
            "name" => "historical",
            "control" => "controls/historical.lst",
            "outputs" => [
                "casa_history.csv",
                "casa_history_flux.csv",
                "casaclm_history_1901_daily.nc",
            ],
            "input" => [
                common_inputs...,
                normal_parameters,
                workflow_input(
                    "stage:adspin/casa_adspin.csv",
                    "casa_history_initial.csv";
                    transform = "casa_passive_carbon_x10",
                ),
            ],
        ),
    ]
    workflow = Dict(
        "schema_version" => 1,
        "name" => "casa-c-one-cell-prespin-to-history",
        "source_commit" => source_commit(source_root),
        "stage" => stages,
    )
    workflow_path = joinpath(configuration, "workflow.toml")
    write_toml_atomic(workflow_path, workflow)
    return workflow_path
end

function casa_workflow_tracer(source_root, fixture_dir, run_root)
    manifest = load_manifest()
    executable = ensure_fortran_build(source_root, run_root; manifest)
    workflow = write_casa_tracer_workflow(source_root, fixture_dir, run_root)
    results = run_stage_workflow(executable, workflow, run_root)
    println("CASA workflow tracer: $run_root")
    return results
end

# ============================================================================
# Smoke tests and reference fixtures
# ============================================================================

function run_smoke_fortran(
    source_root,
    meteorology,
    grid,
    soil,
    run_parent;
    points,
    daily_output,
    soil_model = 1,
    expected_alignment_warnings = 0,
)
    isfile(meteorology) || error("Missing meteorology file $meteorology")
    executable = build_fortran(source_root, run_parent)
    build_dir = dirname(executable)
    run_dir =
        mktempdir(run_parent; prefix = "climaland_bgc_smoke_", cleanup = false)

    cp(grid, joinpath(run_dir, "grid.csv"); force = true)
    stage_smoke_input(
        source_root,
        "GRID_CN/pftlookup_igbp_updated4_exud0.csv",
        run_dir,
        "casa_parameters.csv",
    )
    stage_smoke_input(
        source_root,
        "GRID_CN/modis_phenology_wtundra.txt",
        run_dir,
        "phenology.txt",
    )
    cp(soil, joinpath(run_dir, "soil.csv"); force = true)
    stage_smoke_input(
        source_root,
        "GRID_CN/co2delta_control.txt",
        run_dir,
        "perturbation.txt",
    )
    if soil_model == 3
        stage_smoke_input(
            source_root,
            "EXAMPLE_GRID/corpse_params_12.18d.2017.nml",
            run_dir,
            "corpse_parameters.nml",
        )
    end
    symlink(abspath(meteorology), joinpath(run_dir, "met.nc"))
    control_path =
        write_smoke_control(run_dir; points, daily_output, soil_model)

    run_log = joinpath(run_dir, "run.log")
    try
        open(run_log, "w") do io
            run(
                pipeline(
                    Cmd(Cmd([executable]); dir = run_dir);
                    stdout = io,
                    stderr = io,
                ),
            )
        end
    catch
        println(stderr, "Fortran smoke run failed; model output is in $run_log")
        rethrow()
    end

    run_text = read(run_log, String)
    alignment_warnings = count(
        line -> occursin("Data alignment problem in ReadMetNcFile", line),
        eachline(IOBuffer(run_text)),
    )
    alignment_warnings == expected_alignment_warnings || error(
        "Expected $expected_alignment_warnings data-alignment warnings, found " *
        "$alignment_warnings; see $run_log",
    )

    netcdf_output =
        daily_output == 1 ? "casaclm_pool_flux_0001_daily.nc" :
        "casaclm_pool_flux_0001.nc"
    casa_outputs = ("casa_final.csv", "casa_flux_final.csv", netcdf_output)
    corpse_outputs = if soil_model == 3
        corpse_netcdf =
            daily_output == 1 ? "corpse_pool_flux_0001_daily.nc" :
            "corpse_pool_flux_0001.nc"
        ("unused_corpse_final.csv", corpse_netcdf)
    else
        ()
    end
    expected_outputs = (casa_outputs..., corpse_outputs...)
    missing = filter(name -> !isfile(joinpath(run_dir, name)), expected_outputs)
    isempty(missing) ||
        error("Smoke run did not create: $(join(missing, ", "))")
    metadata = Dict(
        "source_commit" => source_commit(source_root),
        "build_metadata" => joinpath(build_dir, "build_metadata.toml"),
        "control_md5" => md5sum(control_path),
        "meteorology" => abspath(meteorology),
        "meteorology_md5" => md5sum(meteorology),
        "points" => points,
        "daily_output" => daily_output,
        "soil_model" => soil_model,
        "expected_alignment_warnings" => expected_alignment_warnings,
        "observed_alignment_warnings" => alignment_warnings,
        "outputs" => Dict(
            name => Dict(
                "bytes" => filesize(joinpath(run_dir, name)),
                "md5" => md5sum(joinpath(run_dir, name)),
            ) for name in expected_outputs
        ),
    )
    metadata_path = joinpath(run_dir, "run_metadata.toml")
    open(metadata_path, "w") do io
        TOML.print(io, metadata; sorted = true)
    end
    println("Fortran smoke output: $run_dir")
    println("Run metadata: $metadata_path")
    println("Model output: $run_log")
    return run_dir
end

function smoke_fortran(source_root, meteorology, run_parent = tempdir())
    return run_smoke_fortran(
        source_root,
        meteorology,
        joinpath(source_root, "GRID_CN/gridinfo_igbpz_CLM5_GSWP3.csv"),
        joinpath(source_root, "GRID_CN/gridinfo_soil_CLM5_GSWP3.csv"),
        run_parent;
        points = 4263,
        daily_output = 0,
    )
end

function smoke_fortran_fixture(source_root, fixture_dir, run_parent = tempdir())
    fixture_manifest = TOML.parsefile(joinpath(fixture_dir, "fixture.toml"))
    files = fixture_manifest["fixture"]
    comparison = fixture_manifest["comparison"]
    return run_smoke_fortran(
        source_root,
        joinpath(fixture_dir, files["driver"]["filename"]),
        joinpath(fixture_dir, files["grid"]["filename"]),
        joinpath(fixture_dir, files["soil"]["filename"]),
        run_parent;
        points = 1,
        daily_output = 1,
        # The reader compares the preserved global cell ID with the local 1×1
        # array index. This legacy full-grid assumption is harmless and exact.
        expected_alignment_warnings = comparison["expected_alignment_warnings"],
    )
end

function corpse_fortran_fixture(
    source_root,
    fixture_dir,
    run_parent = tempdir(),
)
    fixture_manifest = TOML.parsefile(joinpath(fixture_dir, "fixture.toml"))
    files = fixture_manifest["fixture"]
    comparison = fixture_manifest["comparison"]
    return run_smoke_fortran(
        source_root,
        joinpath(fixture_dir, files["driver"]["filename"]),
        joinpath(fixture_dir, files["grid"]["filename"]),
        joinpath(fixture_dir, files["soil"]["filename"]),
        run_parent;
        points = 1,
        daily_output = 1,
        soil_model = 3,
        expected_alignment_warnings = comparison["expected_alignment_warnings"],
    )
end

const CORPSE_ONE_DAY_EXPECTED = Float32[
    1.9918233156204224e-1,
    1.2999147176742554,
    5.0028387457132339e-2,
    1.0004136711359024e-2,
    1.9999323785305023e-1,
    3.0009185895323753e-2,
    2.0340774208307266e-2,
    4.0052723884582520e-1,
    2.2100000381469727,
    5.2722467808052897e-4,
]

function corpse_one_day(source_root, run_parent = tempdir())
    compiler = Sys.which("gfortran")
    isnothing(compiler) && error("gfortran is required for corpse-one-day")
    source = joinpath(source_root, "SOURCE_CODE", "corpse_soil_carbon.f90")
    parameters =
        joinpath(source_root, "EXAMPLE_GRID", "corpse_params_12.18d.2017.nml")
    driver = joinpath(HARNESS_DIR, "fortran", "corpse_one_day.f90")
    for path in (source, parameters, driver)
        isfile(path) || error("Missing CORPSE probe input: $path")
    end

    run_dir = mktempdir(run_parent; prefix = "corpse-one-day-", cleanup = false)
    executable = joinpath(run_dir, "corpse_one_day")
    build_log = joinpath(run_dir, "build.log")
    open(build_log, "w") do io
        run(
            pipeline(
                `$(compiler) -O0 -J$(run_dir) -o $(executable) \
                 $(source) $(driver)`,
                stdout = io,
                stderr = io,
            ),
        )
    end
    output = read(`$(executable) $(parameters)`, String)
    output_path = joinpath(run_dir, "corpse_one_day.out")
    write(output_path, output)
    values = Float32[]
    for line in eachline(IOBuffer(output))
        value = tryparse(Float32, strip(line))
        isnothing(value) || push!(values, value)
    end
    values == CORPSE_ONE_DAY_EXPECTED ||
        error("CORPSE one-day output differs from the pinned Float32 fixture")
    compiler_version = first(split(read(`$(compiler) --version`, String), '\n'))
    metadata = Dict(
        "compiler" => compiler_version,
        "flags" => ["-O0"],
        "source_md5" => md5sum(source),
        "parameter_md5" => md5sum(parameters),
        "driver_md5" => md5sum(driver),
        "output_md5" => md5sum(output_path),
        "float32_values" => values,
    )
    metadata_path = joinpath(run_dir, "metadata.toml")
    open(metadata_path, "w") do io
        TOML.print(io, metadata; sorted = true)
    end
    println("CORPSE one-day probe: $run_dir")
    return run_dir
end

# ============================================================================
# Self-tests
# ============================================================================

function self_test(source_root = "")
    manifest = load_manifest()
    provenance = TOML.parsefile(PROVENANCE_PATH)
    Test.@testset "reference harness" begin
        Test.@test manifest["schema_version"] == 1
        Test.@test length(manifest["artifact"]) == 8
        Test.@test Set(
            experiment["id"] for experiment in manifest["experiment"]
        ) == Set((
            "casa_c",
            "mimics_c",
            "casa_cn",
            "mimics_cn",
            "corpse_c",
        ))
        Test.@test provenance["schema_version"] == 1
        Test.@test length(provenance["attempt"]) >= 10
        mktempdir() do root
            write(joinpath(root, "abc"), "abc")
            artifact = Dict(
                "filename" => "abc",
                "bytes" => 3,
                "md5" => "900150983cd24fb0d6963f7d28e17f72",
            )
            Test.@test verify_artifact(
                artifact,
                root;
                require_present = true,
            ).status == :verified
            artifact["bytes"] = 4
            Test.@test verify_artifact(
                artifact,
                root;
                require_present = true,
            ).status == :size_mismatch
        end
        Test.@testset "CASA passive-carbon restoration" begin
            mktempdir() do root
                source = joinpath(root, "restart.csv")
                destination = joinpath(root, "restored.csv")
                header =
                    "iveg,casapool%csoil(MIC),casapool%csoil(SLOW)," *
                    "casapool%csoil(PASS),casapool%nsoil(PASS)\n"
                rows = [
                    "1,1.230000E+00,2.0,3.456000E-01,9.9\n",
                    "2,4.0,5.0,-0.012340,8.8,\n",
                ]
                write(source, header * join(rows))

                restore_casa_passive_carbon(source, destination)

                restored = readlines(destination; keep = true)
                Test.@test restored[1] == header
                Test.@test split(restored[2], ',') ==
                           ["1", "1.230000E+00", "2.0", "3.456000E+00", "9.9\n"]
                Test.@test split(restored[3], ',') ==
                           ["2", "4.0", "5.0", "-0.123400", "8.8", "\n"]

                full_header = split(
                    "iYrCnt,npt,veg%iveg,soil%isoilm,casamet%isorder," *
                    "casamet%lat,casamet%lon,casamet%areacell," *
                    "casamet%glai,casabiome%sla(veg%iveg),phen%phase," *
                    "casapool%clabile,casapool%cplant(LEAF)," *
                    "casapool%cplant(WOOD),casapool%cplant(FROOT)," *
                    "casapool%clitter(METB),casapool%clitter(STR)," *
                    "casapool%clitter(CWD),casapool%csoil(MIC)," *
                    "casapool%csoil(SLOW),casapool%csoil(PASS)," *
                    "casapool%nplant(LEAF),casapool%nplant(WOOD)," *
                    "casapool%nplant(FROOT),casapool%nlitter(METB)," *
                    "casapool%nlitter(STR),casapool%nlitter(CWD)," *
                    "casapool%nsoil(MIC),casapool%nsoil(SLOW)," *
                    "casapool%nsoil(PASS),casapool%nsoilmin," *
                    "casapool%pplant(LEAF),casapool%pplant(WOOD)," *
                    "casapool%pplant(FROOT),casapool%plitter(METB)," *
                    "casapool%plitter(STR),casapool%plitter(CWD)," *
                    "casapool%psoil(MIC),casapool%psoil(SLOW)," *
                    "casapool%psoil(PASS),casapool%psoillab," *
                    "casapool%psoilsorb,casapool%psoilocc," *
                    "casabal%sumcbal,casabal%sumnbal,casabal%sumpbal",
                    ',',
                )
                full_passive_column =
                    findfirst(==("casapool%csoil(PASS)"), full_header)
                Test.@test length(full_header) == 46
                for (cycle, passive_value) in (
                    ("C-only", "          1.234567E-01"),
                    ("CN", "          -0.012340"),
                )
                    columns = ["          $(index).000000" for index in 1:46]
                    columns[full_passive_column] = passive_value
                    cycle_source = joinpath(root, "$cycle-restart.csv")
                    cycle_destination = joinpath(root, "$cycle-restored.csv")
                    write(
                        cycle_source,
                        join(full_header, ',') *
                        "\n" *
                        join(columns, ',') *
                        ",\n",
                    )

                    restore_casa_passive_carbon(cycle_source, cycle_destination)

                    restored_columns = split(
                        readlines(cycle_destination; keep = true)[2],
                        ',';
                        keepempty = true,
                    )
                    for index in eachindex(columns)
                        index == full_passive_column && continue
                        Test.@test restored_columns[index] == columns[index]
                    end
                    Test.@test restored_columns[full_passive_column] ==
                               multiply_decimal_by_ten(passive_value)
                    Test.@test restored_columns[end] == "\n"
                end
            end
        end
        Test.@testset "resumable stage workflow" begin
            mktempdir() do root
                input_dir = joinpath(root, "inputs")
                mkpath(input_dir)
                write(joinpath(input_dir, "seed.txt"), "seed-one\n")
                write(joinpath(input_dir, "control.lst"), "control\n")
                executable = joinpath(root, "fake_model.sh")
                write(
                    executable,
                    "#!/bin/sh\n" *
                    "count=0\n" *
                    "test ! -f run_count || count=`cat run_count`\n" *
                    "count=\$((count + 1))\n" *
                    "printf '%s\\n' \"\$count\" > run_count\n" *
                    "cp input.txt output.txt\n",
                )
                chmod(executable, 0o755)
                write_toml_atomic(
                    joinpath(root, "cache_metadata.toml"),
                    Dict("fingerprint" => "build-one"),
                )
                workflow_path = joinpath(root, "workflow.toml")
                workflow = Dict(
                    "schema_version" => 1,
                    "name" => "resume-test",
                    "source_commit" => "test-commit",
                    "stage" => [
                        Dict(
                            "name" => "prespin",
                            "control" => "inputs/control.lst",
                            "outputs" => ["output.txt"],
                            "input" => [
                                Dict(
                                    "source" => "inputs/seed.txt",
                                    "destination" => "input.txt",
                                ),
                            ],
                        ),
                        Dict(
                            "name" => "spin",
                            "control" => "inputs/control.lst",
                            "outputs" => ["output.txt"],
                            "input" => [
                                Dict(
                                    "source" => "stage:prespin/output.txt",
                                    "destination" => "input.txt",
                                ),
                            ],
                        ),
                        Dict(
                            "name" => "historical",
                            "control" => "inputs/control.lst",
                            "outputs" => ["output.txt"],
                            "input" => [
                                Dict(
                                    "source" => "stage:spin/output.txt",
                                    "destination" => "input.txt",
                                ),
                            ],
                        ),
                    ],
                )
                open(workflow_path, "w") do io
                    TOML.print(io, workflow; sorted = true)
                end
                run_root = joinpath(root, "run")

                hook_events = Tuple{String, Symbol}[]
                first_run = run_stage_workflow(
                    executable,
                    workflow_path,
                    run_root;
                    stage_hook = (stage, name, directory, event) ->
                        push!(hook_events, (name, event)),
                )
                Test.@test getproperty.(first_run, :status) == fill(:ran, 3)
                Test.@test hook_events == [
                    ("prespin", :before_run),
                    ("prespin", :after_run),
                    ("spin", :before_run),
                    ("spin", :after_run),
                    ("historical", :before_run),
                    ("historical", :after_run),
                ]
                second_run =
                    run_stage_workflow(executable, workflow_path, run_root)
                Test.@test getproperty.(second_run, :status) == fill(:reused, 3)

                write_toml_atomic(
                    joinpath(root, "cache_metadata.toml"),
                    Dict("fingerprint" => "build-two"),
                )
                changed_build =
                    run_stage_workflow(executable, workflow_path, run_root)
                Test.@test getproperty.(changed_build, :status) == fill(:ran, 3)

                write(joinpath(input_dir, "seed.txt"), "seed-two\n")
                changed_input =
                    run_stage_workflow(executable, workflow_path, run_root)
                Test.@test getproperty.(changed_input, :status) == fill(:ran, 3)

                historical_dir = joinpath(run_root, "stages", "03-historical")
                write(joinpath(historical_dir, "output.txt"), "corrupt\n")
                repaired_output =
                    run_stage_workflow(executable, workflow_path, run_root)
                Test.@test getproperty.(repaired_output, :status) ==
                           [:reused, :reused, :ran]
                Test.@test readchomp(joinpath(historical_dir, "run_count")) ==
                           "4"
                metadata = TOML.parsefile(
                    joinpath(historical_dir, "stage_metadata.toml"),
                )
                Test.@test metadata["status"] == "complete"
                Test.@test metadata["elapsed_seconds"] >= 0
                Test.@test haskey(metadata, "control")
                Test.@test haskey(metadata, "inputs")
                Test.@test haskey(metadata, "outputs")
                Test.@test isfile(joinpath(historical_dir, metadata["log"]))

                failing_workflow = deepcopy(workflow)
                failing_workflow["name"] = "failure-test"
                failing_workflow["stage"] = [
                    Dict(
                        "name" => "failure",
                        "control" => "inputs/control.lst",
                        "outputs" => ["missing.txt"],
                        "input" => [
                            Dict(
                                "source" => "inputs/seed.txt",
                                "destination" => "input.txt",
                            ),
                        ],
                    ),
                ]
                write_toml_atomic(workflow_path, failing_workflow)
                failed_root = joinpath(root, "failed-run")
                Test.@test_throws ErrorException run_stage_workflow(
                    executable,
                    workflow_path,
                    failed_root,
                )
                failed_metadata = TOML.parsefile(
                    joinpath(
                        failed_root,
                        "stages",
                        "01-failure",
                        "stage_metadata.toml",
                    ),
                )
                Test.@test failed_metadata["status"] == "failed"
                Test.@test haskey(failed_metadata, "error")
                Test.@test TOML.parsefile(
                    joinpath(failed_root, "workflow_metadata.toml"),
                )["status"] == "failed"

                preparation_workflow = deepcopy(failing_workflow)
                preparation_workflow["name"] = "preparation-failure-test"
                preparation_workflow["stage"][1]["outputs"] = ["output.txt"]
                preparation_workflow["stage"][1]["input"][1]["source"] = "inputs/absent.txt"
                write_toml_atomic(workflow_path, preparation_workflow)
                preparation_root = joinpath(root, "preparation-failed-run")
                Test.@test_throws ErrorException run_stage_workflow(
                    executable,
                    workflow_path,
                    preparation_root,
                )
                preparation_dir =
                    joinpath(preparation_root, "stages", "01-failure")
                Test.@test TOML.parsefile(
                    joinpath(preparation_dir, "stage_metadata.toml"),
                )["status"] == "failed"
                Test.@test occursin(
                    "Missing workflow input",
                    read(joinpath(preparation_dir, "run.log"), String),
                )

                reserved_workflow = deepcopy(failing_workflow)
                reserved_workflow["name"] = "reserved-path-test"
                reserved_workflow["stage"][1]["input"][1]["destination"] = "fcasacnp_clm_testbed.lst"
                write_toml_atomic(workflow_path, reserved_workflow)
                reserved_root = joinpath(root, "reserved-failed-run")
                Test.@test_throws ErrorException run_stage_workflow(
                    executable,
                    workflow_path,
                    reserved_root,
                )
                Test.@test TOML.parsefile(
                    joinpath(
                        reserved_root,
                        "stages",
                        "01-failure",
                        "stage_metadata.toml",
                    ),
                )["status"] == "failed"
                Test.@test_throws ErrorException safe_relative_path(
                    ".",
                    "stage output",
                )
            end
        end
        if !isempty(source_root)
            example_control = joinpath(
                source_root,
                "GRID_CN",
                "MIMICS_mod5_GSWP3_KO4_push",
                "fcasacnp_clm_HIST_1901_2014_STEP_3of4.lst",
            )
            control = parse_control(example_control)
            Test.@test control[:points] == 4263
            Test.@test control[:years] == (1901, 2014)
            Test.@test control[:soil_model] == 2
            Test.@test :mimics_parameters in
                       first.(control_dependencies(control))
            mktempdir() do build_dir
                cp(
                    joinpath(source_root, "SOURCE_CODE", "corpse_variable.f90"),
                    joinpath(build_dir, "corpse_variable.f90"),
                )
                apply_compat_patch(build_dir)
                text = read(joinpath(build_dir, "corpse_variable.f90"), String)
                declaration = findfirst("real:: initial_C", text)
                namelist = findfirst("namelist /CORPSE_casa_nml/", text)
                Test.@test !isnothing(declaration)
                Test.@test !isnothing(namelist)
                Test.@test first(declaration) < first(namelist)
            end
        end
    end
    return true
end

# ============================================================================
# Command-line interface
# ============================================================================

function usage(io = stdout)
    println(io, "Usage:")
    println(
        io,
        "  julia reference_harness.jl status <data-root> [artifact-id ...]",
    )
    println(
        io,
        "  julia reference_harness.jl verify <data-root> [artifact-id ...]",
    )
    println(
        io,
        "  julia reference_harness.jl verify-all <data-root> [artifact-id ...]",
    )
    println(
        io,
        "  julia reference_harness.jl build-fortran <testbed-source-root> [build-parent]",
    )
    println(
        io,
        "  julia reference_harness.jl smoke-fortran <testbed-source-root> <1901-met.nc> [run-parent]",
    )
    println(
        io,
        "  julia reference_harness.jl smoke-fortran-fixture <testbed-source-root> <fixture-dir> [run-parent]",
    )
    println(
        io,
        "  julia reference_harness.jl corpse-one-day " *
        "<testbed-source-root> [run-parent]",
    )
    println(
        io,
        "  julia reference_harness.jl corpse-fortran-fixture " *
        "<testbed-source-root> <fixture-dir> [run-parent]",
    )
    println(
        io,
        "  julia reference_harness.jl run-workflow " *
        "<executable> <workflow.toml> <run-root>",
    )
    println(
        io,
        "  julia reference_harness.jl casa-workflow-tracer " *
        "<testbed-source-root> <fixture-dir> <run-root>",
    )
    println(io, "  julia reference_harness.jl audit-control <control-file>")
    println(io, "  julia reference_harness.jl self-test [testbed-source-root]")
end

function main(args)
    isempty(args) && (usage(stderr); return 2)
    command = first(args)
    try
        if command in ("status", "verify", "verify-all")
            length(args) >= 2 || error("$command requires a data root")
            manifest = load_manifest()
            data_root = args[2]
            ids = args[3:end]
            verify = command != "status"
            require_present = command == "verify-all" || !isempty(ids)
            ok = report_artifacts(
                manifest,
                data_root,
                ids;
                verify,
                require_present,
            )
            return ok ? 0 : 1
        elseif command == "build-fortran"
            length(args) >= 2 ||
                error("build-fortran requires a testbed source root")
            build_parent = length(args) >= 3 ? args[3] : tempdir()
            build_fortran(args[2], build_parent)
            return 0
        elseif command == "smoke-fortran"
            length(args) >= 3 ||
                error("smoke-fortran requires source root and 1901 meteorology")
            run_parent = length(args) >= 4 ? args[4] : tempdir()
            smoke_fortran(args[2], args[3], run_parent)
            return 0
        elseif command == "smoke-fortran-fixture"
            length(args) >= 3 || error(
                "smoke-fortran-fixture requires source root and fixture directory",
            )
            run_parent = length(args) >= 4 ? args[4] : tempdir()
            smoke_fortran_fixture(args[2], args[3], run_parent)
            return 0
        elseif command == "corpse-one-day"
            length(args) >= 2 ||
                error("corpse-one-day requires a testbed source root")
            run_parent = length(args) >= 3 ? args[3] : tempdir()
            corpse_one_day(args[2], run_parent)
            return 0
        elseif command == "corpse-fortran-fixture"
            length(args) >= 3 ||
                error("corpse-fortran-fixture requires source root and fixture")
            run_parent = length(args) >= 4 ? args[4] : tempdir()
            corpse_fortran_fixture(args[2], args[3], run_parent)
            return 0
        elseif command == "run-workflow"
            length(args) == 4 || error(
                "run-workflow requires an executable, workflow TOML, and run root",
            )
            run_stage_workflow(args[2], args[3], args[4])
            return 0
        elseif command == "casa-workflow-tracer"
            length(args) == 4 || error(
                "casa-workflow-tracer requires source root, fixture, and run root",
            )
            casa_workflow_tracer(args[2], args[3], args[4])
            return 0
        elseif command == "audit-control"
            length(args) == 2 ||
                error("audit-control requires one control file")
            return audit_control(args[2]) ? 0 : 1
        elseif command == "self-test"
            source_root = length(args) >= 2 ? args[2] : ""
            self_test(source_root)
            return 0
        else
            usage(stderr)
            return 2
        end
    catch error_value
        println(stderr, "error: ", sprint(showerror, error_value))
        return 1
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end

end
