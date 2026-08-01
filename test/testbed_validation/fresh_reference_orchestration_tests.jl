using Test
import TOML

include(joinpath(@__DIR__, "fresh_reference_orchestration.jl"))
const FreshReferences = TestbedFreshReferenceOrchestration

function fake_fresh_commands(
    audit_directory;
    build_behavior = "pass",
    worker_behaviors = Dict{String, String}(),
)
    project = dirname(Base.active_project())
    script = joinpath(@__DIR__, "fake_fresh_reference_process.jl")
    build = build_directory ->
        `$(Base.julia_cmd()) --startup-file=no --project=$project $script build $build_directory $audit_directory $build_behavior`
    worker = (model, run_directory, build_directory) ->
        `$(Base.julia_cmd()) --startup-file=no --project=$project $script worker $model $run_directory $build_directory $audit_directory $(get(worker_behaviors, model, "pass"))`
    return (; build, worker)
end

@testset "Fresh reference preflights commands before building" begin
    mktempdir() do directory
        audit = joinpath(directory, "audit")
        temporary = joinpath(directory, "temporary")
        mkpath(audit)
        mkpath(temporary)
        commands = fake_fresh_commands(audit)

        @test_throws ErrorException FreshReferences.run_fresh_reference(
            "fresh",
            commands.build,
            commands.worker;
            models = "MIMICS-CN",
            temporary_parent = temporary,
            preflight = _ -> error("Representative worker unavailable"),
            worker_stdout = devnull,
            worker_stderr = devnull,
        )
        @test isempty(readdir(audit))
        @test isempty(readdir(temporary))
    end
end

@testset "Fresh reference rejects an unverified shared build" begin
    mktempdir() do directory
        audit = joinpath(directory, "audit")
        temporary = joinpath(directory, "temporary")
        mkpath(audit)
        mkpath(temporary)
        commands =
            fake_fresh_commands(audit; build_behavior = "unverified")

        result = FreshReferences.run_fresh_reference(
            "fresh",
            commands.build,
            commands.worker;
            models = "CORPSE",
            temporary_parent = temporary,
            worker_stdout = devnull,
            worker_stderr = devnull,
        )

        @test result.exitcode == 1
        @test result.build.outcome == "failed"
        @test occursin("verification", result.build.error)
        @test isempty(result.outcomes)
        @test isempty(result.comparisons)
        @test readdir(audit) == ["build.toml"]
    end
end

@testset "Fresh nonfinites create proposals without mutating pinned data" begin
    mktempdir() do directory
        audit = joinpath(directory, "audit")
        temporary = joinpath(directory, "temporary")
        protected = joinpath(directory, "protected")
        mkpath(audit)
        mkpath(temporary)
        mkpath(protected)
        protected_paths = [
            joinpath(protected, name) for
            name in ("scope.toml", "policy.toml", "Artifacts.toml")
        ]
        for (index, path) in enumerate(protected_paths)
            write(path, "sentinel = $index\n")
        end
        protected_contents =
            Dict(path => read(path) for path in protected_paths)
        commands = fake_fresh_commands(
            audit;
            worker_behaviors = Dict("CORPSE" => "nonfinite"),
        )

        result = FreshReferences.run_fresh_reference(
            "fresh",
            commands.build,
            commands.worker;
            models = "CORPSE",
            temporary_parent = temporary,
            worker_stdout = devnull,
            worker_stderr = devnull,
        )

        @test result.exitcode == 1
        @test result.outcome == "failed"
        @test result.preserved
        @test only(result.outcomes).outcome == "nonfinite"
        proposal_path = result.proposal_paths["CORPSE"]
        @test isfile(proposal_path)
        proposal = TOML.parsefile(proposal_path)
        @test proposal["schema_version"] == 1
        @test proposal["model"] == "CORPSE"
        @test proposal["source"] == "fresh_reference_nonfinite_result"
        @test length(proposal["proposal"]) == 1
        record = only(proposal["proposal"])
        @test record["cell_id"] == 51
        @test record["model"] == "CORPSE"
        @test record["reviewed"] === false
        @test all(
            path -> read(path) == protected_contents[path],
            protected_paths,
        )
        @test readdir(protected) ==
              ["Artifacts.toml", "policy.toml", "scope.toml"]
    end
end

@testset "Fresh reference failures preserve isolated evidence" begin
    mktempdir() do directory
        audit = joinpath(directory, "audit")
        temporary = joinpath(directory, "temporary")
        mkpath(audit)
        mkpath(temporary)
        commands = fake_fresh_commands(
            audit;
            worker_behaviors = Dict("MIMICS-C" => "fail"),
        )

        result = FreshReferences.run_fresh_reference(
            "fresh",
            commands.build,
            commands.worker;
            models = "MIMICS-C,CORPSE",
            workers = 2,
            temporary_parent = temporary,
            worker_stdout = devnull,
            worker_stderr = devnull,
        )

        @test result.exitcode == 1
        @test result.outcome == "failed"
        @test result.preserved
        @test isdir(result.run_root)
        @test getproperty.(result.outcomes, :model) ==
              ["CORPSE", "MIMICS-C"]
        @test getproperty.(result.outcomes, :outcome) ==
              ["passed", "failed"]
        for model in ("CORPSE", "MIMICS-C")
            record = TOML.parsefile(joinpath(audit, "$model.toml"))
            @test isdir(record["run_directory"])
            @test issetequal(
                readdir(record["run_directory"]),
                ("comparison.toml", "fortran_output.toml", "julia_output.toml"),
            )
        end
    end
end

@testset "Fresh reference mode is never selected implicitly" begin
    mktempdir() do directory
        commands = fake_fresh_commands(directory)
        @test_throws ArgumentError FreshReferences.run_fresh_reference(
            "pinned",
            commands.build,
            commands.worker,
        )
        @test isempty(readdir(directory))
    end
end

@testset "Fresh reference workers use isolated ephemeral directories" begin
    mktempdir() do directory
        audit = joinpath(directory, "audit")
        temporary = joinpath(directory, "temporary")
        mkpath(audit)
        mkpath(temporary)
        commands = fake_fresh_commands(audit)

        result = FreshReferences.run_fresh_reference(
            "fresh",
            commands.build,
            commands.worker;
            models = "CASA-CN,CORPSE,MIMICS-CN",
            workers = 2,
            temporary_parent = temporary,
            worker_stdout = devnull,
            worker_stderr = devnull,
        )

        @test result.exitcode == 0
        @test result.outcome == "passed"
        @test result.build.outcome == "passed"
        @test Set(keys(result.comparisons)) ==
              Set(("CORPSE", "MIMICS-CN", "CASA-CN"))
        @test all(
            result.comparisons[model]["model"] == model for
            model in keys(result.comparisons)
        )
        canonical_root =
            joinpath(realpath(temporary), basename(result.run_root))
        build_record = TOML.parsefile(joinpath(audit, "build.toml"))
        @test build_record["invocations"] == 1
        @test build_record["working_directory"] ==
              joinpath(canonical_root, "build")
        @test !result.preserved
        @test !isdir(result.run_root)
        @test getproperty.(result.outcomes, :model) ==
              ["CORPSE", "MIMICS-CN", "CASA-CN"]
        records = [
            TOML.parsefile(joinpath(audit, "$model.toml")) for
            model in ("CORPSE", "MIMICS-CN", "CASA-CN")
        ]
        @test length(unique(getindex.(records, "run_directory"))) == 3
        @test length(unique(getindex.(records, "build_directory"))) == 1
        @test getindex.(records, "working_directory") == [
            joinpath(canonical_root, "model-$model") for
            model in ("CORPSE", "MIMICS-CN", "CASA-CN")
        ]
        @test all(
            record -> startswith(
                record["run_directory"],
                result.run_root,
            ),
            records,
        )
        @test readdir(audit) ==
              ["CASA-CN.toml", "CORPSE.toml", "MIMICS-CN.toml", "build.toml"]
    end
end

@testset "Fresh reference build verification is fail-fast" begin
    mktempdir() do directory
        audit = joinpath(directory, "audit")
        temporary = joinpath(directory, "temporary")
        mkpath(audit)
        mkpath(temporary)
        commands =
            fake_fresh_commands(audit; build_behavior = "missing")

        result = FreshReferences.run_fresh_reference(
            "fresh",
            commands.build,
            commands.worker;
            models = "CORPSE",
            temporary_parent = temporary,
            worker_stdout = devnull,
            worker_stderr = devnull,
        )

        @test result.exitcode == 1
        @test result.build.outcome == "failed"
        @test occursin("verification", result.build.error)
        @test isempty(result.outcomes)
        @test readdir(audit) == ["build.toml"]
    end
end

@testset "Fresh reference build fails before model workers launch" begin
    mktempdir() do directory
        audit = joinpath(directory, "audit")
        temporary = joinpath(directory, "temporary")
        mkpath(audit)
        mkpath(temporary)
        commands =
            fake_fresh_commands(audit; build_behavior = "fail")

        result = FreshReferences.run_fresh_reference(
            "fresh",
            commands.build,
            commands.worker;
            models = "CORPSE,MIMICS-CN",
            temporary_parent = temporary,
            worker_stdout = devnull,
            worker_stderr = devnull,
        )

        @test result.exitcode == 1
        @test result.build.outcome == "failed"
        @test isempty(result.outcomes)
        @test result.preserved
        @test isdir(result.run_root)
        @test isfile(joinpath(audit, "build.toml"))
        @test isempty(filter(name -> endswith(name, ".toml"), setdiff(
            readdir(audit),
            ["build.toml"],
        )))
        @test isempty(filter(
            name -> startswith(name, "model-"),
            readdir(result.run_root),
        ))
    end
end
