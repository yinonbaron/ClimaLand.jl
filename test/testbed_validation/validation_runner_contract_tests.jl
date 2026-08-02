using Test
import TOML

include(joinpath(@__DIR__, "validation_runner.jl"))
const ContractRunner = TestbedValidationRunner
const CONTRACT_SCOPE_PATH =
    joinpath(@__DIR__, "validation", "scopes", "representative.toml")

function write_contract_forcing_bundle(root)
    mkpath(root)
    fixture_path = joinpath(root, "fixture.toml")
    open(fixture_path, "w") do io
        TOML.print(
            io,
            Dict(
                "schema_version" => 1,
                "selection" => Dict(
                    "scope_manifest_sha256" =>
                        ContractRunner.sha256sum(CONTRACT_SCOPE_PATH),
                    "representative_cell_ids" =>
                        Int.(TOML.parsefile(CONTRACT_SCOPE_PATH)["cell_ids"],),
                ),
            );
            sorted = true,
        )
    end
    manifest = Dict(
        "schema_version" => 1,
        "kind" => "forcing",
        "scope" => "representative",
        "files" =>
            Dict("fixture.toml" => ContractRunner.sha256sum(fixture_path)),
        "payload" => Dict("fixture_manifest" => "fixture.toml"),
        "provenance" => Dict(
            "scope_manifest_sha256" =>
                ContractRunner.sha256sum(CONTRACT_SCOPE_PATH),
            "forcing_sha256" => Dict("forcing.nc" => repeat("a", 64)),
            "shared_parameter_sha256" =>
                Dict("parameters.toml" => repeat("b", 64)),
            "comparison_schema" => "reduced-comparison-oracle-v1",
        ),
    )
    open(joinpath(root, "manifest.toml"), "w") do io
        TOML.print(io, manifest; sorted = true)
    end
    return root
end

function run_injected_representative(model, passed)
    return mktempdir() do directory
        output = joinpath(directory, "output")
        reference = joinpath(directory, "reference")
        forcing = write_contract_forcing_bundle(joinpath(directory, "forcing"))
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
                        (forcing, repeat("b", 40)),
                    corpse_runner,
                    mimics_runner,
                )
            end
        end
        return exitcode,
        TOML.parsefile(joinpath(output, "validation_report.toml")),
        ContractRunner.sha256sum(joinpath(forcing, "manifest.toml"))
    end
end

@testset "Validation Runner accepts an explicit CORPSE forcing bundle" begin
    mktempdir() do directory
        forcing = write_contract_forcing_bundle(joinpath(directory, "forcing"))
        withenv("CLIMALAND_VALIDATION_CORPSE_FORCING" => forcing) do
            root, artifact = ContractRunner.representative_forcing_directory()
            @test root == abspath(forcing)
            @test isnothing(artifact)
            metadata = ContractRunner.corpse_forcing_metadata(root, artifact)
            @test metadata["manifest_sha256"] ==
                  ContractRunner.sha256sum(joinpath(forcing, "manifest.toml"))
            @test metadata["provenance"]["comparison_schema"] ==
                  "reduced-comparison-oracle-v1"
            @test !haskey(metadata, "artifact")
        end
    end
end

@testset "Validation Runner rejects a missing CORPSE forcing override" begin
    mktempdir() do directory
        missing = joinpath(directory, "missing-forcing")
        withenv("CLIMALAND_VALIDATION_CORPSE_FORCING" => missing) do
            error = try
                ContractRunner.representative_forcing_directory()
                nothing
            catch caught
                caught
            end
            @test error isa ContractRunner.RunnerError
            @test occursin(
                "CLIMALAND_VALIDATION_CORPSE_FORCING",
                sprint(showerror, error),
            )
            @test occursin("missing-forcing", sprint(showerror, error))
        end
    end
end

@testset "Validation Runner rejects malformed CORPSE forcing before workers" begin
    configuration = ContractRunner.parse_args([
        "--scope",
        "representative",
        "--models",
        "CORPSE,MIMICS-C",
    ])
    scope = ContractRunner.load_scope_manifests("representative")
    mktempdir() do directory
        forcing = write_contract_forcing_bundle(joinpath(directory, "forcing"))
        write(joinpath(forcing, "fixture.toml"), "changed after manifest")
        report = ContractRunner.empty_aggregate_report(
            configuration,
            joinpath(directory, "output"),
            scope,
        )
        worker_called = Ref(false)
        worker_runner =
            function (command; models, workers, worker_log_directory)
                worker_called[] = true
                return (; outcomes = Any[])
            end
        withenv("CLIMALAND_VALIDATION_CORPSE_FORCING" => forcing) do
            error = try
                ContractRunner.run_multiple!(
                    report,
                    joinpath(directory, "output"),
                    configuration,
                    scope;
                    reference_resolver = (_, _) -> ("reference", nothing),
                    fixture_resolver = (_, _) -> ("fixture", nothing),
                    worker_runner,
                )
                nothing
            catch caught
                caught
            end
            @test error isa ContractRunner.RunnerError
            @test occursin(
                "differs from its manifest",
                sprint(showerror, error),
            )
            @test !worker_called[]
        end
    end
end

@testset "Validation Runner completes CORPSE compatibility before workers" begin
    configuration = ContractRunner.parse_args([
        "--scope",
        "representative",
        "--models",
        "CORPSE,MIMICS-C",
    ])
    scope = ContractRunner.load_scope_manifests("representative")
    mktempdir() do directory
        forcing = write_contract_forcing_bundle(joinpath(directory, "forcing"))
        report = ContractRunner.empty_aggregate_report(
            configuration,
            joinpath(directory, "output"),
            scope,
        )
        worker_called = Ref(false)
        worker_runner =
            function (command; models, workers, worker_log_directory)
                worker_called[] = true
                return (; outcomes = Any[])
            end
        preflight = function (scope_path, forcing_root, reference_root)
            @test scope_path == scope.path
            @test forcing_root == forcing
            @test reference_root == "CORPSE-reference"
            throw(ContractRunner.RunnerError("mixed CORPSE compatibility set"))
        end

        @test_throws ContractRunner.RunnerError ContractRunner.run_multiple!(
            report,
            joinpath(directory, "output"),
            configuration,
            scope;
            reference_resolver = (_, model) -> ("$model-reference", nothing),
            fixture_resolver = (_, _) -> ("fixture", nothing),
            corpse_forcing_resolver = () -> (forcing, nothing),
            corpse_preflight = preflight,
            worker_runner,
        )
        @test !worker_called[]
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
        forcing = write_contract_forcing_bundle(joinpath(output, "forcing"))
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
            corpse_forcing_resolver = () -> (forcing, repeat("c", 40)),
            corpse_preflight = (_, _, _) -> nothing,
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
        exitcode, report, forcing_manifest_sha =
            run_injected_representative(model, true)
        result = only(report["model"])
        @test exitcode == 0
        @test result["outcome"] == "passed"
        @test result["coverage"]["compared_cells"] ==
              (model == "CORPSE" ? 78 : 80)
        @test length(result["coverage"]["eligibility_gaps"]) ==
              (model == "CORPSE" ? 2 : 0)
        @test haskey(result, "comparison_policy")
        if model == "CORPSE"
            @test result["forcing"]["manifest_sha256"] == forcing_manifest_sha
            @test result["forcing"]["artifact"] == repeat("b", 40)
            @test result["forcing"]["provenance"]["comparison_schema"] ==
                  "reduced-comparison-oracle-v1"
        end

        exitcode, report, _ = run_injected_representative(model, false)
        @test exitcode == 1
        @test report["outcome"] == "failed"
        @test only(report["model"])["outcome"] == "failed"
    end
end

@testset "Validation Runner records explicit maintainer evidence retention" begin
    defaults = ContractRunner.parse_args(String[])
    @test defaults.retain_fresh_evidence === false
    @test_throws ContractRunner.RunnerError ContractRunner.parse_args([
        "--retain-fresh-evidence",
    ])
    @test_throws ContractRunner.RunnerError ContractRunner.parse_args([
        "--reference",
        "fresh",
        "--retain-fresh-evidence",
    ])

    mktempdir() do output
        configuration = ContractRunner.parse_args([
            "--scope",
            "representative",
            "--models",
            "CORPSE",
            "--reference",
            "fresh",
            "--output",
            output,
            "--retain-fresh-evidence",
        ])
        scope = ContractRunner.load_scope_manifests("representative")
        report =
            ContractRunner.empty_aggregate_report(configuration, output, scope)
        runner = function (
            reference_mode,
            build_command,
            worker_command;
            models,
            workers,
            temporary_parent,
            retain_success,
            scope_manifest_sha256,
            preflight,
        )
            @test retain_success
            @test scope_manifest_sha256 == ContractRunner.sha256sum(scope.path)
            evidence = joinpath(output, "fresh-reference-evidence")
            mkpath(evidence)
            build = (;
                outcome = "passed",
                seconds = 0.1,
                exitcode = 0,
                signal = 0,
                error = nothing,
            )
            outcome = merge(build, (; model = "CORPSE"))
            comparison = Dict(
                "outcome" => "passed",
                "coverage" => Dict(
                    "scope_cells" => 80,
                    "eligible_cells" => 78,
                    "compared_cells" => 78,
                ),
            )
            return (;
                outcome = "passed",
                exitcode = 0,
                build,
                outcomes = [outcome],
                comparisons = Dict("CORPSE" => comparison),
                run_root = evidence,
                preserved = true,
                retention_mode = "maintainer",
                proposal_paths = Dict{String, String}(),
            )
        end

        @test ContractRunner.run_fresh!(
            report,
            output,
            configuration;
            commands = (build = nothing, worker = nothing),
            runner,
        )
        @test report["fresh_reference"]["retention_mode"] == "maintainer"
        @test report["fresh_reference"]["retained_on_success"] === true
        @test report["fresh_reference"]["ephemeral"] === false
        @test isdir(report["fresh_reference"]["evidence_root"])
    end
end
