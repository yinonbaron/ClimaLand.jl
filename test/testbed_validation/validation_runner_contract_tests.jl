using Test
import TOML

include(joinpath(@__DIR__, "validation_runner.jl"))
const ContractRunner = TestbedValidationRunner
const CONTRACT_SCOPE_PATH =
    joinpath(@__DIR__, "validation", "scopes", "representative.toml")

function run_injected_representative(model, passed)
    return mktempdir() do directory
        output = joinpath(directory, "output")
        reference = joinpath(directory, "reference")
        if model == "CORPSE"
            mkpath(reference)
        else
            open(reference, "w") do io
                TOML.print(io, Dict("schema_version" => 1))
            end
        end
        scope = TOML.parsefile(CONTRACT_SCOPE_PATH)
        fixture = joinpath(directory, "fixture.toml")
        open(fixture, "w") do io
            TOML.print(
                io,
                Dict(
                    "selection" => Dict(
                        "scope_manifest_sha256" =>
                            ContractRunner.sha256sum(CONTRACT_SCOPE_PATH),
                    ),
                ),
            )
        end
        corpse_runner = function (root; kwargs...)
            mkpath(root)
            scientific_path = joinpath(root, "scientific.toml")
            stages = Dict(
                name => Dict(
                    "comparison" => Dict(
                        "state" => Dict("all_match" => passed),
                    ),
                ) for name in
                ("prespin", "spin", "spin_continuation", "historical")
            )
            open(scientific_path, "w") do io
                TOML.print(
                    io,
                    Dict(
                        "stage" => stages,
                        "reduced_historical" => Dict(
                            "annual" => Dict(
                                "state" => Dict("all_match" => passed),
                            ),
                            "daily" => Dict(
                                "state" => Dict("all_match" => passed),
                            ),
                        ),
                        "budget" => Dict("verified" => passed),
                        "calibration" => Dict(
                            "id" => "corpse-c-representative-fresh-fortran-v1",
                            "sha256" => repeat("a", 64),
                        ),
                    );
                    sorted = true,
                )
            end
            gaps = filter(
                gap -> gap["model"] == "CORPSE",
                get(scope, "eligibility_gaps", Any[]),
            )
            return (;
                passed,
                report = scientific_path,
                seconds = 0.01,
                coverage = Dict(
                    "scope_cells" => 80,
                    "eligible_cells" => 78,
                    "compared_cells" => 78,
                    "eligibility_gaps" => gaps,
                ),
            )
        end
        mimics_runner = function (report, args...)
            model_report = only(report["model"])
            model_report["coverage"]["compared_cells"] = 80
            model_report["comparison"] = Dict(
                "fresh_fortran_boundaries" => passed,
                "historical" => passed,
                "carbon_budget" => passed,
                "nitrogen_budget" => passed,
            )
            model_report["outcome"] = passed ? "passed" : "failed"
            model_report["seconds"] = 0.01
            report["outcome"] = model_report["outcome"]
            report["seconds"] = 0.01
            return passed
        end
        exitcode = redirect_stdout(devnull) do
            redirect_stderr(devnull) do
                ContractRunner.main(
                    [
                        "--scope",
                        "representative",
                        "--models",
                        model,
                        "--reference",
                        "pinned",
                        "--workers",
                        "1",
                        "--output",
                        output,
                    ];
                    reference_resolver = (_, selected_model) -> (
                        reference,
                        selected_model == "CORPSE" ? repeat("a", 40) : nothing,
                    ),
                    fixture_resolver = (_, _) -> (fixture, nothing),
                    corpse_forcing_resolver = () ->
                        (directory, repeat("b", 40)),
                    corpse_runner,
                    mimics_runner,
                )
            end
        end
        return exitcode,
        TOML.parsefile(joinpath(output, "validation_report.toml"))
    end
end

@testset "Validation Runner accepts reports only from successful workers" begin
    configuration = ContractRunner.parse_args(["--models", "CORPSE"])
    scope = ContractRunner.load_scope_manifests("representative")
    mktempdir() do output
        report =
            ContractRunner.empty_aggregate_report(configuration, output, scope)
        stale = deepcopy(report)
        only(stale["model"])["outcome"] = "passed"
        outcomes = [(
            model = "CORPSE",
            outcome = "failed",
            exitcode = 1,
            signal = 0,
            seconds = 0.1,
            error = nothing,
        )]

        ContractRunner.aggregate_model_reports!(
            report,
            Dict("CORPSE" => stale),
            outcomes,
            0.1,
        )

        @test report["outcome"] == "failed"
        @test only(report["model"])["outcome"] == "failed"
    end

    mktempdir() do output
        report =
            ContractRunner.empty_aggregate_report(configuration, output, scope)
        outcomes = [(
            model = "CORPSE",
            outcome = "passed",
            exitcode = 0,
            signal = 0,
            seconds = 0.1,
            error = nothing,
        )]

        ContractRunner.aggregate_model_reports!(
            report,
            Dict{String, Any}(),
            outcomes,
            0.1,
        )

        @test report["outcome"] == "failed"
        @test only(report["model"])["outcome"] == "failed"
        @test occursin(
            "current validation report",
            only(report["model"])["error"],
        )
    end
end

@testset "Validation Runner removes reports from prior invocations" begin
    configuration = ContractRunner.parse_args(["--models", "CORPSE"])
    scope = ContractRunner.load_scope_manifests("representative")
    mktempdir() do output
        stale_path =
            joinpath(output, "models", "CORPSE", ContractRunner.REPORT_FILENAME)
        mkpath(dirname(stale_path))
        open(stale_path, "w") do io
            TOML.print(io, Dict("outcome" => "passed"))
        end
        report =
            ContractRunner.empty_aggregate_report(configuration, output, scope)
        worker_runner =
            function (command; models, workers, worker_log_directory)
                @test !isfile(stale_path)
                return (;
                    outcomes = [(
                        model = "CORPSE",
                        outcome = "passed",
                        exitcode = 0,
                        signal = 0,
                        seconds = 0.1,
                        error = nothing,
                    )],
                )
            end

        @test !ContractRunner.run_multiple!(
            report,
            output,
            configuration,
            scope;
            fixture_resolver = (_, _) -> ("fixture", nothing),
            reference_resolver = (_, _) -> ("reference", nothing),
            worker_runner,
        )
        @test report["outcome"] == "failed"
        @test occursin(
            "current validation report",
            only(report["model"])["error"],
        )
    end
end

@testset "Validation Runner reports model policy and performance advice" begin
    configuration = ContractRunner.parse_args([
        "--scope",
        "representative",
        "--models",
        "CASA-C",
    ])
    scope = ContractRunner.load_scope_manifests("representative")
    report = ContractRunner.initial_report(
        configuration,
        "/tmp/validation-policy-test",
        scope,
        ContractRunner.comparison_policy("CASA-C"),
    )
    @test only(report["model"])["comparison_policy"]["sha256"] ==
          report["comparison_policy"]["sha256"]

    aggregate_configuration = ContractRunner.parse_args(String[])
    aggregate = ContractRunner.empty_aggregate_report(
        aggregate_configuration,
        "/tmp/validation-policy-aggregate",
        scope,
    )
    model_reports = Dict(
        model => Dict(
            "model" => [
                merge(
                    deepcopy(aggregate["model"][index]),
                    Dict(
                        "outcome" => "passed",
                        "comparison_policy" =>
                            Dict("id" => "policy-$model"),
                    ),
                ),
            ],
        ) for (index, model) in enumerate(ContractRunner.MODELS)
    )
    outcomes = [
        (;
            model,
            outcome = "passed",
            exitcode = 0,
            signal = 0,
            seconds = 0.1,
            error = nothing,
        ) for model in ContractRunner.MODELS
    ]
    ContractRunner.aggregate_model_reports!(
        aggregate,
        model_reports,
        outcomes,
        0.5,
    )
    @test getindex.(getindex.(aggregate["model"], "comparison_policy"), "id") ==
          ["policy-$model" for model in ContractRunner.MODELS]

    messages = IOBuffer()
    report["outcome"] = "passed"
    @test ContractRunner.annotate_performance_budget!(
        report,
        3600.1;
        io = messages,
    )
    @test report["outcome"] == "passed"
    @test report["performance_budget"]["exceeded"]
    @test occursin("::warning::", String(take!(messages)))
end

@testset "Validation Runner reports injected Representative model outcomes" begin
    for model in ("CORPSE", "MIMICS-C", "MIMICS-CN")
        exitcode, report = run_injected_representative(model, true)
        result = only(report["model"])
        @test exitcode == 0
        @test result["outcome"] == "passed"
        @test result["coverage"]["compared_cells"] ==
              (model == "CORPSE" ? 78 : 80)
        @test length(result["coverage"]["eligibility_gaps"]) ==
              (model == "CORPSE" ? 2 : 0)
        @test haskey(result, "comparison_policy")

        exitcode, report = run_injected_representative(model, false)
        @test exitcode == 1
        @test report["outcome"] == "failed"
        @test only(report["model"])["outcome"] == "failed"
    end
end
