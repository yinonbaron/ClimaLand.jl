using Test
import SHA
import TOML

include(joinpath(@__DIR__, "validation_shard_aggregation.jl"))
const ShardAggregation = TestbedValidationShardAggregation

const SHARD_SCOPE_PATH =
    joinpath(@__DIR__, "validation", "scopes", "representative.toml")
const SHARD_SCOPE = TOML.parsefile(SHARD_SCOPE_PATH)
const SHARD_CELLS = Int.(SHARD_SCOPE["cell_ids"])
const SHARD_MODELS = ("CORPSE", "MIMICS-C", "MIMICS-CN", "CASA-C", "CASA-CN")

shard_cells(index, count = 8) = SHARD_CELLS[index:count:end]

function shard_gaps(model, cells)
    return [
        deepcopy(gap) for gap in SHARD_SCOPE["eligibility_gaps"] if
        gap["model"] == model && Int(gap["cell_id"]) in cells
    ]
end

function synthetic_shard(model, index; passed = true)
    cells = shard_cells(index)
    gaps = shard_gaps(model, cells)
    eligible = length(cells) - length(gaps)
    number = something(findfirst(==(model), SHARD_MODELS))
    model_report = Dict(
        "name" => model,
        "outcome" => passed ? "passed" : "failed",
        "reference_mode" => "pinned",
        "seconds" => Float64(index),
        "coverage" => Dict(
            "scope_cells" => length(cells),
            "eligible_cells" => eligible,
            "compared_cells" => eligible,
            "eligibility_gaps" => gaps,
        ),
        "comparison" => Dict("scientific" => passed),
        "diagnostics" => Dict(
            "all_match" => passed,
            "cell_ids" => cells,
            "cell_failures" =>
                passed ? Any[] : [Dict("cell_id" => first(cells))],
            "variable" => Dict(
                "pool" => Dict(
                    "all_match" => passed,
                    "atol" => 1.0e-8,
                    "rtol" => 1.0e-6,
                    "compared_values" => 2 * eligible,
                    "failed_values" => passed ? 0 : 1,
                    "maximum_absolute_error" => index / 100,
                    "maximum_relative_error" => index / 10,
                ),
            ),
        ),
        "budget" => Dict(
            "carbon" => Dict(
                "all_close" => passed,
                "maximum_absolute_residual_kg_c" => Float64(index),
                "reducer" => "maximum_absolute_residual",
                "stage" => Dict(
                    "historical" => Dict(
                        "start_stock_kg_c" => 10.0 * index,
                        "stop_stock_kg_c" => 13.0 * index,
                        "external_input_kg_c" => 3.0 * index,
                        "external_output_kg_c" => 1.0 * index,
                        "residual_kg_c" => 1.0 * index,
                        "relative_residual" => 1 / 3,
                        "rtol" => 1.0,
                        "close" => passed,
                    ),
                ),
            ),
        ),
        "comparison_policy" => Dict(
            "id" => string("policy-", model),
            "sha256" => repeat(string(number), 64)[1:64],
        ),
        "reference" => Dict(
            "artifact" => repeat(string(number), 40)[1:40],
            "sha256" => repeat("a", 64),
        ),
        "forcing" => Dict(
            "artifact" => repeat("f", 40),
            "manifest_sha256" => repeat("b", 64),
        ),
    )
    model_report["shard_evidence"] = Dict{String, Any}(
        "comparison_report_sha256" => repeat(string(mod(index, 10)), 64),
    )
    if model in ("MIMICS-C", "MIMICS-CN")
        budget_comparison = Dict(
            "all_match" => passed,
            "julia_maximum_absolute_residual_kg_c" => index / 100,
            "fortran_maximum_absolute_residual_kg_c" => index / 200,
        )
        model == "MIMICS-CN" && (
            budget_comparison["julia_maximum_absolute_residual_kg_n"] =
                index / 1000
        )
        model_report["historical"] = Dict(
            "annual" => deepcopy(model_report["diagnostics"]),
            "fixed_daily_samples" => deepcopy(model_report["diagnostics"]),
            "budget_comparison" => budget_comparison,
        )
        mimics_stages =
            model == "MIMICS-C" ? ("prespin", "spin", "historical") :
            ("prespin", "spin", "spin_continuation", "historical")
        model_report["boundary_comparison"] = Dict(
            stage => Dict("pool" => deepcopy(model_report["diagnostics"]))
            for stage in mimics_stages
        )
    elseif model == "CORPSE"
        model_report["boundary_comparison"] = Dict(
            stage => Dict("pool" => deepcopy(model_report["diagnostics"]))
            for
            stage in ("prespin", "spin", "spin_continuation", "historical")
        )
        reduced = Dict(
            "pool" =>
                deepcopy(model_report["diagnostics"]["variable"]["pool"]),
        )
        model_report["reduced_historical"] = Dict(
            "annual_summaries" => deepcopy(reduced),
            "end_of_year" => deepcopy(reduced),
            "annual_budgets" => deepcopy(reduced),
            "fixed_daily_samples" => deepcopy(reduced),
        )
        model_report["shard_evidence"]["stage"] = Dict(
            stage => Dict(
                "checkpoint_sha256" => repeat(string(mod(index, 10)), 64),
                "restart_transform_verified" => true,
                "checkpoint_handoff_verified" => true,
                "conservation_verified" => true,
            ) for
            stage in ("prespin", "spin", "spin_continuation", "historical")
        )
    else
        model_report["initialization_comparison"] =
            deepcopy(model_report["diagnostics"])
        model_report["boundary_comparison"] = Dict(
            stage => Dict(
                "source" => Dict(
                    "fresh_fortran" =>
                        deepcopy(model_report["diagnostics"]),
                ),
            ) for stage in
            ("prespin", "accelerated_spin", "normal_spin", "historical")
        )
        model_report["historical"] = Dict(
            "annual" => deepcopy(model_report["diagnostics"]),
            "selected_dates" => deepcopy(model_report["diagnostics"]),
        )
        model == "CASA-CN" && (
            model_report["historical"]["fresh_fortran_daily"] =
                deepcopy(model_report["diagnostics"])
        )
        model_report["passive_restoration"] = Dict(
            "verified" => true,
            "unaffected_verified" => true,
            "checkpoint_roundtrip_verified" => true,
        )
        passive = Dict{String, Any}(
            "multiplier" => 0.25,
            "verified" => true,
            "unaffected_verified" => true,
            "checkpoint_roundtrip_verified" => true,
            "carbon" => Dict(
                "before" => Float64.(cells),
                "after" => Float64.(cells) ./ 4,
                "verified" => true,
            ),
        )
        model == "CASA-CN" && (
            passive["nitrogen"] = Dict(
                "before" => Float64.(cells) ./ 10,
                "after" => Float64.(cells) ./ 40,
                "verified" => true,
            )
        )
        model_report["shard_evidence"]["passive_restoration"] = passive
    end
    model in ("CASA-CN", "MIMICS-CN") && (
        model_report["budget"]["nitrogen"] = Dict(
            "all_close" => passed,
            "maximum_absolute_residual_kg_n" => index / 10,
            "reducer" => "maximum_absolute_residual",
        )
    )
    return Dict(
        "schema_version" => 1,
        "comparison_schema" => "representative-pinned-comparison-v1",
        "reference_mode" => "pinned",
        "outcome" => passed ? "passed" : "failed",
        "seconds" => Float64(index),
        "workers" => 1,
        "scope" => Dict(
            "name" => "representative",
            "cell_count" => length(SHARD_CELLS),
            "cell_ids" => SHARD_CELLS,
            "manifest_sha256" =>
                bytes2hex(SHA.sha256(read(SHARD_SCOPE_PATH))),
        ),
        "shard" => Dict(
            "schema_version" => 1,
            "strategy" => "scope-order-round-robin-v1",
            "index" => index,
            "count" => 8,
            "cell_ids" => cells,
        ),
        "model" => [model_report],
    )
end

all_synthetic_shards() =
    [synthetic_shard(model, index) for model in SHARD_MODELS for index in 1:8]

function aggregation_error(reports)
    try
        ShardAggregation.aggregate_shard_reports(
            reports,
            SHARD_SCOPE_PATH;
            expected_models = collect(SHARD_MODELS),
            shard_count = 8,
        )
        return nothing
    catch error
        return error
    end
end

@testset "Representative shard aggregation succeeds for all models" begin
    aggregate = ShardAggregation.aggregate_shard_reports(
        reverse(all_synthetic_shards()),
        SHARD_SCOPE_PATH;
        expected_models = collect(SHARD_MODELS),
        shard_count = 8,
    )
    @test aggregate["outcome"] == "passed"
    @test aggregate["scope"]["cell_ids"] == SHARD_CELLS
    @test aggregate["sharding"]["job_count"] == 40
    @test getindex.(aggregate["model"], "name") == collect(SHARD_MODELS)
    @test aggregate["seconds"] == 8.0
    @test aggregate["sharding"]["total_job_seconds"] == 180.0
    by_model = Dict(model["name"] => model for model in aggregate["model"])
    for model in SHARD_MODELS
        report = by_model[model]
        expected = model == "CORPSE" ? 78 : 80
        @test report["coverage"]["scope_cells"] == 80
        @test report["coverage"]["eligible_cells"] == expected
        @test report["coverage"]["compared_cells"] == expected
        @test report["diagnostics"]["cell_ids"] == SHARD_CELLS
        metric = report["diagnostics"]["variable"]["pool"]
        @test metric["compared_values"] == 2 * expected
        @test metric["maximum_absolute_error"] == 0.08
        @test metric["maximum_relative_error"] == 0.8
        @test report["budget"]["carbon"]["maximum_absolute_residual_kg_c"] ==
              36.0
        @test report["budget"]["carbon"]["stage"]["historical"]["residual_kg_c"] ==
              36.0
    end
    for model in SHARD_MODELS
        @test length(by_model[model]["shard_evidence"]) == 8
        @test getindex.(by_model[model]["shard_evidence"], "shard_index") ==
              collect(1:8)
    end
    @test by_model["MIMICS-C"]["historical"]["budget_comparison"]["julia_maximum_absolute_residual_kg_c"] ==
          0.08
    @test haskey(by_model["CORPSE"], "boundary_comparison")
    @test haskey(by_model["CORPSE"], "reduced_historical")
    @test haskey(by_model["CASA-C"], "initialization_comparison")
    @test haskey(by_model["CASA-C"], "historical")
    @test length(by_model["CORPSE"]["coverage"]["eligibility_gaps"]) == 2
end

@testset "Representative shard aggregation fails closed" begin
    complete = all_synthetic_shards()
    @test occursin(
        "missing shard",
        sprint(showerror, aggregation_error(complete[1:(end - 1)])),
    )
    @test occursin(
        "duplicate shard",
        sprint(
            showerror,
            aggregation_error([complete; deepcopy(first(complete))]),
        ),
    )
    overlap = deepcopy(complete)
    overlap[2]["shard"]["cell_ids"][1] = overlap[1]["shard"]["cell_ids"][1]
    @test occursin(
        "deterministic assignment",
        sprint(showerror, aggregation_error(overlap)),
    )
    provenance = deepcopy(complete)
    provenance[2]["model"][1]["reference"]["sha256"] = repeat("c", 64)
    @test occursin(
        "reference provenance",
        sprint(showerror, aggregation_error(provenance)),
    )
    policy = deepcopy(complete)
    policy[2]["model"][1]["comparison_policy"]["id"] = "changed"
    @test occursin(
        "comparison policy",
        sprint(showerror, aggregation_error(policy)),
    )
    schema = deepcopy(complete)
    schema[2]["schema_version"] = 2
    @test occursin("schema", sprint(showerror, aggregation_error(schema)))
    forcing = deepcopy(complete)
    forcing[2]["model"][1]["forcing"]["manifest_sha256"] = repeat("d", 64)
    @test occursin(
        "forcing provenance",
        sprint(showerror, aggregation_error(forcing)),
    )
    cross_model_forcing = deepcopy(complete)
    for report in cross_model_forcing[9:16]
        report["model"][1]["forcing"]["artifact"] = repeat("e", 40)
    end
    @test occursin(
        "inconsistent forcing provenance",
        sprint(showerror, aggregation_error(cross_model_forcing)),
    )
    incomplete = deepcopy(complete)
    incomplete[2]["model"][1]["coverage"]["compared_cells"] -= 1
    @test occursin(
        "incomplete coverage",
        sprint(showerror, aggregation_error(incomplete)),
    )
    structure = deepcopy(complete)
    structure[2]["model"][1]["diagnostics"]["unexpected"] = true
    @test occursin(
        "incompatible",
        sprint(showerror, aggregation_error(structure)),
    )
    missing_evidence = deepcopy(complete)
    delete!(missing_evidence[1]["model"][1], "shard_evidence")
    @test occursin(
        "lacks detailed shard evidence",
        sprint(showerror, aggregation_error(missing_evidence)),
    )
    invalid_evidence_type = deepcopy(complete)
    invalid_evidence_type[1]["model"][1]["shard_evidence"] = "invalid"
    @test occursin(
        "lacks detailed shard evidence",
        sprint(showerror, aggregation_error(invalid_evidence_type)),
    )
    invalid_evidence_digest = deepcopy(complete)
    invalid_evidence_digest[1]["model"][1]["shard_evidence"]["comparison_report_sha256"] = "invalid"
    @test occursin(
        "invalid comparison report digest",
        sprint(showerror, aggregation_error(invalid_evidence_digest)),
    )
    incomplete_corpse_evidence = deepcopy(complete)
    delete!(
        incomplete_corpse_evidence[1]["model"][1]["shard_evidence"]["stage"]["prespin"],
        "conservation_verified",
    )
    @test occursin(
        "invalid prespin stage evidence",
        sprint(showerror, aggregation_error(incomplete_corpse_evidence)),
    )
    missing_passive_field = deepcopy(complete)
    delete!(
        missing_passive_field[25]["model"][1]["shard_evidence"]["passive_restoration"],
        "unaffected_verified",
    )
    @test occursin(
        "unverified passive restoration",
        sprint(showerror, aggregation_error(missing_passive_field)),
    )
    wrong_passive_length = deepcopy(complete)
    pop!(
        wrong_passive_length[25]["model"][1]["shard_evidence"]["passive_restoration"]["carbon"]["before"],
    )
    @test occursin(
        "invalid passive carbon vectors",
        sprint(showerror, aggregation_error(wrong_passive_length)),
    )
    incomplete_mimics_cn = deepcopy(complete)
    for report in incomplete_mimics_cn[17:24]
        delete!(report["model"][1]["historical"], "fixed_daily_samples")
    end
    @test occursin(
        "MIMICS-CN shard 1 has incomplete historical evidence",
        sprint(showerror, aggregation_error(incomplete_mimics_cn)),
    )
    incomplete_casa_cn = deepcopy(complete)
    for report in incomplete_casa_cn[33:40]
        delete!(report["model"][1]["budget"], "nitrogen")
    end
    @test occursin(
        "CASA-CN shard 1 nitrogen budget is missing",
        sprint(showerror, aggregation_error(incomplete_casa_cn)),
    )
    failed = deepcopy(complete)
    failed[2]["outcome"] = "failed"
    failed_model = failed[2]["model"][1]
    failed_model["outcome"] = "failed"
    failed_model["diagnostics"]["all_match"] = false
    failed_model["diagnostics"]["cell_failures"] =
        [Dict("cell_id" => first(failed[2]["shard"]["cell_ids"]))]
    failed_model["diagnostics"]["variable"]["pool"]["all_match"] = false
    failed_model["diagnostics"]["variable"]["pool"]["failed_values"] = 1
    failed_aggregate = ShardAggregation.aggregate_shard_reports(
        failed,
        SHARD_SCOPE_PATH;
        expected_models = collect(SHARD_MODELS),
        shard_count = 8,
    )
    @test failed_aggregate["outcome"] == "failed"
    failed_corpse = only(
        filter(report -> report["name"] == "CORPSE", failed_aggregate["model"]),
    )
    @test only(failed_corpse["diagnostics"]["cell_failures"])["cell_id"] ==
          first(failed[2]["shard"]["cell_ids"])
    @test failed_corpse["diagnostics"]["variable"]["pool"]["failed_values"] == 1
end

@testset "Shard aggregation CLI always writes a report" begin
    mktempdir() do directory
        input = joinpath(directory, "input")
        output = joinpath(directory, "output")
        mkpath(input)
        for (ordinal, report) in enumerate(all_synthetic_shards())
            root = joinpath(input, string("job-", ordinal))
            mkpath(root)
            open(joinpath(root, "validation_report.toml"), "w") do io
                TOML.print(io, report; sorted = true)
            end
        end
        arguments = [
            "--input",
            input,
            "--output",
            output,
            "--shard-count",
            "8",
            "--models",
            "all",
        ]
        @test ShardAggregation.main(arguments) == 0
        aggregate = TOML.parsefile(joinpath(output, "validation_report.toml"))
        @test aggregate["outcome"] == "passed"
        @test length(aggregate["model"]) == 5
        for model in aggregate["model"]
            @test isfile(model["comparison_report"])
            @test bytes2hex(SHA.sha256(read(model["comparison_report"]))) ==
                  model["comparison_report_sha256"]
        end
        malformed =
            TOML.parsefile(joinpath(input, "job-1", "validation_report.toml"))
        delete!(only(malformed["model"]), "reference")
        open(joinpath(input, "job-1", "validation_report.toml"), "w") do io
            TOML.print(io, malformed; sorted = true)
        end
        @test ShardAggregation.main(arguments) == 1
        malformed_failure =
            TOML.parsefile(joinpath(output, "validation_report.toml"))
        @test malformed_failure["outcome"] == "failed"
        @test occursin(
            "unexpected aggregation failure",
            malformed_failure["error"],
        )

        broken = joinpath(directory, "broken")
        mkpath(broken)
        write(joinpath(broken, "validation_report.toml"), "not = [valid")
        broken_arguments = copy(arguments)
        broken_arguments[2] = broken
        @test ShardAggregation.main(broken_arguments) == 1
        failed = TOML.parsefile(joinpath(output, "validation_report.toml"))
        @test failed["outcome"] == "failed"
        @test occursin("unreadable", failed["error"])
    end
end
