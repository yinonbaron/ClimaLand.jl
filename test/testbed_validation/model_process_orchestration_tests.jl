using Test
import TOML

include(joinpath(@__DIR__, "model_process_orchestration.jl"))
const ModelProcesses = TestbedModelProcessOrchestration

function fake_worker_command(
    directory,
    delays;
    behaviors = Dict{String, String}(),
)
    project = dirname(Base.active_project())
    worker = joinpath(@__DIR__, "fake_model_worker.jl")
    return model -> `$(Base.julia_cmd()) --startup-file=no --project=$project $worker $model $(delays[model]) $(get(behaviors, model, "pass")) $directory`
end

@testset "Model worker crashes are isolated and fail the aggregate" begin
    mktempdir() do directory
        selected = ("CASA-CN", "CORPSE", "MIMICS-CN")
        delays = Dict(model => 0.05 for model in selected)
        log_directory = joinpath(directory, "logs")
        result = ModelProcesses.run_model_workers(
            fake_worker_command(
                directory,
                delays;
                behaviors = Dict("MIMICS-CN" => "crash"),
            );
            models = join(selected, ","),
            workers = 2,
            worker_log_directory = log_directory,
        )

        @test result.exitcode == 1
        @test result.outcome == "failed"
        @test getproperty.(result.outcomes, :model) ==
              ["CORPSE", "MIMICS-CN", "CASA-CN"]
        @test getproperty.(result.outcomes, :outcome) ==
              ["passed", "failed", "passed"]
        @test result.outcomes[2].exitcode != 0
        @test result.outcomes[2].signal == 0
        @test all(outcome -> outcome.seconds > 0, result.outcomes)
        @test isfile(joinpath(directory, "CORPSE.finished.toml"))
        @test !isfile(joinpath(directory, "MIMICS-CN.finished.toml"))
        @test isfile(joinpath(directory, "CASA-CN.finished.toml"))
        @test readdir(log_directory) == ["MIMICS-CN.log"]
        failure_log = read(joinpath(log_directory, "MIMICS-CN.log"), String)
        @test occursin("MIMICS-CN stdout", failure_log)
        @test occursin("MIMICS-CN stderr", failure_log)
    end
end

@testset "Model process selection and concurrency are bounded" begin
    @test ModelProcesses.select_models("all") ==
          collect(ModelProcesses.MODELS)
    @test ModelProcesses.select_models("CASA-CN,CORPSE") ==
          ["CORPSE", "CASA-CN"]
    @test ModelProcesses.default_worker_count(; cpu_threads = 3) == 3
    @test ModelProcesses.default_worker_count(; cpu_threads = 20) == 5
    @test ModelProcesses.worker_count("2") == 2
    @test_throws ArgumentError ModelProcesses.select_models("")
    @test_throws ArgumentError ModelProcesses.select_models("UNKNOWN")
    @test_throws ArgumentError ModelProcesses.worker_count("many")
    @test_throws ArgumentError ModelProcesses.worker_count("0")
    @test_throws ArgumentError ModelProcesses.worker_count(true)
end

@testset "Model workers refill bounded slots in isolated processes" begin
    mktempdir() do directory
        delays = Dict(
            "CORPSE" => 0.05,
            "MIMICS-C" => 0.0,
            "MIMICS-CN" => 0.1,
            "CASA-C" => 0.1,
            "CASA-CN" => 0.1,
        )
        result = ModelProcesses.run_model_workers(
            fake_worker_command(
                directory,
                delays;
                behaviors = Dict(
                    "MIMICS-C" => "wait:MIMICS-CN.started.toml",
                ),
            );
            workers = 2,
            worker_stdout = devnull,
            worker_stderr = devnull,
        )

        @test result.exitcode == 0
        @test getproperty.(result.outcomes, :model) ==
              collect(ModelProcesses.MODELS)
        @test all(outcome -> outcome.outcome == "passed", result.outcomes)
        @test all(outcome -> outcome.seconds > 0, result.outcomes)
        records = Dict(
            model => TOML.parsefile(
                joinpath(directory, "$model.finished.toml"),
            ) for model in ModelProcesses.MODELS
        )
        @test all(
            record ->
                record["julia_num_threads"] == 1 &&
                    record["blas_threads"] == 1 &&
                    record["julia_num_threads_environment"] == "1" &&
                    record["openblas_num_threads_environment"] == "1" &&
                    record["omp_num_threads_environment"] == "1" &&
                    record["mkl_num_threads_environment"] == "1" &&
                    record["veclib_maximum_threads_environment"] == "1",
            values(records),
        )
        events = [
            (record["started_ns"], 1) for record in values(records)
        ]
        append!(
            events,
            [(record["finished_ns"], -1) for record in values(records)],
        )
        active = 0
        maximum_active = 0
        for (_, change) in sort(events; by = event -> (event[1], event[2]))
            active += change
            maximum_active = max(maximum_active, active)
        end
        @test maximum_active == 2
        @test records["MIMICS-CN"]["started_ns"] >=
              records["CORPSE"]["finished_ns"]
        @test records["MIMICS-CN"]["started_ns"] <
              records["MIMICS-C"]["finished_ns"]
    end
end
