using Test
import TOML

const REPRESENTATIVE_SELECTION = TestbedRepresentativeCellSelection

function synthetic_candidate(cell_id, pft, offset; active = true)
    return (;
        cell_id,
        pft,
        active,
        features = (
            gpp_median = offset,
            gpp_p10 = offset + 0.01,
            gpp_p90 = offset + 0.02,
            gpp_seasonal_amplitude = offset + 0.03,
            temperature_median = offset + 0.04,
            temperature_p10 = offset + 0.05,
            temperature_p90 = offset + 0.06,
            temperature_seasonal_amplitude = offset + 0.07,
            liquid_moisture_median = offset + 0.08,
            liquid_moisture_p10 = offset + 0.09,
            liquid_moisture_p90 = offset + 0.10,
            liquid_moisture_seasonal_amplitude = offset + 0.11,
            frozen_moisture_median = offset + 0.12,
            frozen_moisture_p10 = offset + 0.13,
            frozen_moisture_p90 = offset + 0.14,
            frozen_moisture_seasonal_amplitude = offset + 0.15,
            nitrogen_deposition_median = offset + 0.16,
            nitrogen_deposition_p10 = offset + 0.17,
            nitrogen_deposition_p90 = offset + 0.18,
            nitrogen_deposition_seasonal_amplitude = offset + 0.19,
            clay = offset + 0.20,
            silt = offset + 0.21,
            porosity = offset + 0.22,
        ),
    )
end

@testset "Representative manifest preserves reviewed gaps" begin
    mktempdir() do directory
        source = joinpath(directory, "forcing.nc")
        grid = joinpath(directory, "grid.csv")
        soil = joinpath(directory, "soil.csv")
        write(source, "forcing")
        write(grid, "grid")
        write(soil, "soil")
        output = joinpath(directory, "representative.toml")
        gaps = [
            Dict(
                "model" => "CORPSE",
                "cell_id" => 51,
                "pft" => 17,
                "reason" => "reviewed inactive mask evidence",
                "reviewed" => true,
            ),
        ]
        selection = (;
            cell_ids = [51, 52],
            matches = NamedTuple[],
            allocation = Dict(1 => 1),
            population = Dict(1 => 2),
        )
        smoke_manifest =
            joinpath(@__DIR__, "validation", "scopes", "smoke.toml")
        REPRESENTATIVE_SELECTION.write_scope_manifest(
            output,
            selection,
            [51],
            [source],
            grid,
            soil,
            smoke_manifest;
            seed = 31432026,
            eligibility_gaps = gaps,
        )
        @test TOML.parsefile(output)["eligibility_gaps"] == gaps
    end
end

@testset "Representative selector is deterministic and PFT-stratified" begin
    candidates = [
        synthetic_candidate(id, pft, id / 1000) for
        (id, pft) in zip(1:100, repeat([1, 2, 3, 4], 25))
    ]
    candidates[100] = synthetic_candidate(100, 4, 0.1; active = false)
    smoke_ids = collect(1:7)

    selection = REPRESENTATIVE_SELECTION.select_representative_cells(
        candidates,
        smoke_ids;
        total_cells = 20,
        seed = 31432026,
    )
    repeated = REPRESENTATIVE_SELECTION.select_representative_cells(
        reverse(candidates),
        reverse(smoke_ids);
        total_cells = 20,
        seed = 31432026,
    )

    @test selection.cell_ids == repeated.cell_ids
    @test selection.matches == repeated.matches
    @test length(selection.cell_ids) == 20
    @test length(unique(selection.cell_ids)) == 20
    @test issubset(smoke_ids, selection.cell_ids)
    @test selection.cell_ids != sort(smoke_ids)
    @test 100 ∉ selection.cell_ids
    @test sum(values(selection.allocation)) == 13
    @test selection.population == Dict(1 => 25, 2 => 25, 3 => 25, 4 => 24)
    @test selection.allocation == Dict(1 => 4, 2 => 3, 3 => 3, 4 => 3)
    @test all(match -> match.matching_error >= 0, selection.matches)
    @test all(
        match ->
            length(match.target) ==
            length(REPRESENTATIVE_SELECTION.FEATURE_NAMES),
        selection.matches,
    )
end

@testset "Representative fixture provenance is complete" begin
    provenance = REPRESENTATIVE_SELECTION.fixture_provenance()
    @test provenance.selection["code"] == "representative_cell_selection.jl"
    @test provenance.selection["code_sha256"] ==
          REPRESENTATIVE_SELECTION.sha256sum(
        joinpath(@__DIR__, "representative_cell_selection.jl"),
    )
    @test provenance.time["calendar"] == "noleap"
    @test provenance.time["start_year"] == 1901
    @test provenance.time["end_year"] == 2014
    @test provenance.time["days"] == 41610
end
