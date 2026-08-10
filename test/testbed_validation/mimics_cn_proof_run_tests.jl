using Test
import SHA
import TOML

include(joinpath(@__DIR__, "mimics_cn_proof_run.jl"))
const MIMICSCNProofRun = TestbedMIMICSCNProofRun

proof_sha256(path) = bytes2hex(SHA.sha256(read(path)))

function write_proof_toml(path, document)
    mkpath(dirname(path))
    open(path, "w") do io
        TOML.print(io, document; sorted = true)
    end
    return abspath(path)
end

function make_proof_run(directory)
    validation_root = joinpath(directory, "validation")
    cell_ids = collect(1:80)
    scope = write_proof_toml(
        joinpath(directory, "representative.toml"),
        Dict(
            "schema_version" => 1,
            "name" => "representative",
            "cell_ids" => cell_ids,
            "eligibility_gaps" => Any[],
        ),
    )
    oracle = write_proof_toml(
        joinpath(directory, "reduced_oracle.toml"),
        Dict(
            "schema_version" => 1,
            "model" => "MIMICS-CN",
            "scope" => "representative",
            "cell_ids" => cell_ids,
            "provenance" => Dict(
                "fortran_source_revision" => repeat("a", 40),
                "generator_sha256" => repeat("b", 64),
                "scope_manifest_sha256" => proof_sha256(scope),
                "fortran_build_sha256" => repeat("c", 64),
            ),
            "oracle" => Dict(
                "boundary" => Dict(),
                "annual" => Dict(),
                "daily" => Dict(),
                "budget" => Dict(),
            ),
        ),
    )
    boundary = write_proof_toml(
        joinpath(directory, "boundary.toml"),
        Dict("schema_version" => 1),
    )
    historical = write_proof_toml(
        joinpath(directory, "historical.toml"),
        Dict("schema_version" => 1),
    )
    forcing = write_proof_toml(
        joinpath(directory, "fixture.toml"),
        Dict("schema_version" => 1),
    )
    coverage = Dict(
        "scope_cell_ids" => cell_ids,
        "eligible_cell_ids" => cell_ids,
        "scope_cells" => 80,
        "compared_cells" => 80,
        "eligibility_gaps" => Any[],
    )
    scientific = write_proof_toml(
        joinpath(validation_root, "MIMICS-CN", "reconstruction_report.toml"),
        Dict(
            "schema_version" => 1,
            "coverage" => coverage,
            "boundary_comparison" => Dict(
                stage => Dict("all_match" => true) for stage in
                ("prespin", "spin", "spin_continuation", "historical")
            ),
            "historical_comparison" => Dict("all_match" => true),
            "carbon_budget" => Dict("all_close" => true),
            "nitrogen_budget" => Dict("all_close" => true),
        ),
    )
    validation = write_proof_toml(
        joinpath(validation_root, "validation_report.toml"),
        Dict(
            "schema_version" => 1,
            "reference_mode" => "pinned",
            "outcome" => "passed",
            "scope" => Dict(
                "name" => "representative",
                "cell_count" => 80,
                "cell_ids" => cell_ids,
                "manifest" => scope,
                "manifest_sha256" => proof_sha256(scope),
            ),
            "model" => [
                Dict(
                    "name" => "MIMICS-CN",
                    "reference_mode" => "pinned",
                    "outcome" => "passed",
                    "coverage" => Dict(
                        "scope_cells" => 80,
                        "eligible_cells" => 80,
                        "compared_cells" => 80,
                        "eligibility_gaps" => Any[],
                    ),
                    "comparison" => Dict(
                        "fresh_fortran_boundaries" => true,
                        "historical" => true,
                        "carbon_budget" => true,
                        "nitrogen_budget" => true,
                    ),
                    "comparison_report" => scientific,
                    "reference" => Dict(
                        "path" => oracle,
                        "sha256" => proof_sha256(oracle),
                    ),
                    "comparison_policy" => Dict(
                        "boundary_calibration" => boundary,
                        "boundary_calibration_sha256" =>
                            proof_sha256(boundary),
                        "historical_calibration" => historical,
                        "historical_calibration_sha256" =>
                            proof_sha256(historical),
                    ),
                    "forcing" => Dict(
                        "manifest" => forcing,
                        "manifest_sha256" => proof_sha256(forcing),
                    ),
                ),
            ],
        ),
    )
    return (; validation_root, validation, scope, oracle, scientific)
end

@testset "MIMICS-CN proof run becomes a noncanonical local candidate" begin
    mktempdir() do directory
        fixture = make_proof_run(directory)
        destination = joinpath(directory, "local-candidate.toml")

        result = MIMICSCNProofRun.write_local_candidate(
            fixture.validation_root,
            fixture.oracle,
            destination;
            scope_manifest_path = fixture.scope,
        )

        @test result.path == abspath(destination)
        candidate = TOML.parsefile(destination)
        @test candidate["operation"] == "local_reference_candidate_audit"
        @test candidate["canonical"] === false
        @test candidate["publishable"] === false
        @test candidate["files"]["oracle"] == proof_sha256(fixture.oracle)
        @test candidate["files"]["validation_report"] ==
              proof_sha256(fixture.validation)
        @test candidate["files"]["scientific_report"] ==
              proof_sha256(fixture.scientific)
        @test candidate["coverage"]["scope_cells"] == 80
        @test candidate["coverage"]["eligible_cells"] == 80
        @test candidate["coverage"]["compared_cells"] == 80
        @test isempty(candidate["coverage"]["eligibility_gaps"])
        @test !isfile(
            joinpath(fixture.validation_root, "publication_candidate.toml"),
        )
    end
end

@testset "MIMICS-CN proof postprocessing fails closed" begin
    for (label, mutate, message) in (
        (
            "changed oracle",
            fixture -> write(fixture.oracle, "changed"),
            "oracle SHA-256",
        ),
        (
            "failed scientific comparison",
            fixture -> begin
                report = TOML.parsefile(fixture.scientific)
                report["nitrogen_budget"]["all_close"] = false
                write_proof_toml(fixture.scientific, report)
            end,
            "nitrogen budget",
        ),
        (
            "wrong coverage",
            fixture -> begin
                report = TOML.parsefile(fixture.validation)
                only(report["model"])["coverage"]["compared_cells"] = 79
                write_proof_toml(fixture.validation, report)
            end,
            "coverage",
        ),
        (
            "invented Eligibility Gap",
            fixture -> begin
                report = TOML.parsefile(fixture.validation)
                only(report["model"])["coverage"]["eligibility_gaps"] =
                    [Dict("model" => "MIMICS-CN", "cell_id" => 80)]
                write_proof_toml(fixture.validation, report)
            end,
            "Eligibility Gap",
        ),
    )
        @testset "$label" begin
            mktempdir() do directory
                fixture = make_proof_run(directory)
                mutate(fixture)
                error = try
                    MIMICSCNProofRun.write_local_candidate(
                        fixture.validation_root,
                        fixture.oracle,
                        joinpath(directory, "candidate.toml");
                        scope_manifest_path = fixture.scope,
                    )
                    nothing
                catch caught
                    caught
                end
                @test error isa MIMICSCNProofRun.ProofError
                @test occursin(message, sprint(showerror, error))
                @test !isfile(joinpath(directory, "candidate.toml"))
            end
        end
    end
end
