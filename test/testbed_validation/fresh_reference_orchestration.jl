if !isdefined(@__MODULE__, :TestbedModelProcessOrchestration)
    include(joinpath(@__DIR__, "model_process_orchestration.jl"))
end

module TestbedFreshReferenceOrchestration

import TOML

const ModelProcesses =
    getfield(parentmodule(@__MODULE__), :TestbedModelProcessOrchestration)

function run_build(build_command, build_directory, worker_stdout, worker_stderr)
    started_ns = time_ns()
    try
        process = run(
            pipeline(
                ignorestatus(
                    Cmd(
                        build_command(build_directory);
                        dir = build_directory,
                    ),
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
        get(record, "cell_id", 0) isa Integer &&
            record["cell_id"] > 0 ||
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
        occursin(
            r"^\d{4}-\d{2}-\d{2}$",
            record["first_nonfinite_date"],
        ) || error("$model nonfinite result has an invalid date")
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
    preflight = _ -> nothing,
    worker_stdout = stdout,
    worker_stderr = stderr,
)
    reference_mode == "fresh" ||
        throw(ArgumentError("fresh-reference orchestration requires explicit fresh mode"))
    selected = ModelProcesses.select_models(models)
    preflight(selected)
    run_root = isnothing(temporary_parent) ?
               mktempdir(; prefix = "fresh-reference-", cleanup = false) :
               mktempdir(
        temporary_parent;
        prefix = "fresh-reference-",
        cleanup = false,
    )
    build_directory = joinpath(run_root, "build")
    mkpath(build_directory)
    build = run_build(
        build_command,
        build_directory,
        worker_stdout,
        worker_stderr,
    )
    metadata_path = joinpath(build_directory, "build_metadata.toml")
    verified = build.outcome == "passed" && isfile(metadata_path) && try
        get(TOML.parsefile(metadata_path), "verified", false) === true
    catch
        false
    end
    if build.outcome == "passed" && !verified
        build = merge(
            build,
            (;
                outcome = "failed",
                error = "shared Fortran build verification failed",
            ),
        )
    end
    build.outcome == "passed" ||
        return (;
            outcome = "failed",
            exitcode = 1,
            build,
            outcomes = Any[],
            comparisons = Dict{String, Any}(),
            run_root,
            preserved = true,
            proposal_paths = Dict{String, String}(),
        )
    model_directories = Dict(
        model => joinpath(run_root, "model-$model") for model in selected
    )
    foreach(mkpath, values(model_directories))
    workers_result = ModelProcesses.run_model_workers(
        model -> Cmd(
            worker_command(
                model,
                model_directories[model],
                build_directory,
            );
            dir = model_directories[model],
        );
        models = selected,
        workers,
        worker_stdout,
        worker_stderr,
    )
    proposal_paths = Dict{String, String}()
    comparisons = Dict{String, Any}()
    for model in selected
        comparison_path = joinpath(model_directories[model], "comparison.toml")
        isfile(comparison_path) &&
            (comparisons[model] = TOML.parsefile(comparison_path))
        path = write_proposals(model, model_directories[model])
        isnothing(path) || (proposal_paths[model] = path)
    end
    outcomes = map(workers_result.outcomes) do outcome
        haskey(proposal_paths, outcome.model) ?
        merge(
            outcome,
            (;
                outcome = "nonfinite",
                error = "fresh trajectory produced an Eligibility Gap proposal",
            ),
        ) : outcome
    end
    passed = workers_result.exitcode == 0 && isempty(proposal_paths)
    preserved = !passed
    preserved || rm(run_root; recursive = true)
    return (;
        outcome = passed ? "passed" : "failed",
        exitcode = passed ? 0 : 1,
        build,
        outcomes,
        comparisons,
        run_root,
        preserved,
        proposal_paths,
    )
end

end
