using Test
import SHA
import TOML

const VALIDATION_RUNNER = joinpath(@__DIR__, "validation_runner.jl")
const VALIDATION_SCOPE_MANIFESTS = joinpath(@__DIR__, "validation", "scopes")
const VALIDATION_COMPARISON_POLICY =
    joinpath(@__DIR__, "validation", "comparison_policy.toml")
const VALIDATION_CASA_C_CALIBRATION =
    joinpath(@__DIR__, "validation", "casa_c_full_grid_calibration.toml")
include(VALIDATION_RUNNER)
const VALIDATION_RUNNER_MODULE = TestbedValidationRunner

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

function write_smoke_scope_manifests(directory, eligibility_gaps)
    manifests = joinpath(directory, "scopes")
    mkpath(manifests)
    cp(
        joinpath(VALIDATION_SCOPE_MANIFESTS, "core.toml"),
        joinpath(manifests, "core.toml"),
    )
    smoke = TOML.parsefile(joinpath(VALIDATION_SCOPE_MANIFESTS, "smoke.toml"))
    smoke["eligibility_gaps"] = eligibility_gaps
    open(joinpath(manifests, "smoke.toml"), "w") do io
        TOML.print(io, smoke; sorted = true)
    end
    return manifests
end

@testset "Validation Runner reports reviewed Eligibility Gaps" begin
    mktempdir() do directory
        eligibility_gaps = [
            Dict(
                "model" => "CASA-C",
                "cell_id" => 51,
                "reason" => "reviewed nonfinite Fortran trajectory",
                "reviewed" => true,
            ),
        ]
        manifests = write_smoke_scope_manifests(directory, eligibility_gaps)

        path = joinpath(manifests, "smoke.toml")
        scope = VALIDATION_RUNNER_MODULE.validate_scope_manifest(
            TOML.parsefile(path),
            path,
            "smoke",
        )
        configuration =
            (; scope = "smoke", reference_mode = "pinned", workers = 1)
        report = VALIDATION_RUNNER_MODULE.initial_report(
            configuration,
            directory,
            scope,
            VALIDATION_RUNNER_MODULE.comparison_policy(),
        )
        coverage = report["model"][1]["coverage"]
        @test coverage["scope_cells"] == 37
        @test coverage["eligible_cells"] == 36
        @test coverage["compared_cells"] == 0
        @test coverage["eligibility_gaps"] == eligibility_gaps
    end
end

@testset "Validation Runner rejects unreviewed Eligibility Gaps" begin
    mktempdir() do directory
        manifests = write_smoke_scope_manifests(
            directory,
            [
                Dict(
                    "model" => "CASA-C",
                    "cell_id" => 51,
                    "reason" => "not reviewed",
                    "reviewed" => false,
                ),
            ],
        )

        path = joinpath(manifests, "smoke.toml")
        failure = try
            VALIDATION_RUNNER_MODULE.validate_scope_manifest(
                TOML.parsefile(path),
                path,
                "smoke",
            )
        catch error
            error
        end

        @test failure isa VALIDATION_RUNNER_MODULE.RunnerError
        @test occursin("unreviewed Eligibility Gap", sprint(showerror, failure))
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
            @test report["scope"]["manifest"] ==
                  abspath(joinpath(VALIDATION_SCOPE_MANIFESTS, "$scope.toml"))
            @test report["scope"]["manifest_sha256"] ==
                  bytes2hex(SHA.sha256(read(report["scope"]["manifest"])))
            @test report["comparison_policy"]["model"] == "CASA-C"
            @test report["comparison_policy"]["path"] ==
                  abspath(VALIDATION_COMPARISON_POLICY)
            @test report["comparison_policy"]["sha256"] == bytes2hex(
                SHA.sha256(read(report["comparison_policy"]["path"])),
            )
            @test report["comparison_policy"]["budget_rtol"] == 5.0e-12
            calibration = report["comparison_policy"]["calibration"]
            @test calibration["source"] == "fresh_fortran_full_grid"
            @test calibration["cell_count"] == 4263
            @test calibration["path"] == abspath(VALIDATION_CASA_C_CALIBRATION)
            @test calibration["sha256"] ==
                  bytes2hex(SHA.sha256(read(calibration["path"])))
            calibration_text = read(calibration["path"], String)
            @test !occursin("/Users/", calibration_text)
            @test !occursin("/tmp/", calibration_text)
            calibration_document = TOML.parse(calibration_text)
            provenance = calibration_document["source_provenance"]
            @test provenance["git_head_advanced_during_run"]
            @test provenance["execution_source_hashes_are_authoritative"]
            leaf =
                report["comparison_policy"]["fresh_fortran_boundary"]["prespin"]["casa_plant.c_leaf"]
            @test leaf["atol"] > 0
            @test leaf["rtol"] >= 0
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

@testset "Validation Runner stages the Representative Scope before simulation" begin
    mktempdir() do output
        result = run_validation(
            "--scope",
            "representative",
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
        @test occursin("Pinned CASA-C reference is missing", result.stderr)
        report = TOML.parsefile(joinpath(output, "validation_report.toml"))
        @test report["scope"]["name"] == "representative"
        @test report["scope"]["cell_count"] == 80
        @test length(unique(report["scope"]["cell_ids"])) == 80
        smoke =
            TOML.parsefile(joinpath(VALIDATION_SCOPE_MANIFESTS, "smoke.toml"))
        @test issubset(smoke["cell_ids"], report["scope"]["cell_ids"])
        representative = TOML.parsefile(
            joinpath(VALIDATION_SCOPE_MANIFESTS, "representative.toml"),
        )
        @test representative["selection"]["seed"] == 31432026
        @test representative["selection"]["inactive_candidates_excluded"]
        @test sum(
            values(representative["selection"]["candidate_population"]),
        ) == 2982
        @test occursin(
            "cellMissing == 0",
            representative["selection"]["candidate_filter"],
        )
        @test sum(values(representative["selection"]["allocation"])) == 43
        @test length(representative["selection"]["match"]) == 43
    end
end

@testset "Validation Runner binds Representative forcing to its Scope Manifest" begin
    mktempdir() do directory
        scope_path = joinpath(directory, "representative.toml")
        fixture_path = joinpath(directory, "fixture.toml")
        write(scope_path, "name = \"representative\"\n")
        scope = (; name = "representative", path = scope_path)
        open(fixture_path, "w") do io
            TOML.print(
                io,
                Dict("selection" => Dict("scope_manifest_sha256" => "stale")),
            )
        end

        failure = try
            VALIDATION_RUNNER_MODULE.validate_fixture_scope_provenance(
                fixture_path,
                scope,
            )
        catch error
            error
        end
        @test failure isa VALIDATION_RUNNER_MODULE.RunnerError
        @test occursin("frozen Scope Manifest", sprint(showerror, failure))

        fixture = TOML.parsefile(fixture_path)
        fixture["selection"]["scope_manifest_sha256"] =
            bytes2hex(SHA.sha256(read(scope_path)))
        open(fixture_path, "w") do io
            TOML.print(io, fixture; sorted = true)
        end
        @test isnothing(
            VALIDATION_RUNNER_MODULE.validate_fixture_scope_provenance(
                fixture_path,
                scope,
            ),
        )
    end
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
    @test occursin(
        "only one of CASA-C or CASA-CN is available",
        defaults.stderr,
    )

    invalid = run_validation("--scope", "unknown")
    @test invalid.exitcode == 2
    @test occursin("scope must be one of", invalid.stderr)

    invalid = run_validation("--scope", "core", "--workers", "0")
    @test invalid.exitcode == 2
    @test occursin("workers must be positive", invalid.stderr)
end

@testset "Validation Runner enforces its hard process deadline" begin
    mktempdir() do output
        result = run_validation(
            "--scope",
            "core",
            "--models",
            "CASA-C",
            "--output",
            output;
            environment = Dict(
                "CLIMALAND_VALIDATION_TIMEOUT_SECONDS" => "0.05",
            ),
        )

        @test result.exitcode == 124
        @test occursin("hard timeout", result.stderr)
        report = TOML.parsefile(joinpath(output, "validation_report.toml"))
        @test report["outcome"] == "timed_out"
        @test report["model"][1]["outcome"] == "timed_out"
        @test report["timeout"]["expired"]
        @test report["timeout"]["limit_seconds"] == 0.05
    end
end

@testset "Validation Runner fails closed before CASA-C simulation" begin
    mktempdir() do directory
        policy_path = joinpath(directory, "comparison_policy.toml")
        calibration_path =
            joinpath(directory, "casa_c_full_grid_calibration.toml")
        cp(VALIDATION_COMPARISON_POLICY, policy_path)
        obsolete = TOML.parsefile(VALIDATION_CASA_C_CALIBRATION)
        obsolete["method"]["raw_absolute"] = "a(r) = max(5e-10, max_i(e_i - r*x_i))"
        open(calibration_path, "w") do io
            TOML.print(io, obsolete; sorted = true)
        end
        error = try
            VALIDATION_RUNNER_MODULE.comparison_policy("CASA-C"; path = policy_path)
            nothing
        catch exception
            exception
        end
        @test error isa VALIDATION_RUNNER_MODULE.RunnerError
        @test occursin("obsolete absolute floor", error.message)
    end

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

@testset "Validation Runner accepts explicit CASA-CN and fails closed" begin
    mktempdir() do output
        missing = joinpath(output, "missing-reference.toml")
        result = run_validation(
            "--scope",
            "core",
            "--models",
            "CASA-CN",
            "--output",
            output;
            environment = Dict(
                "CLIMALAND_VALIDATION_CASA_CN_REFERENCE" => missing,
            ),
        )

        @test result.exitcode == 2
        @test occursin("Pinned CASA-CN reference is missing", result.stderr)
        report = TOML.parsefile(joinpath(output, "validation_report.toml"))
        @test report["model"][1]["name"] == "CASA-CN"
        @test report["model"][1]["coverage"]["compared_cells"] == 0
        @test !isdir(joinpath(output, "CASA-CN", "stages"))
    end
end

@testset "Validation Runner completes pinned Core and Smoke comparisons" begin
    for (scope, cell_count) in (("core", 11), ("smoke", 37))
        mktempdir() do output
            result = run_validation(
                "--scope",
                scope,
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
            @test report["scope"]["name"] == scope
            @test report["scope"]["cell_count"] == cell_count
            @test report["model"][1]["name"] == "CASA-C"
            @test report["model"][1]["coverage"]["compared_cells"] == cell_count
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
            scientific = TOML.parsefile(report["model"][1]["comparison_report"])
            applied =
                scientific["boundary_comparison"]["prespin"]["source"]["fresh_fortran"]["variable"]["casa_plant.c_leaf"]
            policy =
                report["comparison_policy"]["fresh_fortran_boundary"]["prespin"]["casa_plant.c_leaf"]
            @test applied["atol"] == policy["atol"]
            @test applied["rtol"] == policy["rtol"]
            @test report["outcome"] == "passed"
        end
    end
end

if get(ENV, "CLIMALAND_RUN_REPRESENTATIVE_VALIDATION", "false") == "true"
    @testset "Validation Runner completes pinned Representative CASA-CN" begin
        mktempdir() do output
            result = run_validation(
                "--scope",
                "representative",
                "--models",
                "CASA-CN",
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
            model = only(report["model"])
            @test model["name"] == "CASA-CN"
            @test report["comparison_policy"]["id"] ==
                  "casa-representative-validation-v3"
            @test report["comparison_policy"]["budget_rtol"] == 1.2e-11
            @test occursin(
                "1.05 safety margin",
                report["comparison_policy"]["budget_rtol_method"],
            )
            @test model["coverage"]["scope_cells"] == 80
            @test model["coverage"]["compared_cells"] == 80
            @test model["outcome"] == "passed"
            @test all(values(model["comparison"]))
            @test haskey(model["budget"], "carbon")
            @test haskey(model["budget"], "nitrogen")
            @test model["budget"]["carbon"]["reducer"] ==
                  "maximum_absolute_residual"
            @test model["budget"]["nitrogen"]["reducer"] ==
                  "maximum_absolute_residual"
            @test model["historical"]["annual"]["all_match"]
            @test model["historical"]["fixed_daily_samples"]["all_match"]
            @test model["historical"]["fresh_fortran_daily"]["all_match"]
            @test length(
                model["historical"]["fresh_fortran_daily"]["sample_days"],
            ) == 56
            @test report["comparison_policy"]["fixed_daily_samples"]["sample_count_per_variable_cell"] ==
                  84
            @test report["comparison_policy"]["annual_reducers"]["state_pool"]["reducers"] ==
                  ["annual_mean", "end_of_year"]
            @test report["comparison_policy"]["invalid_oracle_variables"]["nLitInptStruc"]["kind"] ==
                  "variable_level"
            daily_gap =
                report["comparison_policy"]["invalid_oracle_windows"]["fresh_fortran_fixed_daily"]
            @test daily_gap["kind"] == "time_window"
            @test daily_gap["missing_years"] == [1957]
            @test daily_gap["comparison"] == "missing_window_native_julia_only"
            policy_document = TOML.parsefile(VALIDATION_COMPARISON_POLICY)
            for rule in (
                "fresh_fortran_boundary",
                "fresh_fortran_annual",
                "fresh_fortran_daily",
            )
                @test !haskey(policy_document["model"]["CASA-CN"][rule], "atol")
                @test !haskey(policy_document["model"]["CASA-CN"][rule], "rtol")
            end
            scientific = TOML.parsefile(model["comparison_report"])
            applied =
                scientific["historical_comparison"]["annual"]["source"]["fresh_fortran"]["reducers"]["annual_mean"]["variable"]["casa_plant.c_leaf"]
            policy =
                report["comparison_policy"]["fresh_fortran_annual"]["annual_mean"]["casa_plant.c_leaf"]
            @test applied["atol"] == policy["atol"]
            @test applied["rtol"] == policy["rtol"]
            daily_applied =
                model["historical"]["fresh_fortran_daily"]["variable"]["casa_plant.c_leaf"]
            daily_policy =
                report["comparison_policy"]["fresh_fortran_historical"]["casa_plant.c_leaf"]
            @test daily_applied["atol"] == daily_policy["atol"]
            @test daily_applied["rtol"] == daily_policy["rtol"]
        end
    end

    @testset "Validation Runner aggregates a CASA-CN scientific failure" begin
        pinned, _ =
            VALIDATION_RUNNER_MODULE.reference_path("representative", "CASA-CN")
        reference = TOML.parsefile(pinned)
        incomplete = deepcopy(reference)
        delete!(
            incomplete["configuration"]["carbon_nitrogen"]["native_julia"]["historical"],
            "diagnostic.n_litter_structural_input",
        )
        scope = VALIDATION_RUNNER_MODULE.load_scope_manifests("representative")
        @test_throws VALIDATION_RUNNER_MODULE.RunnerError VALIDATION_RUNNER_MODULE.validate_eligible_reference_values(
            incomplete,
            scope,
            "CASA-CN",
        )
        nonfinite = deepcopy(reference)
        nonfinite["configuration"]["carbon_nitrogen"]["fresh_fortran"]["boundary"]["prespin"]["casa_plant.c_leaf"][1] =
            Inf
        nonfinite_error = try
            VALIDATION_RUNNER_MODULE.validate_eligible_reference_values(
                nonfinite,
                scope,
                "CASA-CN",
            )
            nothing
        catch error
            error
        end
        @test nonfinite_error isa VALIDATION_RUNNER_MODULE.RunnerError
        @test occursin("carbon_nitrogen.fresh_fortran", nonfinite_error.message)
        invalid_provenance = deepcopy(reference)
        invalid_provenance["configuration"]["carbon_nitrogen"]["provenance"]["fresh_fortran_daily_sha256"]["2014"] = "not-a-sha256"
        provenance_error = try
            VALIDATION_RUNNER_MODULE.validate_eligible_reference_values(
                invalid_provenance,
                scope,
                "CASA-CN",
            )
            nothing
        catch error
            error
        end
        @test provenance_error isa VALIDATION_RUNNER_MODULE.RunnerError
        @test occursin("daily provenance", provenance_error.message)
        invalid_forcing = deepcopy(reference)
        invalid_forcing["configuration"]["carbon_nitrogen"]["provenance"]["forcing_artifact_git_tree_sha1"] = "0000000000000000000000000000000000000000"
        forcing_error = try
            VALIDATION_RUNNER_MODULE.validate_reference_forcing_artifact(
                invalid_forcing,
                "836b4cda5912f1bea5f27abd326789285b02ed46",
                "CASA-CN",
                scope,
            )
            nothing
        catch error
            error
        end
        @test forcing_error isa VALIDATION_RUNNER_MODULE.RunnerError
        @test occursin("Representative forcing artifact", forcing_error.message)
        stale_calibration = deepcopy(reference)
        stale_calibration["configuration"]["carbon_nitrogen"]["provenance"]["fresh_fortran_calibration_sha256"] = "0000000000000000000000000000000000000000000000000000000000000000"
        calibration_error = try
            VALIDATION_RUNNER_MODULE.validate_reference_calibration(
                stale_calibration,
                joinpath(
                    @__DIR__,
                    "validation",
                    "casa_cn_full_grid_calibration.toml",
                ),
                "CASA-CN",
                scope,
            )
            nothing
        catch error
            error
        end
        @test calibration_error isa VALIDATION_RUNNER_MODULE.RunnerError
        @test occursin(
            "current full-grid calibration",
            calibration_error.message,
        )
        leaf =
            reference["configuration"]["carbon_nitrogen"]["fresh_fortran"]["boundary"]["prespin"]["casa_plant.c_leaf"]
        leaf[1] += 1.0e6
        mktempdir() do directory
            altered = joinpath(directory, "altered-reference.toml")
            open(altered, "w") do io
                TOML.print(io, reference; sorted = true)
            end
            output = joinpath(directory, "output")
            result = run_validation(
                "--scope",
                "core",
                "--models",
                "CASA-CN",
                "--reference",
                "pinned",
                "--workers",
                "1",
                "--output",
                output;
                environment = Dict(
                    "CLIMALAND_VALIDATION_CASA_CN_REFERENCE" => altered,
                ),
            )

            @test result.exitcode == 1
            report = TOML.parsefile(joinpath(output, "validation_report.toml"))
            model = only(report["model"])
            @test model["coverage"]["compared_cells"] == 11
            @test model["outcome"] == "failed"
            @test !model["comparison"]["fresh_fortran_boundaries"]
            @test report["outcome"] == "failed"
        end
    end
end
