using Test
import SHA
import TOML

const VALIDATION_RUNNER = joinpath(@__DIR__, "validation_runner.jl")
const VALIDATION_SCOPE_MANIFESTS = joinpath(@__DIR__, "validation", "scopes")

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

@testset "Validation Runner reports reviewed Eligibility Gaps" begin
    mktempdir() do directory
        manifests = joinpath(directory, "scopes")
        mkpath(manifests)
        cp(
            joinpath(VALIDATION_SCOPE_MANIFESTS, "core.toml"),
            joinpath(manifests, "core.toml"),
        )
        smoke =
            TOML.parsefile(joinpath(VALIDATION_SCOPE_MANIFESTS, "smoke.toml"))
        smoke["eligibility_gaps"] = [
            Dict(
                "model" => "CASA-C",
                "cell_id" => 51,
                "reason" => "reviewed nonfinite Fortran trajectory",
                "reviewed" => true,
            ),
        ]
        open(joinpath(manifests, "smoke.toml"), "w") do io
            TOML.print(io, smoke; sorted = true)
        end

        output = joinpath(directory, "output")
        result = run_validation(
            "--scope",
            "smoke",
            "--models",
            "CASA-C",
            "--output",
            output;
            environment = Dict(
                "CLIMALAND_VALIDATION_SCOPE_MANIFEST_DIRECTORY" =>
                    manifests,
                "CLIMALAND_VALIDATION_CASA_C_REFERENCE" =>
                    joinpath(directory, "missing-reference.toml"),
            ),
        )

        @test result.exitcode == 2
        report = TOML.parsefile(joinpath(output, "validation_report.toml"))
        coverage = report["model"][1]["coverage"]
        @test coverage["scope_cells"] == 37
        @test coverage["eligible_cells"] == 36
        @test coverage["compared_cells"] == 0
        @test coverage["eligibility_gaps"] == [
            Dict(
                "model" => "CASA-C",
                "cell_id" => 51,
                "reason" => "reviewed nonfinite Fortran trajectory",
                "reviewed" => true,
            ),
        ]
    end
end

@testset "Validation Runner rejects unreviewed Eligibility Gaps" begin
    mktempdir() do directory
        manifests = joinpath(directory, "scopes")
        mkpath(manifests)
        cp(
            joinpath(VALIDATION_SCOPE_MANIFESTS, "core.toml"),
            joinpath(manifests, "core.toml"),
        )
        smoke =
            TOML.parsefile(joinpath(VALIDATION_SCOPE_MANIFESTS, "smoke.toml"))
        smoke["eligibility_gaps"] = [
            Dict(
                "model" => "CASA-C",
                "cell_id" => 51,
                "reason" => "not reviewed",
                "reviewed" => false,
            ),
        ]
        open(joinpath(manifests, "smoke.toml"), "w") do io
            TOML.print(io, smoke; sorted = true)
        end

        result = run_validation(
            "--scope",
            "smoke",
            "--models",
            "CASA-C";
            environment = Dict(
                "CLIMALAND_VALIDATION_SCOPE_MANIFEST_DIRECTORY" =>
                    manifests,
            ),
        )

        @test result.exitcode == 2
        @test occursin("unreviewed Eligibility Gap", result.stderr)
    end
end

@testset "Validation Runner rejects eligible nonfinite reference values" begin
    mktempdir() do directory
        reference = joinpath(directory, "nonfinite-reference.toml")
        open(reference, "w") do io
            TOML.print(
                io,
                Dict(
                    "schema_version" => 1,
                    "cell_ids" => [
                        51,
                        626,
                        923,
                        1285,
                        3613,
                        4273,
                        4397,
                        4453,
                        6325,
                        10644,
                        10997,
                    ],
                    "configuration" => Dict(
                        "carbon_only" => Dict(
                            "native_julia" => Dict(
                                "initialization" => Dict(
                                    "casa_plant.c_leaf" => [Inf; zeros(10)],
                                ),
                            ),
                        ),
                    ),
                );
                sorted = true,
            )
        end
        output = joinpath(directory, "output")
        result = run_validation(
            "--scope",
            "core",
            "--models",
            "CASA-C",
            "--output",
            output;
            environment = Dict(
                "CLIMALAND_VALIDATION_CASA_C_REFERENCE" => reference,
            ),
        )

        @test result.exitcode == 2
        @test occursin(
            "eligible nonfinite reference value for CASA-C cell 51",
            result.stderr,
        )
        report = TOML.parsefile(joinpath(output, "validation_report.toml"))
        @test report["model"][1]["coverage"]["eligible_cells"] == 11
        @test report["model"][1]["coverage"]["compared_cells"] == 0
    end
end

@testset "Validation Runner resolves manifest-backed Core and Smoke scopes" begin
    reports = Dict{String, Any}()
    for (scope, cell_count) in (("core", 11), ("smoke", 37))
        mktempdir() do output
            result = run_validation(
                "--scope",
                scope,
                "--models",
                "CASA-C",
                "--output",
                output;
                environment = Dict(
                    "CLIMALAND_VALIDATION_CASA_C_REFERENCE" =>
                        joinpath(output, "missing-reference.toml"),
                ),
            )

            @test result.exitcode == 2
            report = TOML.parsefile(joinpath(output, "validation_report.toml"))
            reports[scope] = report
            @test report["scope"]["name"] == scope
            @test report["scope"]["cell_count"] == cell_count
            @test report["scope"]["cell_ids"] ==
                  sort(report["scope"]["cell_ids"])
            @test report["scope"]["manifest_sha256"] ==
                  bytes2hex(SHA.sha256(read(report["scope"]["manifest"])))
            @test report["comparison_policy"]["model"] == "CASA-C"
            @test report["comparison_policy"]["sha256"] == bytes2hex(
                SHA.sha256(read(report["comparison_policy"]["path"])),
            )
            @test report["comparison_policy"]["budget_rtol"] == 5.0e-12
        end
    end

    @test issetequal(
        reports["core"]["scope"]["cell_ids"],
        intersect(
            reports["core"]["scope"]["cell_ids"],
            reports["smoke"]["scope"]["cell_ids"],
        ),
    )
    @test reports["core"]["scope"]["cell_ids"] !=
          reports["smoke"]["scope"]["cell_ids"]
end

@testset "Validation Runner warns for temporary scope aliases" begin
    for (alias, canonical) in (("ordinary", "core"), ("extended", "smoke"))
        mktempdir() do output
            result = run_validation(
                "--scope",
                alias,
                "--models",
                "CASA-C",
                "--output",
                output;
                environment = Dict(
                    "CLIMALAND_VALIDATION_CASA_C_REFERENCE" =>
                        joinpath(output, "missing-reference.toml"),
                ),
            )

            @test result.exitcode == 2
            @test occursin(
                "$alias is deprecated; use $canonical",
                result.stderr,
            )
            report = TOML.parsefile(joinpath(output, "validation_report.toml"))
            @test report["scope"]["name"] == canonical
        end
    end
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

@testset "Validation Runner completes the pinned Core CASA-C comparison" begin
    mktempdir() do output
        result = run_validation(
            "--scope",
            "core",
            "--models",
            "CASA-C",
            "--reference",
            "pinned",
            "--workers",
            "1",
            "--output",
            output,
        )

        @test result.exitcode == 0
        @test occursin("Validation: passed", result.stdout)
        report = TOML.parsefile(joinpath(output, "validation_report.toml"))
        @test report["scope"]["name"] == "core"
        @test report["scope"]["cell_count"] == 11
        @test report["model"][1]["name"] == "CASA-C"
        @test report["model"][1]["coverage"]["compared_cells"] == 11
        @test report["model"][1]["outcome"] == "passed"
        @test report["model"][1]["seconds"] > 0
        @test Set(keys(report["model"][1]["comparison"])) == Set([
            "initialization",
            "fresh_fortran_boundaries",
            "carbon_budget",
            "passive_restoration",
            "checkpoint_roundtrip",
        ])
        @test all(values(report["model"][1]["comparison"]))
        @test report["outcome"] == "passed"
    end
end
