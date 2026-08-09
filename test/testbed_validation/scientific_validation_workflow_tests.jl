using Test

const REPRESENTATIVE_VALIDATION_WORKFLOW = normpath(
    joinpath(
        @__DIR__,
        "..",
        "..",
        ".github",
        "workflows",
        "representative-validation.yml",
    ),
)

@testset "Representative scientific validation workflow contract" begin
    workflow = read(REPRESENTATIVE_VALIDATION_WORKFLOW, String)

    @test occursin("pull_request:", workflow)
    @test occursin(r"push:\s+branches: \[main\]"s, workflow)
    @test !occursin(r"paths(?:-ignore)?:", workflow)
    @test occursin(
        r"concurrency:\s+group:.*github\.ref.*cancel-in-progress: true"s,
        workflow,
    )
    @test occursin("matrix:", workflow)
    @test occursin("fail-fast: false", workflow)
    @test occursin("max-parallel: 40", workflow)
    @test occursin("shard: [1, 2, 3, 4, 5, 6, 7, 8]", workflow)
    for (model, slug, artifact) in (
        ("CORPSE", "corpse", "representative_corpse_reference"),
        ("MIMICS-C", "mimics-c", "representative_mimics_c_reference"),
        ("MIMICS-CN", "mimics-cn", "representative_mimics_cn_reference"),
        ("CASA-C", "casa-c", "representative_casa_c_reference"),
        ("CASA-CN", "casa-cn", "representative_casa_cn_reference"),
    )
        target = Regex(
            "- model: $model\\s+slug: $slug\\s+reference_artifact: $artifact",
        )
        @test occursin(target, workflow)
        @test length(
            findall(Regex("^\\s+- model: " * model * raw"$", "m"), workflow),
        ) == 1
    end
    @test occursin("MODEL: \${{ matrix.target.model }}", workflow)
    @test occursin("SHARD_INDEX: \${{ matrix.shard }}", workflow)
    @test occursin("SHARD_COUNT: '8'", workflow)
    @test length(findall(r"^\s+- model:"m, workflow)) == 5
    @test occursin("runs-on: ubuntu-latest", workflow)
    @test occursin("version: '1.12'", workflow)
    @test occursin("timeout-minutes: 100", workflow)
    @test occursin("CLIMALAND_VALIDATION_TIMEOUT_SECONDS: '4800'", workflow)

    cache = findfirst("Cache Julia depot and validation artifacts", workflow)
    @test occursin("JULIA_NUM_THREADS: '1'", workflow)
    @test occursin("OPENBLAS_NUM_THREADS: '1'", workflow)
    stage = findfirst("Stage pinned artifacts for this model", workflow)
    run = findfirst("Run one Representative model shard", workflow)
    @test !isnothing(cache)
    @test !isnothing(stage)
    @test !isnothing(run)
    @test first(cache) < first(stage) < first(run)
    for artifact in (
        "representative_forcing",
        "representative_corpse_reference",
        "representative_mimics_c_reference",
        "representative_mimics_cn_reference",
        "representative_casa_c_reference",
        "representative_casa_cn_reference",
    )
        @test occursin(artifact, workflow)
    end

    @test occursin(
        "required = (\"representative_forcing\", ENV[\"REFERENCE_ARTIFACT\"])",
        workflow,
    )
    runner_command =
        r"validation_runner\.jl\s+\\\s+--scope representative\s+\\\s+--models \"\$\{MODEL\}\"\s+\\\s+--reference pinned\s+\\\s+--shard-index \"\$\{SHARD_INDEX\}\"\s+\\\s+--shard-count \"\$\{SHARD_COUNT\}\"\s+\\\s+--workers 1"s
    @test occursin(runner_command, workflow)
    @test !occursin(
        r"validation_runner\.jl\s+\\\s+--scope representative\s+\\\s+--models all"s,
        workflow,
    )
    @test occursin("if: steps.stage_artifacts.outcome == 'success'", workflow)
    @test occursin("SECONDS >= 4200", workflow)
    @test occursin("::warning", workflow)
    @test occursin("name: Upload compact shard report", workflow)
    @test occursin(
        r"if: always\(\)\s+uses: actions/upload-artifact@"s,
        workflow,
    )
    @test occursin(
        "name: representative-validation-shard-\${{ matrix.target.slug }}-\${{ matrix.shard }}",
        workflow,
    )
    @test occursin("name: Upload detailed shard failure logs", workflow)
    @test occursin(
        "name: representative-validation-failure-\${{ matrix.target.slug }}-\${{ matrix.shard }}",
        workflow,
    )
    @test occursin("path: validation-output/logs/", workflow)
    @test occursin(
        r"if:.*always\(\).*steps\.stage_artifacts\.outcome != 'success'.*steps\.validation\.outcome != 'success'",
        workflow,
    )
    @test occursin(
        r"aggregate-validation:\s+name: Representative scientific validation\s+needs: representative-shard\s+if:.*always\(\)"s,
        workflow,
    )
    @test occursin(r"aggregate-validation:.*timeout-minutes: 30"s, workflow)
    @test occursin("pattern: representative-validation-shard-*", workflow)
    @test !occursin("merge-multiple: true", workflow)
    @test occursin("merge-multiple: false", workflow)
    aggregate_command =
        r"aggregate_validation_shards\.jl\s+\\\s+--input shard-reports\s+\\\s+--output validation-output\s+\\\s+--shard-count 8\s+\\\s+--models all"s
    @test occursin(aggregate_command, workflow)
    @test occursin("name: Upload aggregate validation report", workflow)
    @test occursin("name: representative-validation-report", workflow)
    @test occursin(
        "validation-output/models/*/comparison_report.toml",
        workflow,
    )
    @test occursin(
        "MATRIX_OUTCOME: \${{ needs.representative-shard.result }}",
        workflow,
    )
    @test occursin(
        r"name: Upload aggregate validation report\s+if: always\(\)"s,
        workflow,
    )
    @test occursin(
        "DOWNLOAD_OUTCOME: \${{ steps.download_reports.outcome }}",
        workflow,
    )
    @test occursin(
        "AGGREGATION_OUTCOME: \${{ steps.aggregate.outcome }}",
        workflow,
    )
end
