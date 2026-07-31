module TestbedCASACNShardedCalibration

import SHA
import TOML

const MANIFEST_NAME = "calibration_shards.toml"
const COMPLETION_NAME = "complete.toml"
const STAGES = ("prespin", "accelerated_spin", "normal_spin", "historical")
const SCRIPT_PATH = @__FILE__
const TIMEOUT_SECONDS = 2 * 60 * 60

if abspath(PROGRAM_FILE) == abspath(SCRIPT_PATH) &&
   !isempty(ARGS) &&
   first(ARGS) == "worker"
    include(joinpath(@__DIR__, "native_casa_cn_reconstruction.jl"))
end

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

"""
    shard_ranges(cell_count, shard_count)

Partition `cell_count` ordered cells into balanced contiguous ranges.
Called from [`run_shards`](@ref).
"""
function shard_ranges(cell_count, shard_count)
    cell_count > 0 || throw(ArgumentError("cell count must be positive"))
    0 < shard_count <= cell_count ||
        throw(ArgumentError("shard count must be between 1 and cell count"))
    width, remainder = divrem(cell_count, shard_count)
    first_index = 1
    return map(1:shard_count) do shard
        length = width + (shard <= remainder)
        range = first_index:(first_index + length - 1)
        first_index = last(range) + 1
        range
    end
end

"""
    combine_shards(load, shards, cell_count)

Load and combine complete shard arrays in global grid order.
Called from the full-grid calibration generator and [`load_shards`](@ref).
"""
function combine_shards(load::Function, shards, cell_count)
    covered = falses(cell_count)
    result = nothing
    for shard in shards
        range = (shard.first_grid_index):(shard.last_grid_index)
        all(index -> 1 <= index <= cell_count, range) ||
            error("calibration shard lies outside the full grid")
        any(covered[range]) && error("calibration shards overlap")
        values = load(shard)
        size(values, 1) == length(range) ||
            error("calibration shard output has the wrong point count")
        if isnothing(result)
            result = similar(values, (cell_count, size(values)[2:end]...))
        else
            size(values)[2:end] == size(result)[2:end] ||
                error("calibration shard output shapes differ")
        end
        destination =
            view(result, range, ntuple(_ -> Colon(), ndims(result) - 1)...)
        destination .= values
        covered[range] .= true
    end
    all(covered) || error("calibration shards do not cover the full grid")
    return result
end

"""
    file_record(path, root)

Record a calibration input path relative to `root` with its SHA-256 digest.
Called from [`execution_identity`](@ref).
"""
function file_record(path, root)
    isfile(path) || error("calibration input is missing: $path")
    return Dict("path" => relpath(path, root), "sha256" => sha256sum(path))
end

"""
    forcing_paths(forcing_root, reference_root)

Resolve the exact historical forcing files declared by the Fortran metadata.
Called from [`execution_identity`](@ref).
"""
function forcing_paths(forcing_root, reference_root)
    metadata = TOML.parsefile(
        joinpath(
            reference_root,
            "stages",
            "04-historical",
            "stage_metadata.toml",
        ),
    )
    names = sort!(
        String[
            record["destination"] for record in metadata["inputs"] if
            startswith(String(record["destination"]), "met_") &&
            endswith(String(record["destination"]), ".nc")
        ],
    )
    length(names) == 114 || error(
        "Fortran historical metadata must declare exactly 114 forcing files",
    )
    allunique(names) || error("Fortran historical forcing declarations repeat")
    return joinpath.(forcing_root, names)
end

"""
    execution_identity(source_root, forcing_root, reference_root)

Hash the model sources and every static or forcing input that affects a shard.
Called from [`run_shards`](@ref) before completed shards may be reused.
"""
function execution_identity(source_root, forcing_root, reference_root)
    repo_root = normpath(joinpath(@__DIR__, "..", ".."))
    project_path = Base.active_project()
    isnothing(project_path) && error("CASA-CN calibration requires a project")
    manifest_path = joinpath(dirname(project_path), "Manifest.toml")
    source_paths = (
        SCRIPT_PATH,
        joinpath(@__DIR__, "native_casa_c_reconstruction.jl"),
        joinpath(@__DIR__, "native_casa_cn_reconstruction.jl"),
        joinpath(@__DIR__, "native_workflow.jl"),
        joinpath(@__DIR__, "selected_casa_workflow.jl"),
        joinpath(repo_root, "src", "integrated", "casa_biogeochemistry.jl"),
        joinpath(
            repo_root,
            "src",
            "standalone",
            "Soil",
            "Biogeochemistry",
            "casa.jl",
        ),
        joinpath(repo_root, "src", "standalone", "Vegetation", "casa.jl"),
        project_path,
        manifest_path,
    )
    input_paths = (
        joinpath(source_root, "GRID_CN", "gridinfo_igbpz_CLM5_GSWP3.csv"),
        joinpath(source_root, "GRID_CN", "gridinfo_soil_CLM5_GSWP3.csv"),
        joinpath(source_root, "GRID_CN", "modis_phenology_wtundra.txt"),
        joinpath(source_root, "GRID_CN", "pftlookup_igbp_updated4_exud0.csv"),
        joinpath(source_root, "GRID_CN", "pftlookup_igbp_updated4_exud0AD.csv"),
        joinpath(
            reference_root,
            "candidates",
            "parameters",
            "pftlookup_igbp_updated4_borealNfix.candidate.csv",
        ),
        (
            joinpath(reference_root, "stages", stage, "stage_metadata.toml") for stage in (
                "01-prespin",
                "02-accelerated_spin",
                "03-normal_spin",
                "04-historical",
            )
        )...,
    )
    records = Dict(
        "source" => [file_record(path, repo_root) for path in source_paths],
        "input" => [file_record(path, source_root) for path in input_paths],
        "forcing" => [
            file_record(path, forcing_root) for
            path in forcing_paths(forcing_root, reference_root)
        ],
        "source_root" => abspath(source_root),
        "forcing_root" => abspath(forcing_root),
        "reference_root" => abspath(reference_root),
        "julia_version" => string(VERSION),
        "kernel" => string(Sys.KERNEL),
        "architecture" => string(Sys.ARCH),
    )
    payload = sprint(io -> TOML.print(io, records; sorted = true))
    records["sha256"] = bytes2hex(SHA.sha256(payload))
    return records
end

"""
    manifest_document(ranges, identity, execution_revision)

Build the immutable description of one complete sharded calibration attempt.
Called from [`write_manifest`](@ref).
"""
function manifest_document(ranges, identity, execution_revision)
    return Dict(
        "schema_version" => 1,
        "model" => "CASA-CN",
        "cell_count" => sum(length, ranges),
        "shard_count" => length(ranges),
        "execution_revision" => execution_revision,
        "execution_identity" => identity,
        "shard" => [
            Dict(
                "index" => index,
                "first_grid_index" => first(range),
                "last_grid_index" => last(range),
                "output" => "shard-$(lpad(index, 3, '0'))",
            ) for (index, range) in enumerate(ranges)
        ],
    )
end

"""
    write_manifest(output_root, ranges, identity, execution_revision)

Write a new shard manifest or verify that an existing manifest is identical.
Called from [`run_shards`](@ref).
"""
function write_manifest(output_root, ranges, identity, execution_revision)
    mkpath(output_root)
    path = joinpath(output_root, MANIFEST_NAME)
    expected = manifest_document(ranges, identity, execution_revision)
    if isfile(path)
        TOML.parsefile(path) == expected ||
            error("existing calibration shard manifest is incompatible")
        return path
    end
    open(path, "w") do io
        TOML.print(io, expected; sorted = true)
    end
    return path
end

"""
    completion_valid(output_root, shard, identity_sha256)

Return whether a shard is complete, compatible, and content-hash intact.
Called from [`load_shards`](@ref) and [`run_shards`](@ref).
"""
function completion_valid(output_root, shard, identity_sha256)
    root = joinpath(output_root, shard.output)
    path = joinpath(root, COMPLETION_NAME)
    isfile(path) || return false
    document = TOML.parsefile(path)
    get(document, "execution_identity_sha256", nothing) == identity_sha256 ||
        return false
    get(document, "first_grid_index", nothing) == shard.first_grid_index ||
        return false
    get(document, "last_grid_index", nothing) == shard.last_grid_index ||
        return false
    outputs = get(document, "output", Any[])
    isempty(outputs) && return false
    return all(outputs) do output
        candidate = joinpath(root, output["path"])
        isfile(candidate) && sha256sum(candidate) == output["sha256"]
    end
end

"""
    load_shards(output_root; require_complete = true)

Load and validate the ordered shard records declared by `output_root`.
"""
function load_shards(output_root; require_complete = true)
    path = joinpath(output_root, MANIFEST_NAME)
    isfile(path) || error("calibration shard manifest is missing: $path")
    document = TOML.parsefile(path)
    get(document, "schema_version", nothing) == 1 ||
        error("unsupported calibration shard manifest")
    get(document, "model", nothing) == "CASA-CN" ||
        error("calibration shard manifest is not CASA-CN")
    cell_count = Int(document["cell_count"])
    identity_sha256 = document["execution_identity"]["sha256"]
    shards = map(document["shard"]) do shard
        (
            index = Int(shard["index"]),
            first_grid_index = Int(shard["first_grid_index"]),
            last_grid_index = Int(shard["last_grid_index"]),
            output = String(shard["output"]),
            output_root = joinpath(output_root, String(shard["output"])),
        )
    end
    combine_shards(shards, cell_count) do shard
        ones(length((shard.first_grid_index):(shard.last_grid_index)))
    end
    if require_complete
        incomplete = [
            shard.index for shard in shards if
            !completion_valid(output_root, shard, identity_sha256)
        ]
        isempty(incomplete) ||
            error("incomplete calibration shards: $(join(incomplete, ", "))")
    end
    return shards
end

"""
    quarantine_invalid_shards(shards)

Move existing invalid shard directories aside so replacements can publish.
Called from [`run_shards`](@ref).
"""
function quarantine_invalid_shards(shards)
    return filter(
        !isnothing,
        map(shards) do shard
            ispath(shard.output_root) || return nothing
            quarantine = "$(shard.output_root).invalid-$(time_ns())"
            mv(shard.output_root, quarantine)
            quarantine
        end,
    )
end

"""
    output_records(root)

Hash the reduced history and every stage manifest and checkpoint in a shard.
Called from [`run_worker`](@ref).
"""
function output_records(root)
    paths = String[joinpath(root, "reduced_historical.nc")]
    for stage in STAGES
        workflow = joinpath(root, "stages", stage, "workflow.toml")
        isfile(workflow) || error("calibration shard workflow is missing")
        document = TOML.parsefile(workflow)
        entries = document["stage"]
        length(entries) == 1 || error("calibration shard stage is ambiguous")
        checkpoint = joinpath(dirname(workflow), entries[1]["checkpoint"])
        append!(paths, (workflow, checkpoint))
    end
    return [
        Dict("path" => relpath(path, root), "sha256" => sha256sum(path)) for
        path in paths
    ]
end

"""
    run_until(command, deadline; command_stdout = stdout, command_stderr = stderr)

Run `command` until the absolute wall-clock `deadline`, killing it on timeout.
Return its exit code and whether the deadline expired. Called from
[`run_shards`](@ref).
"""
function run_until(
    command,
    deadline;
    command_stdout = stdout,
    command_stderr = stderr,
)
    remaining = deadline - time()
    remaining > 0 || return (; exitcode = 124, timed_out = true)
    process = run(
        pipeline(
            ignorestatus(command);
            stdout = command_stdout,
            stderr = command_stderr,
        );
        wait = false,
    )
    status = timedwait(
        () -> process_exited(process),
        remaining;
        pollint = min(0.1, remaining / 10),
    )
    if status == :timed_out
        process_exited(process) || kill(process)
        wait(process)
        return (; exitcode = 124, timed_out = true)
    end
    wait(process)
    return (; exitcode = process.exitcode, timed_out = false)
end

"""
    run_worker(args)

Run one isolated contiguous CASA-CN grid shard and publish it atomically.
Called by the `worker` command-line mode created by [`run_shards`](@ref).
"""
function run_worker(args)
    length(args) == 8 || error(
        "usage: casa_cn_sharded_calibration.jl worker SOURCE_ROOT FORCING_ROOT REFERENCE_ROOT OUTPUT_ROOT FIRST LAST IDENTITY_SHA256 FINAL_ROOT",
    )
    source_root, forcing_root, reference_root, output_root = args[1:4]
    first_grid_index = parse(Int, args[5])
    last_grid_index = parse(Int, args[6])
    identity_sha256 = args[7]
    final_root = args[8]
    ispath(final_root) && error("incomplete calibration shard already exists")
    mkpath(output_root)
    attempt_root = mktempdir(output_root; prefix = "attempt-")
    TestbedNativeCASACNReconstruction.run_gridded_case(
        source_root,
        forcing_root,
        reference_root,
        attempt_root;
        boundary_only = true,
        grid_indices = first_grid_index:last_grid_index,
    )
    completion = Dict(
        "schema_version" => 1,
        "execution_identity_sha256" => identity_sha256,
        "first_grid_index" => first_grid_index,
        "last_grid_index" => last_grid_index,
        "output" => output_records(attempt_root),
    )
    open(joinpath(attempt_root, COMPLETION_NAME), "w") do io
        TOML.print(io, completion; sorted = true)
    end
    mv(attempt_root, final_root)
    return nothing
end

"""
    run_shards(args; timeout_seconds = TIMEOUT_SECONDS)

Run, resume, and aggregate the global CASA-CN calibration within a hard limit.
"""
function run_shards(args; timeout_seconds = TIMEOUT_SECONDS)
    5 <= length(args) <= 8 || error(
        "usage: casa_cn_sharded_calibration.jl run SOURCE_ROOT FORCING_ROOT REFERENCE_ROOT OUTPUT_ROOT OUTPUT_TOML [SHARDS] [WORKERS] [EXECUTION_REVISION]",
    )
    source_root, forcing_root, reference_root, output_root, output_toml =
        args[1:5]
    shard_count = length(args) >= 6 ? parse(Int, args[6]) : 6
    workers = length(args) >= 7 ? parse(Int, args[7]) : shard_count
    execution_revision = length(args) == 8 ? args[8] : "HEAD"
    workers > 0 || throw(ArgumentError("workers must be positive"))
    timeout_seconds > 0 || throw(ArgumentError("timeout must be positive"))
    deadline = time() + timeout_seconds
    ranges = shard_ranges(4_263, shard_count)
    identity = execution_identity(source_root, forcing_root, reference_root)
    manifest = write_manifest(output_root, ranges, identity, execution_revision)
    shards = load_shards(output_root; require_complete = false)
    pending = [
        shard for shard in shards if
        !completion_valid(output_root, shard, identity["sha256"])
    ]
    quarantine_invalid_shards(pending)
    project = dirname(Base.active_project())
    results = if isempty(pending)
        Tuple{Int, Int, Bool}[]
    else
        asyncmap(pending; ntasks = min(workers, length(pending))) do shard
            log_path = joinpath(
                output_root,
                "shard-$(lpad(shard.index, 3, '0')).log",
            )
            command = addenv(
                `$(Base.julia_cmd()) --startup-file=no --project=$project $SCRIPT_PATH worker $source_root $forcing_root $reference_root $output_root $(shard.first_grid_index) $(shard.last_grid_index) $(identity["sha256"]) $(shard.output_root)`,
                "JULIA_NUM_THREADS" => "1",
                "OPENBLAS_NUM_THREADS" => "1",
            )
            result = open(log_path, "w") do io
                run_until(
                    command,
                    deadline;
                    command_stdout = io,
                    command_stderr = io,
                )
            end
            return (shard.index, result.exitcode, result.timed_out)
        end
    end
    timed_out = [index for (index, _, expired) in results if expired]
    isempty(timed_out) || error(
        "calibration exceeded the $(timeout_seconds)-second hard timeout; timed-out shards: $(join(timed_out, ", "))",
    )
    failed = [index for (index, code, _) in results if code != 0]
    isempty(failed) || error("calibration shards failed: $(join(failed, ", "))")
    load_shards(output_root)
    generator = joinpath(@__DIR__, "generate_casa_cn_full_grid_calibration.jl")
    command = `$(Base.julia_cmd()) --startup-file=no --project=$project $generator $output_root $reference_root $output_toml $execution_revision`
    aggregation = run_until(command, deadline)
    aggregation.timed_out && error(
        "calibration aggregation exceeded the $(timeout_seconds)-second hard timeout",
    )
    aggregation.exitcode == 0 || error("CASA-CN calibration aggregation failed")
    println("Shard manifest: $manifest")
    println("Calibration: $output_toml")
    return nothing
end

"""
    main(args = ARGS)

Dispatch the `run` and `worker` command-line modes.
"""
function main(args = ARGS)
    isempty(args) && error("expected run or worker")
    first(args) == "worker" && return run_worker(args[2:end])
    first(args) == "run" && return run_shards(args[2:end])
    error("expected run or worker")
end

end

if abspath(PROGRAM_FILE) == abspath(TestbedCASACNShardedCalibration.SCRIPT_PATH)
    TestbedCASACNShardedCalibration.main()
end
