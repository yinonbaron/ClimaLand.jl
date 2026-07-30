module TestbedModelProcessOrchestration

const MODELS = ("CORPSE", "MIMICS-C", "MIMICS-CN", "CASA-C", "CASA-CN")

function select_models(value = "all")
    requested =
        value == "all" ? collect(MODELS) :
        value isa AbstractString ? split(value, ','; keepempty = false) :
        collect(value)
    isempty(requested) &&
        throw(ArgumentError("models must be all or a comma-separated subset"))
    invalid = setdiff(requested, MODELS)
    isempty(invalid) ||
        throw(ArgumentError("unknown models: $(join(invalid, ", "))"))
    return filter(model -> model in requested, collect(MODELS))
end

function default_worker_count(; cpu_threads = Sys.CPU_THREADS)
    cpu_threads > 0 ||
        throw(ArgumentError("available CPU count must be positive"))
    return min(length(MODELS), cpu_threads)
end

function worker_count(value)
    value isa Bool &&
        throw(ArgumentError("workers must be a positive integer"))
    count = value isa Integer ? Int(value) : tryparse(Int, value)
    isnothing(count) &&
        throw(ArgumentError("workers must be a positive integer"))
    count > 0 || throw(ArgumentError("workers must be positive"))
    return count
end

function run_model_workers(
    worker_command;
    models = collect(MODELS),
    workers = default_worker_count(),
    worker_stdout = stdout,
    worker_stderr = stderr,
)
    selected = select_models(models)
    limit = worker_count(workers)
    pending = collect(selected)
    running = Dict{String, Any}()
    completed = Dict{String, Any}()

    while !isempty(pending) || !isempty(running)
        while !isempty(pending) && length(running) < limit
            model = popfirst!(pending)
            started_ns = time_ns()
            try
                command = addenv(
                    worker_command(model),
                    "JULIA_NUM_THREADS" => "1",
                    "OPENBLAS_NUM_THREADS" => "1",
                )
                process = run(
                    pipeline(
                        ignorestatus(command);
                        stdout = worker_stdout,
                        stderr = worker_stderr,
                    );
                    wait = false,
                )
                running[model] = (; process, started_ns)
            catch error
                completed[model] = (;
                    model,
                    outcome = "crashed",
                    exitcode = nothing,
                    signal = nothing,
                    seconds = (time_ns() - started_ns) / 1e9,
                    error = sprint(showerror, error),
                )
            end
        end

        isempty(running) && continue
        index = findfirst(
            name ->
                haskey(running, name) &&
                    process_exited(running[name].process),
            selected,
        )
        if isnothing(index)
            sleep(0.005)
            continue
        end
        model = selected[index]
        worker = pop!(running, model)
        wait(worker.process)
        code = worker.process.exitcode
        signal = worker.process.termsignal
        completed[model] = (;
            model,
            outcome = success(worker.process) ? "passed" : "failed",
            exitcode = code,
            signal,
            seconds = (time_ns() - worker.started_ns) / 1e9,
            error = nothing,
        )
    end

    outcomes = [completed[model] for model in selected]
    passed = all(outcome -> outcome.outcome == "passed", outcomes)
    return (;
        outcome = passed ? "passed" : "failed",
        exitcode = passed ? 0 : 1,
        outcomes,
    )
end

end
