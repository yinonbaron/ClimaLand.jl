if !isdefined(@__MODULE__, :TestbedModelProcessOrchestration)
    include(joinpath(@__DIR__, "model_process_orchestration.jl"))
end

module TestbedFreshReferenceOrchestration

import TOML

const ModelProcesses =
    getfield(parentmodule(@__MODULE__), :TestbedModelProcessOrchestration)
const PINNED_FORTRAN_SOURCE_COMMIT = "27ae1a0b673411642cd780ecad66d1c8f84e6a58"
const CANONICAL_TOOLCHAIN_IDENTITY = "climaland-biogeochem-reference-linux-gfortran-v1"
const EXPECTED_COVERAGE = Dict(
    model =>
        (scope_cells = 80, eligible_cells = model == "CORPSE" ? 78 : 80) for
    model in ModelProcesses.MODELS
)

valid_sha256(value) =
    value isa AbstractString && occursin(r"^[0-9a-f]{64}$", value)

function require_count(coverage, key, expected, model)
    value = get(coverage, key, nothing)
    value isa Integer && !(value isa Bool) && value == expected ||
        error("$model comparison has invalid $key coverage")
    return value
end

function validated_comparison(
    model,
    path;
    expected_executable_sha256 = nothing,
    expected_scope_manifest_sha256 = nothing,
    fortran_path = nothing,
)
    isfile(path) || error("$model comparison report is missing")
    report = try
        TOML.parsefile(path)
    catch error
        message = sprint(showerror, error)
        throw(ErrorException("$model comparison report is malformed: $message"))
    end
    schema_version = get(report, "schema_version", nothing)
    schema_version isa Integer &&
        !(schema_version isa Bool) &&
        schema_version == 1 ||
        error("$model comparison report schema is incompatible")
    get(report, "model", nothing) == model ||
        error("$model comparison report identifies the wrong model")
    get(report, "scope", nothing) == "representative" ||
        error("$model comparison report is not Representative")
    get(report, "outcome", nothing) == "passed" ||
        error("$model comparison did not pass")
    coverage = get(report, "coverage", nothing)
    coverage isa AbstractDict || error("$model comparison lacks coverage")
    expected = EXPECTED_COVERAGE[model]
    require_count(coverage, "scope_cells", expected.scope_cells, model)
    require_count(coverage, "eligible_cells", expected.eligible_cells, model)
    require_count(coverage, "compared_cells", expected.eligible_cells, model)
    selected_fortran_path =
        isnothing(fortran_path) ?
        joinpath(dirname(path), "fortran_output.toml") : fortran_path
    isfile(selected_fortran_path) || error("$model Fortran evidence is missing")
    fortran = TOML.parsefile(selected_fortran_path)
    get(fortran, "model", nothing) == model ||
        error("$model Fortran evidence identifies the wrong model")
    for key in ("shared_executable_sha256", "scope_manifest_sha256")
        value = get(report, key, nothing)
        valid_sha256(value) || error("$model comparison lacks $key")
        value == get(fortran, key, nothing) ||
            error("$model comparison differs from its Fortran $key")
    end
    isnothing(expected_executable_sha256) ||
        report["shared_executable_sha256"] == expected_executable_sha256 ||
        error("$model comparison differs from the shared Fortran build")
    isnothing(expected_scope_manifest_sha256) ||
        report["scope_manifest_sha256"] == expected_scope_manifest_sha256 ||
        error("$model comparison differs from the exact Scope Manifest")
    return report
end

function run_build(build_command, build_directory, worker_stdout, worker_stderr)
    started_ns = time_ns()
    try
        process = run(
            pipeline(
                ignorestatus(
                    Cmd(build_command(build_directory); dir = build_directory),
                );
                stdout = worker_stdout,
                stderr = worker_stderr,
            ),
        )
        return (;
            outcome = success(process) ? "passed" : "failed",
            exitcode = process.exitcode,
            signal = process.termsignal,
            seconds = (time_ns() - started_ns) / 1e9,
            error = nothing,
        )
    catch error
        return (;
            outcome = "crashed",
            exitcode = nothing,
            signal = nothing,
            seconds = (time_ns() - started_ns) / 1e9,
            error = sprint(showerror, error),
        )
    end
end

function write_proposals(model, run_directory)
    source_path = joinpath(run_directory, "nonfinite_results.toml")
    isfile(source_path) || return nothing
    source = TOML.parsefile(source_path)
    get(source, "schema_version", nothing) == 1 ||
        error("$model nonfinite results have an incompatible schema")
    records = get(source, "nonfinite", Any[])
    isempty(records) && error("$model nonfinite results are empty")
    proposals = map(records) do record
        get(record, "cell_id", 0) isa Integer && record["cell_id"] > 0 ||
            error("$model nonfinite result has an invalid cell")
        get(record, "evidence_side", nothing) in ("fortran", "julia") ||
            error("$model nonfinite result has an invalid evidence side")
        for key in (
            "reason",
            "first_nonfinite_date",
            "first_nonfinite_stage",
            "first_nonfinite_variable",
        )
            value = get(record, key, nothing)
            value isa AbstractString && !isempty(strip(value)) ||
                error("$model nonfinite result lacks $key")
        end
        occursin(r"^\d{4}-\d{2}-\d{2}$", record["first_nonfinite_date"]) ||
            error("$model nonfinite result has an invalid date")
        return merge(
            Dict{String, Any}(record),
            Dict("model" => model, "reviewed" => false),
        )
    end
    destination = joinpath(run_directory, "eligibility_gap_proposals.toml")
    temporary = "$destination.tmp"
    open(temporary, "w") do io
        TOML.print(
            io,
            Dict(
                "schema_version" => 1,
                "model" => model,
                "source" => "fresh_reference_nonfinite_result",
                "proposal" => proposals,
            );
            sorted = true,
        )
    end
    mv(temporary, destination; force = true)
    return destination
end

function run_fresh_reference(
    reference_mode,
    build_command,
    worker_command;
    models = collect(ModelProcesses.MODELS),
    workers = ModelProcesses.default_worker_count(),
    temporary_parent = nothing,
    retain_success = false,
    scope_manifest_sha256 = nothing,
    preflight = _ -> nothing,
    worker_stdout = stdout,
    worker_stderr = stderr,
)
    reference_mode == "fresh" || throw(
        ArgumentError(
            "fresh-reference orchestration requires explicit fresh mode",
        ),
    )
    retention_mode = retain_success ? "maintainer" : "ephemeral"
    selected = ModelProcesses.select_models(models)
    preflight(selected)
    run_root =
        isnothing(temporary_parent) ?
        mktempdir(; prefix = "fresh-reference-", cleanup = false) :
        mktempdir(
            temporary_parent;
            prefix = "fresh-reference-",
            cleanup = false,
        )
    build_directory = joinpath(run_root, "build")
    mkpath(build_directory)
    build =
        run_build(build_command, build_directory, worker_stdout, worker_stderr)
    metadata_path = joinpath(build_directory, "build_metadata.toml")
    metadata =
        build.outcome == "passed" && isfile(metadata_path) ?
        try
            TOML.parsefile(metadata_path)
        catch
            nothing
        end : nothing
    executable_sha256 =
        metadata isa AbstractDict ?
        get(
            get(metadata, "verification", Dict{String, Any}()),
            "executable_sha256",
            nothing,
        ) : nothing
    verified =
        metadata isa AbstractDict &&
        get(metadata, "verified", false) === true &&
        valid_sha256(executable_sha256)
    if build.outcome == "passed" && !verified
        build = merge(
            build,
            (;
                outcome = "failed",
                error = "shared Fortran build verification failed",
            ),
        )
    end
    build.outcome == "passed" || return (;
        outcome = "failed",
        exitcode = 1,
        build,
        outcomes = Any[],
        comparisons = Dict{String, Any}(),
        run_root,
        preserved = true,
        retention_mode,
        proposal_paths = Dict{String, String}(),
    )
    model_directories =
        Dict(model => joinpath(run_root, "model-$model") for model in selected)
    foreach(mkpath, values(model_directories))
    workers_result = ModelProcesses.run_model_workers(
        model -> Cmd(
            worker_command(model, model_directories[model], build_directory);
            dir = model_directories[model],
        );
        models = selected,
        workers,
        worker_stdout,
        worker_stderr,
    )
    proposal_paths = Dict{String, String}()
    for model in selected
        path = write_proposals(model, model_directories[model])
        isnothing(path) || (proposal_paths[model] = path)
    end
    process_outcomes =
        Dict(outcome.model => outcome for outcome in workers_result.outcomes)
    comparisons = Dict{String, Any}()
    comparison_errors = Dict{String, String}()
    for model in selected
        haskey(proposal_paths, model) && continue
        process_outcomes[model].outcome == "passed" || continue
        comparison_path = joinpath(model_directories[model], "comparison.toml")
        try
            comparisons[model] = validated_comparison(
                model,
                comparison_path;
                expected_executable_sha256 = executable_sha256,
                expected_scope_manifest_sha256 = scope_manifest_sha256,
            )
        catch error
            comparison_errors[model] = sprint(showerror, error)
        end
    end
    outcomes = map(workers_result.outcomes) do outcome
        haskey(proposal_paths, outcome.model) ?
        merge(
            outcome,
            (;
                outcome = "nonfinite",
                error = "fresh trajectory produced an Eligibility Gap proposal",
            ),
        ) :
        haskey(comparison_errors, outcome.model) ?
        merge(
            outcome,
            (; outcome = "failed", error = comparison_errors[outcome.model]),
        ) : outcome
    end
    passed =
        workers_result.exitcode == 0 &&
        isempty(proposal_paths) &&
        isempty(comparison_errors)
    preserved = !passed || retain_success
    preserved || rm(run_root; recursive = true)
    return (;
        outcome = passed ? "passed" : "failed",
        exitcode = passed ? 0 : 1,
        build,
        outcomes,
        comparisons,
        run_root,
        preserved,
        retention_mode,
        proposal_paths,
    )
end

end
