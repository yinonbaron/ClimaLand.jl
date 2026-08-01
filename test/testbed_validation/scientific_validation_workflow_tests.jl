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
    @test !occursin("matrix:", workflow)
    @test occursin("runs-on: ubuntu-latest", workflow)
    @test occursin("version: '1.12'", workflow)
    @test occursin("timeout-minutes: 120", workflow)

    cache = findfirst("Cache Julia depot and validation artifacts", workflow)
    stage = findfirst("Stage all pinned Representative artifacts", workflow)
    run = findfirst("Run all Representative model comparisons", workflow)
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

    runner_command = r"validation_runner\.jl\s+\\\s+--scope representative\s+\\\s+--models all\s+\\\s+--reference pinned"s
    @test occursin(runner_command, workflow)
    @test occursin("if: steps.stage_artifacts.outcome == 'success'", workflow)
    @test occursin("Required pinned artifacts are unpublished", workflow)
    @test occursin("SECONDS >= 3600", workflow)
    @test occursin("::warning", workflow)
    @test occursin("name: Upload compact validation report", workflow)
    @test occursin(r"if: always\(\)\s+uses: actions/upload-artifact@"s, workflow)
    @test occursin("name: Upload detailed failure logs", workflow)
    @test occursin(
        "if: steps.stage_artifacts.outcome != 'success' || steps.validation.outcome != 'success'",
        workflow,
    )
    @test occursin("publication issue #55", workflow)
end
