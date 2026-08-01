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
    worker_log_directory = nothing,
)
    selected = select_models(models)
    limit = worker_count(workers)
    isnothing(worker_log_directory) || mkpath(worker_log_directory)
    pending = collect(selected)
    running = Dict{String, Any}()
    completed = Dict{String, Any}()

    while !isempty(pending) || !isempty(running)
        while !isempty(pending) && length(running) < limit
            model = popfirst!(pending)
            started_ns = time_ns()
            worker_log = nothing
            worker_log_path = nothing
            try
                if !isnothing(worker_log_directory)
                    worker_log_path =
                        joinpath(worker_log_directory, "$model.log")
                    worker_log = open(worker_log_path, "w")
                end
                command = addenv(
                    worker_command(model),
                    "JULIA_NUM_THREADS" => "1",
                    "OPENBLAS_NUM_THREADS" => "1",
                )
                process = run(
                    pipeline(
                        ignorestatus(command);
                        stdout =
                            isnothing(worker_log) ? worker_stdout : worker_log,
                        stderr =
                            isnothing(worker_log) ? worker_stderr : worker_log,
                    );
                    wait = false,
                )
                running[model] =
                    (; process, started_ns, worker_log, worker_log_path)
            catch error
                isnothing(worker_log) || close(worker_log)
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
        isnothing(worker.worker_log) || close(worker.worker_log)
        code = worker.process.exitcode
        signal = worker.process.termsignal
        passed = success(worker.process)
        passed && !isnothing(worker.worker_log_path) &&
            rm(worker.worker_log_path)
        completed[model] = (;
            model,
            outcome = passed ? "passed" : "failed",
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
