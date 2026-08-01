using Test
import SHA
import TOML

include(joinpath(@__DIR__, "fresh_reference_adapter.jl"))
const FreshReferenceAdapter = TestbedFreshReferenceAdapter

@testset "Fresh-reference adapter verifies shared builds" begin
    mktempdir() do directory
        executable = joinpath(directory, "casaclm_mimics-cn_corpse")
        write(executable, "shared executable")
        metadata_path = joinpath(directory, "build_metadata.toml")
        metadata = Dict(
            "schema_version" => 1,
            "verified" => true,
            "verification" => Dict(
                "executable" => basename(executable),
                "executable_sha256" =>
                    bytes2hex(SHA.sha256(read(executable))),
                "source_commit" =>
                    FreshReferenceAdapter.PINNED_SOURCE_COMMIT,
                "source_code_clean" => true,
            ),
        )
        open(metadata_path, "w") do io
            TOML.print(io, metadata; sorted = true)
        end

        @test FreshReferenceAdapter.verified_executable(directory) == executable
        write(executable, "changed")
        @test_throws FreshReferenceAdapter.AdapterError FreshReferenceAdapter.verified_executable(
            directory,
        )
    end
end

@testset "Fresh-reference commands expose the orchestration seam" begin
    commands = FreshReferenceAdapter.commands("../biogeochem_testbed")
    build = commands.build("/tmp/fresh-build")
    worker = commands.worker("CASA-C", "/tmp/fresh-casa", "/tmp/fresh-build")

    @test first(build.exec) == Base.julia_cmd().exec[1]
    @test "build" in build.exec
    @test abspath("../biogeochem_testbed") in build.exec
    @test "worker" in worker.exec
    @test "CASA-C" in worker.exec
    @test abspath("../biogeochem_testbed") in worker.exec
    @test_throws FreshReferenceAdapter.AdapterError commands.preflight([
        "CASA-C",
    ])
    mimics_cn = commands.mimics_cn(
        "/tmp/forcing",
        "/tmp/reference-template",
        "/tmp/fresh-mimics-cn",
        "/tmp/fresh-build",
    )
    @test "run-mimics-cn-80" in mimics_cn.exec
    @test "/tmp/forcing" in mimics_cn.exec
    @test "/tmp/reference-template" in mimics_cn.exec
end

@testset "Fresh model capabilities expose exact remaining gaps" begin
    @test Set(keys(FreshReferenceAdapter.MISSING_MODEL_COMMANDS)) ==
          Set(FreshReferenceAdapter.ModelProcesses.MODELS)
    @test Set(keys(FreshReferenceAdapter.MODEL_CAPABILITIES)) ==
          Set(FreshReferenceAdapter.ModelProcesses.MODELS)
    for model in FreshReferenceAdapter.ModelProcesses.MODELS
        capability = FreshReferenceAdapter.model_capability(model)
        @test isfile(capability.runner)
        @test !capability.representative_ready
        @test !isempty(capability.blocker)
        error = try
            FreshReferenceAdapter.require_model_command(model)
            nothing
        catch caught
            caught
        end
        @test error isa FreshReferenceAdapter.AdapterError
        @test occursin(model, error.message)
        @test occursin("Representative", error.message)
    end
    mimics_cn = FreshReferenceAdapter.model_capability("MIMICS-CN")
    @test mimics_cn.deepest_scope == "representative"
    @test mimics_cn.shared_build
    @test mimics_cn.completed_phases == ("fortran", "julia")
    @test occursin("comparison", lowercase(mimics_cn.blocker))
    status = FreshReferenceAdapter.status_document()
    @test status["representative_workers_ready"] === false
    @test Set(keys(status["model"])) ==
          Set(FreshReferenceAdapter.ModelProcesses.MODELS)
end

@testset "Fresh-reference tracer requires an empty directory" begin
    mktempdir() do directory
        fresh = joinpath(directory, "fresh")
        @test FreshReferenceAdapter.require_empty_directory(fresh) == fresh
        @test isdir(fresh)
        write(joinpath(fresh, "stale"), "old output")
        @test_throws FreshReferenceAdapter.AdapterError FreshReferenceAdapter.require_empty_directory(
            fresh,
        )
        file = joinpath(directory, "not-a-directory")
        write(file, "file")
        @test_throws FreshReferenceAdapter.AdapterError FreshReferenceAdapter.require_empty_directory(
            file,
        )
    end
end

@testset "Fresh MIMICS-CN workflow records the shared build source" begin
    mktempdir() do directory
        path = joinpath(directory, "workflow.toml")
        open(path, "w") do io
            TOML.print(
                io,
                Dict("schema_version" => 1, "source_commit" => "archive"),
            )
        end
        FreshReferenceAdapter.pin_workflow_source!(path)
        @test TOML.parsefile(path)["source_commit"] ==
              FreshReferenceAdapter.PINNED_SOURCE_COMMIT
    end
end

@testset "CASA-C tracer is explicitly not a Representative worker" begin
    @test FreshReferenceAdapter.CASA_C_TRACER_MODEL == "CASA-C"
    @test FreshReferenceAdapter.CASA_C_TRACER_SCOPE == "one-cell-boundary"
    @test_throws FreshReferenceAdapter.AdapterError FreshReferenceAdapter.main([
        "worker",
        "CASA-C",
        "/tmp/run",
        "/tmp/build",
        abspath("../biogeochem_testbed"),
    ],)
end
