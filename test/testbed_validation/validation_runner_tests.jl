using Test
import TOML

const VALIDATION_RUNNER =
    joinpath(@__DIR__, "validation_runner.jl")

function run_validation(args...; environment = Dict{String, String}())
    project = dirname(Base.active_project())
    command = addenv(
        `$(Base.julia_cmd()) --startup-file=no --project=$project $VALIDATION_RUNNER $args`,
        "JULIA_NUM_THREADS" => "1",
        environment...,
    )
    stdout = IOBuffer()
    stderr = IOBuffer()
    process = run(pipeline(ignorestatus(command); stdout, stderr))
    return (;
        exitcode = process.exitcode,
        stdout = String(take!(stdout)),
        stderr = String(take!(stderr)),
    )
end

@testset "Validation Runner rejects unavailable defaults and invalid values" begin
    defaults = run_validation()
    @test defaults.exitcode == 2
    @test occursin("Representative Scope is not available yet", defaults.stderr)

    invalid = run_validation("--scope", "unknown")
    @test invalid.exitcode == 2
    @test occursin("scope must be one of", invalid.stderr)

    invalid = run_validation("--scope", "core", "--workers", "0")
    @test invalid.exitcode == 2
    @test occursin("workers must be positive", invalid.stderr)
end

@testset "Validation Runner fails closed before CASA-C simulation" begin
    mktempdir() do output
        missing = joinpath(output, "missing-reference.toml")
        result = run_validation(
            "--scope",
            "core",
            "--models",
            "CASA-C",
            "--output",
            output;
            environment = Dict(
                "CLIMALAND_VALIDATION_CASA_C_REFERENCE" => missing,
            ),
        )

        @test result.exitcode == 2
        @test occursin("Pinned CASA-C reference is missing", result.stderr)
        report = TOML.parsefile(joinpath(output, "validation_report.toml"))
        @test report["scope"]["name"] == "core"
        @test report["model"][1]["name"] == "CASA-C"
        @test report["model"][1]["reference_mode"] == "pinned"
        @test report["model"][1]["coverage"]["compared_cells"] == 0
        @test report["model"][1]["outcome"] == "failed"
        @test !isdir(joinpath(output, "CASA-C", "stages"))
    end

    mktempdir() do output
        incompatible = joinpath(output, "incompatible-reference.toml")
        write(incompatible, "schema_version = 2\n")
        result = run_validation(
            "--scope",
            "core",
            "--models",
            "CASA-C",
            "--output",
            output;
            environment = Dict(
                "CLIMALAND_VALIDATION_CASA_C_REFERENCE" => incompatible,
            ),
        )

        @test result.exitcode == 2
        @test occursin("incompatible schema", result.stderr)
        @test !isdir(joinpath(output, "CASA-C", "stages"))
    end
end
