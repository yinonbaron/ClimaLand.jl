using Test
import Pkg
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

function fake_validation_fresh_commands(audit_directory)
    project = dirname(Base.active_project())
    script = joinpath(@__DIR__, "fake_fresh_reference_process.jl")
    scope_sha256 = bytes2hex(
        SHA.sha256(
            read(joinpath(VALIDATION_SCOPE_MANIFESTS, "representative.toml")),
        ),
    )
    build =
        build_directory ->
            `$(Base.julia_cmd()) --startup-file=no --project=$project $script build $build_directory $audit_directory pass`
    worker =
        (model, run_directory, build_directory) ->
            `$(Base.julia_cmd()) --startup-file=no --project=$project $script worker $model $run_directory $build_directory $audit_directory pass $scope_sha256`
    return (; build, worker, preflight = _ -> nothing)
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

@testset "CASA-CN scientific outcome gates on Fortran evidence" begin
    boundary_comparison = Dict(
        stage => Dict(
            "source" => Dict(
                "fresh_fortran" => Dict("all_match" => true),
                "native_julia" => Dict("all_match" => false),
            ),
        ) for stage in
        ("prespin", "accelerated_spin", "normal_spin", "historical")
    )
    report = Dict(
        "initialization_comparison" => Dict("all_match" => true),
        "boundary_comparison" => boundary_comparison,
        "carbon_budget" => Dict("all_close" => true),
        "nitrogen_budget" => Dict("all_close" => true),
        "passive_restoration" => Dict(
            "verified" => true,
            "unaffected_verified" => true,
            "checkpoint_roundtrip_verified" => true,
        ),
        "historical_comparison" => Dict(
            "all_match" => false,
            "annual" => Dict(
                "all_match" => false,
                "source" => Dict(
                    "fresh_fortran" => Dict("all_match" => true),
                    "native_julia" => Dict("all_match" => false),
                ),
            ),
            "fixed_daily_samples" => Dict("all_match" => false),
            "fresh_fortran_daily" => Dict("all_match" => true),
        ),
    )
    result = (; stages = [(; checkpoint_roundtrip_verified = true)])
    fresh_fortran_daily = report["historical_comparison"]["fresh_fortran_daily"]

    native_only_failure = VALIDATION_RUNNER_MODULE.scientific_outcome(
        report,
        result,
        "CASA-CN";
        fresh_fortran_daily,
    )
    @test native_only_failure.passed
    @test native_only_failure.checks["annual_reducers_and_daily_samples"]
    @test native_only_failure.checks["fresh_fortran_daily"]
    @test !report["historical_comparison"]["all_match"]
    @test !report["historical_comparison"]["fixed_daily_samples"]["all_match"]

    report["nitrogen_budget"]["all_close"] = false
    local_budget_failure = VALIDATION_RUNNER_MODULE.scientific_outcome(
        report,
        result,
        "CASA-CN";
        fresh_fortran_daily,
    )
    deferred_budget = VALIDATION_RUNNER_MODULE.scientific_outcome(
        report,
        result,
        "CASA-CN";
        fresh_fortran_daily,
        defer_budgets = true,
    )
    @test !local_budget_failure.passed
    @test deferred_budget.passed
    @test !deferred_budget.checks["nitrogen_budget"]
    report["nitrogen_budget"]["all_close"] = true

    report["historical_comparison"]["annual"]["source"]["fresh_fortran"]["all_match"] =
        false
    failed_annual = VALIDATION_RUNNER_MODULE.scientific_outcome(
        report,
        result,
        "CASA-CN";
        fresh_fortran_daily,
    )
    @test !failed_annual.passed
    @test !failed_annual.checks["annual_reducers_and_daily_samples"]

    report["historical_comparison"]["annual"]["source"]["fresh_fortran"]["all_match"] =
        true
    report["historical_comparison"]["fresh_fortran_daily"]["all_match"] = false
    failed_daily = VALIDATION_RUNNER_MODULE.scientific_outcome(
        report,
        result,
        "CASA-CN";
        fresh_fortran_daily,
    )
    @test !failed_daily.passed
    @test !failed_daily.checks["annual_reducers_and_daily_samples"]
    @test !failed_daily.checks["fresh_fortran_daily"]

    fresh_fortran_daily["all_match"] = true
    for malformed in (
        Dict{String, Any}(),
        Dict("prespin" => boundary_comparison["prespin"]),
        Dict("unexpected" => boundary_comparison["prespin"]),
    )
        report["boundary_comparison"] = malformed
        incomplete_boundaries = VALIDATION_RUNNER_MODULE.scientific_outcome(
            report,
            result,
            "CASA-CN";
            fresh_fortran_daily,
        )
        @test !incomplete_boundaries.passed
        @test !incomplete_boundaries.checks["fresh_fortran_boundaries"]
    end
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

@testset "Validation Runner exposes stable defaults and rejects invalid values" begin
    defaults = VALIDATION_RUNNER_MODULE.parse_args(String[])
    @test defaults.scope == "representative"
    @test defaults.models == collect(VALIDATION_RUNNER_MODULE.MODELS)
    @test defaults.reference_mode == "pinned"
    @test isnothing(defaults.shard_index)
    @test isnothing(defaults.shard_count)

    invalid = run_validation("--scope", "unknown")
    @test invalid.exitcode == 2
    @test occursin("scope must be one of", invalid.stderr)

    invalid = run_validation("--scope", "core", "--workers", "0")
    @test invalid.exitcode == 2
    @test occursin("workers must be positive", invalid.stderr)
end

@testset "Validation Runner exposes deterministic Representative shards" begin
    scope = VALIDATION_RUNNER_MODULE.load_scope_manifests("representative")
    shards = [
        VALIDATION_RUNNER_MODULE.parse_args([
            "--models",
            "CASA-C",
            "--shard-index",
            string(index),
            "--shard-count",
            "8",
        ]) for index in 1:8
    ]
    assigned = [
        VALIDATION_RUNNER_MODULE.execution_selection(scope, "CASA-C", config).cell_ids for config in shards
    ]

    @test all(length(ids) == 10 for ids in assigned)
    @test sort(reduce(vcat, assigned)) == scope.cell_ids
    @test all(
        isempty(intersect(assigned[left], assigned[right])) for left in 1:8 for
        right in (left + 1):8
    )
    @test assigned[1] == scope.cell_ids[1:8:end]

    for args in (
        ["--models", "CASA-C", "--shard-index", "1"],
        ["--models", "CASA-C", "--shard-count", "8"],
        ["--models", "CASA-C", "--shard-index", "0", "--shard-count", "8"],
        ["--models", "CASA-C", "--shard-index", "9", "--shard-count", "8"],
        ["--models", "CASA-C", "--shard-index", "1", "--shard-count", "0"],
        ["--models", "CASA-C", "--shard-index", "1", "--shard-count", "81"],
    )
        @test_throws VALIDATION_RUNNER_MODULE.RunnerError VALIDATION_RUNNER_MODULE.parse_args(
            args,
        )
    end

    for args in (
        [
            "--scope",
            "core",
            "--models",
            "CASA-C",
            "--shard-index",
            "1",
            "--shard-count",
            "8",
        ],
        [
            "--models",
            "CASA-C,CASA-CN",
            "--shard-index",
            "1",
            "--shard-count",
            "8",
        ],
        [
            "--models",
            "CASA-C",
            "--reference",
            "fresh",
            "--shard-index",
            "1",
            "--shard-count",
            "8",
        ],
    )
        config = VALIDATION_RUNNER_MODULE.parse_args(args)
        @test_throws VALIDATION_RUNNER_MODULE.RunnerError VALIDATION_RUNNER_MODULE.validate_available(
            config,
        )
    end
end

@testset "Validation Runner reports shard-local coverage with canonical provenance" begin
    scope = VALIDATION_RUNNER_MODULE.load_scope_manifests("representative")
    configuration = VALIDATION_RUNNER_MODULE.parse_args([
        "--models",
        "CORPSE",
        "--shard-index",
        "1",
        "--shard-count",
        "8",
    ])
    mktempdir() do output
        report = VALIDATION_RUNNER_MODULE.empty_aggregate_report(
            configuration,
            output,
            scope,
        )
        model = only(report["model"])

        @test report["comparison_schema"] ==
              "representative-pinned-comparison-v1"
        @test report["scope"]["cell_count"] == 80
        @test report["scope"]["manifest_sha256"] ==
              VALIDATION_RUNNER_MODULE.sha256sum(scope.path)
        @test report["shard"] == Dict(
            "schema_version" => 1,
            "index" => 1,
            "count" => 8,
            "cell_ids" => scope.cell_ids[1:8:end],
            "strategy" => "scope-order-round-robin-v1",
        )
        @test model["coverage"]["scope_cells"] == 10
        @test model["coverage"]["eligible_cells"] == 9
        @test only(model["coverage"]["eligibility_gaps"])["cell_id"] == 51
    end
end
@testset "Validation Runner aggregates deterministic model reports" begin

    configuration =
        VALIDATION_RUNNER_MODULE.parse_args(["--models", "MIMICS-C,CASA-C"])
    scope = VALIDATION_RUNNER_MODULE.load_scope_manifests("representative")
    mktempdir() do output
        report = VALIDATION_RUNNER_MODULE.empty_aggregate_report(
            configuration,
            output,
            scope,
        )
        model_reports = Dict(
            model => Dict(
                "model" => [
                    merge(
                        deepcopy(
                            only(
                                filter(
                                    item -> item["name"] == model,
                                    report["model"],
                                ),
                            ),
                        ),
                        Dict("outcome" => "passed", "seconds" => 1.0),
                    ),
                ],
            ) for model in configuration.models
        )
        outcomes = [
            (;
                model,
                outcome = "passed",
                exitcode = 0,
                signal = 0,
                seconds = 1.0,
                error = nothing,
            ) for model in configuration.models
        ]

        VALIDATION_RUNNER_MODULE.aggregate_model_reports!(
            report,
            model_reports,
            outcomes,
            2.0,
        )

        @test report["outcome"] == "passed"
        @test getindex.(report["model"], "name") == configuration.models
        @test report["seconds"] == 2.0
    end
end

@testset "Validation Runner dispatches fresh mode through process orchestration" begin
    unsupported = VALIDATION_RUNNER_MODULE.parse_args([
        "--scope",
        "core",
        "--models",
        "CASA-C",
        "--reference",
        "fresh",
    ])
    @test_throws VALIDATION_RUNNER_MODULE.RunnerError begin
        VALIDATION_RUNNER_MODULE.validate_available(unsupported)
    end
    withenv(VALIDATION_RUNNER_MODULE.FRESH_SOURCE_OVERRIDE => nothing) do
        @test_throws VALIDATION_RUNNER_MODULE.RunnerError begin
            VALIDATION_RUNNER_MODULE.configured_fresh_commands(["MIMICS-C"])
        end
    end
    mktempdir() do directory
        audit = joinpath(directory, "audit")
        output = joinpath(directory, "output")
        mkpath(audit)
        configuration = VALIDATION_RUNNER_MODULE.parse_args([
            "--scope",
            "representative",
            "--models",
            "all",
            "--reference",
            "fresh",
            "--workers",
            "3",
            "--output",
            output,
        ])
        scope = VALIDATION_RUNNER_MODULE.load_scope_manifests("representative")
        report = VALIDATION_RUNNER_MODULE.empty_aggregate_report(
            configuration,
            output,
            scope,
        )
        @test VALIDATION_RUNNER_MODULE.run_fresh!(
            report,
            output,
            configuration;
            commands = fake_validation_fresh_commands(audit),
        )
        @test TOML.parsefile(joinpath(audit, "build.toml"))["invocations"] == 1
        @test all(
            isfile(joinpath(audit, "$model.toml")) for
            model in VALIDATION_RUNNER_MODULE.MODELS
        )
        @test report["outcome"] == "passed"
        @test getindex.(report["model"], "name") == configuration.models
        @test all(model["outcome"] == "passed" for model in report["model"])
        @test all(
            model["coverage"]["compared_cells"] ==
            model["coverage"]["eligible_cells"] for model in report["model"]
        )
        @test all(haskey(model, "comparison") for model in report["model"])
        @test report["fresh_reference"]["cleaned_up"] === true
        @test report["fresh_reference"]["preserved_on_failure"] === false
        @test isempty(report["fresh_reference"]["eligibility_gap_proposals"])
        @test !haskey(report["fresh_reference"], "evidence_root")
        report_path = VALIDATION_RUNNER_MODULE.write_report(output, report)
        @test TOML.parsefile(report_path)["outcome"] == "passed"
    end

    mktempdir() do output
        result = run_validation(
            "--scope",
            "representative",
            "--models",
            "MIMICS-C",
            "--reference",
            "fresh",
            "--output",
            output,
        )
        @test result.exitcode == 2
        @test occursin(
            VALIDATION_RUNNER_MODULE.FRESH_SOURCE_OVERRIDE,
            result.stderr,
        )
        report = TOML.parsefile(joinpath(output, "validation_report.toml"))
        @test only(report["model"])["name"] == "MIMICS-C"
    end

    mktempdir() do output
        result = run_validation(
            "--scope",
            "representative",
            "--models",
            "CORPSE",
            "--reference",
            "pinned",
            "--output",
            output;
            environment = Dict(
                VALIDATION_RUNNER_MODULE.REFERENCE_OVERRIDE["CORPSE"] =>
                    joinpath(output, "missing-reference"),
            ),
        )
        @test result.exitcode == 2
        @test occursin("reference bundle is missing", result.stderr)
        @test isfile(joinpath(output, "validation_report.toml"))
    end
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

@testset "Validation Runner writes aggregate hard-timeout reports" begin
    mktempdir() do output
        args =
            ["--scope", "representative", "--models", "all", "--output", output]
        started_at = time()
        configuration = VALIDATION_RUNNER_MODULE.parse_args(args)
        scope = VALIDATION_RUNNER_MODULE.load_scope_manifests("representative")
        completed = VALIDATION_RUNNER_MODULE.empty_aggregate_report(
            merge(configuration, (; models = ["CORPSE"])),
            output,
            scope,
        )
        completed["outcome"] = "passed"
        only(completed["model"])["outcome"] = "passed"
        completed_path =
            joinpath(output, "models", "CORPSE", "validation_report.toml")
        mkpath(dirname(completed_path))
        open(completed_path, "w") do io
            TOML.print(io, completed; sorted = true)
        end
        log_directory = joinpath(output, "logs")
        mkpath(log_directory)
        write(joinpath(log_directory, "CORPSE.log"), "passed")
        write(joinpath(log_directory, "MIMICS-C.log"), "timed out")
        VALIDATION_RUNNER_MODULE.write_timeout_report(
            args,
            output,
            7200.0,
            started_at,
        )

        report = TOML.parsefile(joinpath(output, "validation_report.toml"))
        @test report["outcome"] == "timed_out"
        @test report["timeout"]["expired"]
        @test report["timeout"]["limit_seconds"] == 7200.0
        @test getindex.(report["model"], "name") ==
              collect(VALIDATION_RUNNER_MODULE.MODELS)
        @test report["model"][1]["outcome"] == "passed"
        @test all(
            model -> model["outcome"] == "timed_out",
            report["model"][2:end],
        )
        @test !isfile(joinpath(log_directory, "CORPSE.log"))
        @test isfile(joinpath(log_directory, "MIMICS-C.log"))

        VALIDATION_RUNNER_MODULE.write_timeout_report(
            args,
            output,
            7200.0,
            stat(completed_path).mtime + 1,
        )
        stale = TOML.parsefile(joinpath(output, "validation_report.toml"))
        @test all(model -> model["outcome"] == "timed_out", stale["model"])
    end
end

@testset "Validation Runner bounds process-tree termination" begin
    if !Sys.iswindows()
        mktempdir() do directory
            ready = joinpath(directory, "ready")
            script = "trap 'exit 0' TERM; (trap '' TERM; sleep 30) & touch '$ready'; wait"
            command = Cmd(`sh -c $script`; detach = true)
            process = run(ignorestatus(command); wait = false)
            @test timedwait(() -> isfile(ready), 2; pollint = 0.01) == :ok
            process_group = Base.Libc.getpid(process)
            started = time()
            VALIDATION_RUNNER_MODULE.terminate_process_tree(
                process;
                grace_seconds = 0.05,
            )
            @test process_exited(process)
            @test timedwait(
                () -> ccall(:kill, Cint, (Cint, Cint), -process_group, 0) != 0,
                1;
                pollint = 0.01,
            ) == :ok
            @test time() - started < 2
        end
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

@testset "Validation Runner accepts explicit MIMICS-CN and fails closed" begin
    mktempdir() do output
        missing = joinpath(output, "missing-reference.toml")
        result = run_validation(
            "--scope",
            "representative",
            "--models",
            "MIMICS-CN",
            "--output",
            output;
            environment = Dict(
                "CLIMALAND_VALIDATION_MIMICS_CN_REFERENCE" => missing,
            ),
        )

        @test result.exitcode == 2
        @test occursin("Pinned MIMICS-CN reference is missing", result.stderr)
        report = TOML.parsefile(joinpath(output, "validation_report.toml"))
        model = only(report["model"])
        @test model["name"] == "MIMICS-CN"
        @test model["coverage"]["scope_cells"] == 80
        @test model["coverage"]["compared_cells"] == 0
        @test model["comparison_policy"]["boundary_calibration_sha256"] ==
              bytes2hex(
            SHA.sha256(
                read(model["comparison_policy"]["boundary_calibration"]),
            ),
        )
        @test !isdir(joinpath(output, "MIMICS-CN", "stages"))
    end
end

@testset "Validation Runner accepts explicit MIMICS-C and fails closed" begin
    mktempdir() do output
        missing = joinpath(output, "missing-reference.toml")
        result = run_validation(
            "--scope",
            "representative",
            "--models",
            "MIMICS-C",
            "--output",
            output;
            environment = Dict(
                "CLIMALAND_VALIDATION_MIMICS_C_REFERENCE" => missing,
            ),
        )

        @test result.exitcode == 2
        @test occursin("Pinned MIMICS-C reference is missing", result.stderr)
        report = TOML.parsefile(joinpath(output, "validation_report.toml"))
        model = only(report["model"])
        @test model["name"] == "MIMICS-C"
        @test model["coverage"]["scope_cells"] == 80
        @test model["coverage"]["compared_cells"] == 0
        @test !isdir(joinpath(output, "MIMICS-C", "stages"))
    end
end

@testset "Validation Runner projects complete MIMICS evidence" begin
    budget(suffix) = Dict(
        "all_close" => true,
        "stage" => Dict("historical" => Dict("residual_$suffix" => -2.5)),
    )
    boundary = Dict(
        "prespin" => Dict(
            "all_match" => false,
            "cell_failures" =>
                [Dict("cell_id" => 51, "variables" => ["c_labile"])],
        ),
    )
    historical = Dict(
        "annual" => Dict("all_match" => true),
        "fixed_daily_samples" => Dict("all_match" => true),
        "budget" => Dict("all_match" => true),
    )
    scientific = Dict(
        "boundary_comparison" => boundary,
        "historical_comparison" => historical,
        "carbon_budget" => budget("kg_c"),
        "nitrogen_budget" => budget("kg_n"),
    )

    for model in ("MIMICS-C", "MIMICS-CN")
        projected = VALIDATION_RUNNER_MODULE.project_mimics_evidence!(
            Dict{String, Any}(),
            scientific,
            model,
        )
        @test projected["boundary_comparison"] == boundary
        @test projected["historical"]["annual"] == historical["annual"]
        @test projected["historical"]["fixed_daily_samples"] ==
              historical["fixed_daily_samples"]
        @test projected["historical"]["budget_comparison"] ==
              historical["budget"]
        @test projected["budget"]["carbon"]["maximum_absolute_residual_kg_c"] ==
              2.5
        @test haskey(projected["budget"], "nitrogen") == (model == "MIMICS-CN")
    end
end

@testset "Validation Runner projects durable CASA and CORPSE shard evidence" begin
    mktempdir() do directory
        report_path = joinpath(directory, "comparison.toml")
        write(report_path, "schema_version = 1\n")
        diagnostic = Dict("all_match" => true, "maximum_absolute_error" => 0.25)
        casa_scientific = Dict(
            "initialization_comparison" => diagnostic,
            "boundary_comparison" => Dict("prespin" => diagnostic),
            "historical_comparison" => Dict("annual" => diagnostic),
            "passive_restoration" => Dict(
                "multiplier" => 0.25,
                "verified" => true,
                "carbon" => Dict(
                    "before" => [1.0, 2.0],
                    "after" => [0.25, 0.5],
                    "verified" => true,
                ),
                "checkpoint_roundtrip_verified" => true,
            ),
        )
        casa = VALIDATION_RUNNER_MODULE.project_casa_evidence!(
            Dict{String, Any}(),
            casa_scientific,
            Dict("all_match" => true),
            report_path,
        )
        @test casa["boundary_comparison"] ==
              casa_scientific["boundary_comparison"]
        @test casa["historical"]["annual"] == diagnostic
        @test casa["historical"]["fresh_fortran_daily"]["all_match"]
        @test casa["shard_evidence"]["comparison_report_sha256"] ==
              VALIDATION_RUNNER_MODULE.sha256sum(report_path)
        @test casa["passive_restoration"]["carbon"] == Dict("verified" => true)
        @test !haskey(casa["passive_restoration"]["carbon"], "before")
        @test casa["shard_evidence"]["passive_restoration"]["carbon"]["before"] ==
              [1.0, 2.0]

        corpse_scientific = Dict(
            "stage" => Dict(
                "prespin" => Dict(
                    "comparison" => Dict("pool" => diagnostic),
                    "checkpoint_sha256" => repeat("a", 64),
                    "checkpoint_handoff_verified" => true,
                    "restart_transform_verified" => true,
                    "conservation_verified" => true,
                ),
            ),
            "reduced_historical" =>
                Dict("annual_summaries" => Dict("pool" => diagnostic)),
        )
        corpse = VALIDATION_RUNNER_MODULE.project_corpse_evidence!(
            Dict{String, Any}(),
            corpse_scientific,
            report_path,
        )
        @test corpse["boundary_comparison"]["prespin"]["pool"] == diagnostic
        @test corpse["reduced_historical"] ==
              corpse_scientific["reduced_historical"]
        @test corpse["shard_evidence"]["stage"]["prespin"]["checkpoint_sha256"] ==
              repeat("a", 64)
        @test corpse["shard_evidence"]["stage"]["prespin"]["restart_transform_verified"]
        @test corpse["shard_evidence"]["stage"]["prespin"]["conservation_verified"]
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

@testset "Validation Runner accepts repackaged Representative forcing" begin
    mktempdir() do forcing_root
        forcing_path = joinpath(forcing_root, "forcing.nc")
        write(forcing_path, "representative forcing")
        source_tree = bytes2hex(Pkg.GitTools.tree_hash(forcing_root))
        manifest = Dict(
            "files" => Dict(
                "forcing.nc" => bytes2hex(SHA.sha256(read(forcing_path))),
            ),
        )
        open(joinpath(forcing_root, "manifest.toml"), "w") do io
            TOML.print(io, manifest; sorted = true)
        end
        reference = Dict(
            "configuration" => Dict(
                "carbon_nitrogen" => Dict(
                    "provenance" => Dict(
                        "forcing_artifact_git_tree_sha1" => source_tree,
                    ),
                ),
            ),
        )
        @test isnothing(
            VALIDATION_RUNNER_MODULE.validate_reference_forcing_artifact(
                reference,
                forcing_root,
                "CASA-CN",
                (; name = "representative"),
            ),
        )
    end
end

if get(ENV, "CLIMALAND_RUN_MIMICS_CN_REPRESENTATIVE_VALIDATION", "false") ==
   "true"
    @testset "Validation Runner completes pinned Representative MIMICS-CN" begin
        mktempdir() do output
            result = run_validation(
                "--scope",
                "representative",
                "--models",
                "MIMICS-CN",
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
            @test model["name"] == "MIMICS-CN"
            @test model["coverage"]["scope_cells"] == 80
            @test model["coverage"]["eligible_cells"] == 80
            @test model["coverage"]["compared_cells"] == 80
            @test isempty(model["coverage"]["eligibility_gaps"])
            @test model["outcome"] == "passed"
            @test all(values(model["comparison"]))
            @test haskey(model, "boundary_comparison")
            @test haskey(model["historical"], "annual")
            @test haskey(model["historical"], "fixed_daily_samples")
            @test haskey(model["historical"], "budget_comparison")
            @test haskey(model["budget"], "carbon")
            @test haskey(model["budget"], "nitrogen")
            @test report["outcome"] == "passed"
        end
    end
end

if get(ENV, "CLIMALAND_RUN_MIMICS_C_REPRESENTATIVE_VALIDATION", "false") ==
   "true"
    @testset "Validation Runner completes pinned Representative MIMICS-C" begin
        mktempdir() do output
            result = run_validation(
                "--scope",
                "representative",
                "--models",
                "MIMICS-C",
                "--reference",
                "pinned",
                "--workers",
                "1",
                "--output",
                output,
            )

            @test result.exitcode == 0
            report = TOML.parsefile(joinpath(output, "validation_report.toml"))
            model = only(report["model"])
            @test model["coverage"]["compared_cells"] == 80
            @test isempty(model["coverage"]["eligibility_gaps"])
            @test model["outcome"] == "passed"
            @test all(values(model["comparison"]))
            @test haskey(model, "boundary_comparison")
            @test haskey(model["historical"], "annual")
            @test haskey(model["historical"], "fixed_daily_samples")
            @test haskey(model["historical"], "budget_comparison")
            @test haskey(model["budget"], "carbon")
        end
    end
end

if get(ENV, "CLIMALAND_RUN_REPRESENTATIVE_VALIDATION", "false") == "true"
    @testset "Validation Runner completes a pinned Representative CASA-C shard" begin
        mktempdir() do output
            result = run_validation(
                "--scope",
                "representative",
                "--models",
                "CASA-C",
                "--reference",
                "pinned",
                "--shard-index",
                "1",
                "--shard-count",
                "8",
                "--workers",
                "1",
                "--output",
                output,
            )
            @test result.exitcode == 0
            report = TOML.parsefile(joinpath(output, "validation_report.toml"))
            model = only(report["model"])
            scope =
                VALIDATION_RUNNER_MODULE.load_scope_manifests("representative")
            @test report["shard"]["cell_ids"] == scope.cell_ids[1:8:end]
            @test model["coverage"]["scope_cells"] == 10
            @test model["coverage"]["compared_cells"] == 10
            @test model["outcome"] == "passed"
            @test haskey(model, "boundary_comparison")
            @test haskey(model, "historical")
            @test haskey(model, "shard_evidence")
        end
    end


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
        fixture_manifest, _ = VALIDATION_RUNNER_MODULE.fixture_manifest_path(
            "representative",
            "CASA-CN",
        )
        forcing_root = dirname(fixture_manifest)
        invalid_forcing = deepcopy(reference)
        invalid_forcing["configuration"]["carbon_nitrogen"]["provenance"]["forcing_artifact_git_tree_sha1"] = "0000000000000000000000000000000000000000"
        forcing_error = try
            VALIDATION_RUNNER_MODULE.validate_reference_forcing_artifact(
                invalid_forcing,
                forcing_root,
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
