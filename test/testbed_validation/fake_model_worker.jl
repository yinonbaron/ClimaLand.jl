import LinearAlgebra
import TOML

model, delay, behavior, directory = ARGS
println("$model stdout")
println(stderr, "$model stderr")
started_ns = time_ns()
open(joinpath(directory, "$model.started.toml"), "w") do io
    TOML.print(io, Dict("started_ns" => started_ns))
end
sleep(parse(Float64, delay))
behavior == "crash" && error("requested fake worker crash")
if startswith(behavior, "wait:")
    marker = joinpath(directory, last(split(behavior, ':'; limit = 2)))
    status = timedwait(() -> isfile(marker), 10; pollint = 0.01)
    status == :ok || error("timed out waiting for $marker")
end
finished_ns = time_ns()
open(joinpath(directory, "$model.finished.toml"), "w") do io
    TOML.print(
        io,
        Dict(
            "blas_threads" => LinearAlgebra.BLAS.get_num_threads(),
            "finished_ns" => finished_ns,
            "julia_num_threads" => Threads.nthreads(),
            "julia_num_threads_environment" =>
                get(ENV, "JULIA_NUM_THREADS", ""),
            "model" => model,
            "mkl_num_threads_environment" =>
                get(ENV, "MKL_NUM_THREADS", ""),
            "omp_num_threads_environment" =>
                get(ENV, "OMP_NUM_THREADS", ""),
            "openblas_num_threads_environment" =>
                get(ENV, "OPENBLAS_NUM_THREADS", ""),
            "started_ns" => started_ns,
            "veclib_maximum_threads_environment" =>
                get(ENV, "VECLIB_MAXIMUM_THREADS", ""),
        );
        sorted = true,
    )
end
