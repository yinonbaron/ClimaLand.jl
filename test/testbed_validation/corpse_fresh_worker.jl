module TestbedCORPSEFreshWorker

import SHA
import TOML

export NonfiniteError,
    TrajectoryObserver,
    WorkerError,
    representative_scope,
    run_worker

const MODEL = "CORPSE"
const STAGES = ("prespin", "spin", "spin_continuation", "historical")
const STAGE_SYMBOLS = (:prespin, :spin, :spin_continuation, :historical)
const REVIEWED_GAPS = Dict(51 => 17, 3442 => 11)

struct WorkerError <: Exception
    message::String
end

Base.showerror(io::IO, error::WorkerError) = print(io, error.message)

struct NonfiniteError <: Exception
    records::Vector{Dict{String, Any}}
end

Base.showerror(io::IO, error::NonfiniteError) = print(
    io,
    "CORPSE trajectory became nonfinite for $(length(error.records)) cell(s)",
)

sha256sum(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

function write_toml(path, document)
    mkpath(dirname(path))
    temporary = path * ".tmp"
    open(temporary, "w") do io
        TOML.print(io, document; sorted = true)
    end
    mv(temporary, path; force = true)
    return path
end

function require_empty_directory(path)
    if isdir(path)
        isempty(readdir(path)) ||
            throw(WorkerError("fresh run directory is not empty: $path"))
    elseif ispath(path)
        throw(WorkerError("fresh run path is not a directory: $path"))
    else
        mkpath(path)
    end
    return path
end

function representative_scope(path)
    document = TOML.parsefile(path)
    get(document, "schema_version", nothing) == 1 ||
        throw(WorkerError("Representative scope schema is incompatible"))
    get(document, "name", nothing) == "representative" ||
        throw(WorkerError("CORPSE fresh worker requires Representative scope"))
    cell_ids = Int.(get(document, "cell_ids", Int[]))
    length(cell_ids) == 80 && length(unique(cell_ids)) == 80 ||
        throw(WorkerError("Representative scope must contain 80 unique cells"))
    gaps = Dict{Int, Int}()
    entries = get(document, "eligibility_gaps", Any[])
    for entry in entries
        get(entry, "model", nothing) == MODEL || continue
        get(entry, "reviewed", false) === true || throw(
            WorkerError("CORPSE scope contains an unreviewed eligibility gap"),
        )
        gaps[Int(entry["cell_id"])] = Int(entry["pft"])
    end
    gaps == REVIEWED_GAPS ||
        throw(WorkerError("CORPSE scope does not contain the reviewed gaps"))
    all(id in cell_ids for id in keys(gaps)) ||
        throw(WorkerError("CORPSE reviewed gaps are absent from the scope"))
    return (;
        cell_ids,
        eligible_cell_ids = filter(id -> !haskey(gaps, id), cell_ids),
        gaps,
        path = abspath(path),
        sha256 = sha256sum(path),
    )
end

"""
An ordered, fail-fast observer for one side of a CORPSE comparison.

The bridge must call it after every simulated step, in canonical stage order,
with every prognostic and diagnostic vector aligned to `cell_ids`. The first
call containing a nonfinite eligible value throws `NonfiniteError`, preserving
the exact stage, step, date, and lexicographically first variable.
"""
mutable struct TrajectoryObserver
    evidence_side::String
    cell_ids::Vector{Int}
    eligible::BitVector
    last_stage_rank::Int
    last_step::Int
end

function TrajectoryObserver(evidence_side, cell_ids, eligible_cell_ids)
    evidence_side in ("fortran", "julia") ||
        throw(ArgumentError("evidence_side must be fortran or julia"))
    eligible_set = Set(Int.(eligible_cell_ids))
    return TrajectoryObserver(
        String(evidence_side),
        Int.(cell_ids),
        BitVector(id in eligible_set for id in cell_ids),
        0,
        0,
    )
end

function (observer::TrajectoryObserver)(stage, step, date, values)
    stage_rank = stage isa Symbol ? findfirst(==(stage), STAGE_SYMBOLS) :
                 findfirst(==(stage), STAGES)
    isnothing(stage_rank) && throw(WorkerError("unknown CORPSE stage $stage"))
    step isa Integer && step > 0 ||
        throw(WorkerError("CORPSE trajectory step must be positive"))
    stage_rank >= observer.last_stage_rank ||
        throw(WorkerError("CORPSE trajectory observations are out of order"))
    stage_rank == observer.last_stage_rank && step <= observer.last_step &&
        throw(WorkerError("CORPSE trajectory steps are not strictly increasing"))
    observer.last_stage_rank = stage_rank
    observer.last_step = step
    isempty(values) && return nothing
    stage_name = stage isa Symbol ? STAGES[stage_rank] : String(stage)

    variables = sort!(String.(collect(keys(values))))
    records = Dict{String, Any}[]
    for position in eachindex(observer.cell_ids)
        observer.eligible[position] || continue
        first_variable = findfirst(variables) do variable
            vector = values[variable]
            vector isa AbstractVector &&
                length(vector) == length(observer.cell_ids) || throw(
                WorkerError(
                    "CORPSE trajectory has incompatible $variable values",
                ),
            )
            value = vector[position]
            value isa Real && !isfinite(value)
        end
        isnothing(first_variable) && continue
        variable = variables[first_variable]
        push!(
            records,
            Dict(
                "cell_id" => observer.cell_ids[position],
                "model" => MODEL,
                "reviewed" => false,
                "evidence_kind" => "nonfinite_trajectory",
                "evidence_side" => observer.evidence_side,
                "first_nonfinite_stage" => stage_name,
                "first_nonfinite_step" => Int(step),
                "first_nonfinite_date" => String(date),
                "first_nonfinite_variable" => variable,
                "reason" =>
                    "fresh $(observer.evidence_side) CORPSE trajectory became nonfinite",
            ),
        )
    end
    isempty(records) || throw(NonfiniteError(records))
    return nothing
end

function write_nonfinite_results(run_root, records)
    isempty(records) && throw(WorkerError("CORPSE nonfinite results are empty"))
    return write_toml(
        joinpath(run_root, "nonfinite_results.toml"),
        Dict(
            "schema_version" => 1,
            "model" => MODEL,
            "scope" => "representative",
            "nonfinite" => records,
            "eligibility_gap_proposal" => records,
        ),
    )
end

function tree_digest(path)
    isfile(path) && return sha256sum(path)
    isdir(path) || throw(WorkerError("immutable input is missing: $path"))
    context = SHA.SHA256_CTX()
    for (root, directories, files) in walkdir(path)
        sort!(directories)
        for file in sort!(files)
            absolute = joinpath(root, file)
            SHA.update!(context, codeunits(relpath(absolute, path)))
            SHA.update!(context, read(absolute))
        end
    end
    return bytes2hex(SHA.digest!(context))
end

function immutable_snapshot(paths)
    return Dict(abspath(path) => tree_digest(path) for path in paths)
end

function assert_unchanged(snapshot)
    for (path, digest) in snapshot
        tree_digest(path) == digest ||
            throw(WorkerError("fresh worker mutated immutable input: $path"))
    end
    return nothing
end

function result_field(result, name)
    hasproperty(result, name) ||
        throw(WorkerError("CORPSE bridge result lacks $(String(name))"))
    return getproperty(result, name)
end

function write_comparison(run_root, scientific_path, oracle_path)
    report = TOML.parsefile(scientific_path)
    get(report, "schema_version", nothing) == 1 ||
        throw(WorkerError("CORPSE comparison report schema is incompatible"))
    coverage = get(report, "coverage", Dict{String, Any}())
    get(coverage, "scope_cells", nothing) == 80 &&
        get(coverage, "eligible_cells", nothing) == 78 &&
        get(coverage, "compared_cells", nothing) == 78 || throw(
        WorkerError("CORPSE comparison report is not Representative-80"),
    )
    outcome = get(report, "outcome", nothing)
    outcome in ("passed", "failed") ||
        throw(WorkerError("CORPSE comparison report lacks a scientific outcome"))
    report["model"] = MODEL
    report["scope"] = "representative"
    report["reference"] = Dict(
        "path" => abspath(oracle_path),
        "sha256" => sha256sum(oracle_path),
        "kind" => "fresh_reduced_oracle",
    )
    path = write_toml(joinpath(run_root, "comparison.toml"), report)
    return (; path, passed = outcome == "passed")
end

"""
    run_worker(source_root, fixture_manifest, run_root, build_directory; ...)

Orchestrate one isolated Representative-80 CORPSE fresh comparison. Callers
provide thin bridges to the shared-build verifier, compact Fortran generator,
historical reducer, payload packer, and Julia executor. Both simulation bridges
must invoke their supplied `observer` after every step; this is the exact
nonfinite-evidence contract.
"""
function run_worker(
    source_root,
    fixture_manifest,
    run_root,
    build_directory;
    scope_manifest,
    calibration_manifest,
    executable_resolver,
    fortran_runner,
    reference_reducer,
    payload_builder,
    julia_runner,
)
    source_root = abspath(source_root)
    fixture_manifest = abspath(fixture_manifest)
    run_root = abspath(run_root)
    build_directory = abspath(build_directory)
    require_empty_directory(run_root)
    scope = representative_scope(scope_manifest)
    immutable = immutable_snapshot(
        (scope_manifest, calibration_manifest, fixture_manifest),
    )
    try
        executable = executable_resolver(build_directory)
        isfile(executable) ||
            throw(WorkerError("verified shared Fortran executable is missing"))
        fortran_root = joinpath(run_root, "fortran")
        oracle_root = joinpath(run_root, "oracle")
        payload_root = joinpath(run_root, "payload")
        julia_root = joinpath(run_root, "julia")
        foreach(mkpath, (fortran_root, oracle_root, payload_root, julia_root))

        fortran_observer = TrajectoryObserver(
            "fortran",
            scope.cell_ids,
            scope.eligible_cell_ids,
        )
        fortran = try
            fortran_runner(;
                executable,
                source_root,
                fixture_manifest,
                scope_manifest = scope.path,
                output_root = fortran_root,
                cell_ids = scope.cell_ids,
                observer = fortran_observer,
            )
        catch error
            error isa NonfiniteError || rethrow()
            evidence = write_nonfinite_results(run_root, error.records)
            return (; status = :nonfinite, evidence, side = :fortran)
        end
        result_field(fortran, :cell_ids) == scope.cell_ids ||
            throw(WorkerError("Fortran bridge did not run the exact 80 cells"))
        boundary_root = abspath(result_field(fortran, :boundary_root))
        historical_root = abspath(result_field(fortran, :historical_root))
        oracle_path = joinpath(oracle_root, "reduced_history.nc")
        reduced = reference_reducer(
            scope.path,
            historical_root,
            oracle_path,
        )
        result_field(reduced, :reference) == oracle_path ||
            throw(WorkerError("CORPSE reducer wrote outside the ephemeral oracle"))
        isfile(oracle_path) ||
            throw(WorkerError("CORPSE reducer did not create the fresh oracle"))
        bundle = payload_builder(boundary_root, oracle_path, payload_root)
        write_toml(
            joinpath(run_root, "fortran_output.toml"),
            Dict(
                "schema_version" => 1,
                "model" => MODEL,
                "scope" => "representative",
                "scope_cells" => 80,
                "eligible_cells" => 78,
                "shared_executable_sha256" => sha256sum(executable),
                "fresh_oracle" => abspath(oracle_path),
                "fresh_oracle_sha256" => sha256sum(oracle_path),
            ),
        )

        julia_observer = TrajectoryObserver(
            "julia",
            scope.cell_ids,
            scope.eligible_cell_ids,
        )
        julia = try
            julia_runner(;
                output_root = julia_root,
                bundle,
                boundary_root,
                fixture_manifest,
                scope_manifest = scope.path,
                calibration_manifest,
                cell_ids = scope.cell_ids,
                observer = julia_observer,
            )
        catch error
            error isa NonfiniteError || rethrow()
            evidence = write_nonfinite_results(run_root, error.records)
            return (; status = :nonfinite, evidence, side = :julia)
        end
        scientific_path = abspath(result_field(julia, :report))
        comparison = write_comparison(run_root, scientific_path, oracle_path)
        write_toml(
            joinpath(run_root, "julia_output.toml"),
            Dict(
                "schema_version" => 1,
                "model" => MODEL,
                "scope" => "representative",
                "scientific_report" => scientific_path,
                "scientific_report_sha256" => sha256sum(scientific_path),
            ),
        )
        return (;
            status = comparison.passed ? :passed : :failed,
            comparison = comparison.path,
            oracle = oracle_path,
        )
    finally
        assert_unchanged(immutable)
    end
end

end
