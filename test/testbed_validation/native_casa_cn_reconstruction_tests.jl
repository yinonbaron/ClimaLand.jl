using Test
import NCDatasets
import TOML

@testset "native CASA-CN reconstruction contract" begin
    stages = TestbedNativeCASACNReconstruction.COMPLETE_STAGES
    @test getproperty.(stages, :name) ==
          (:prespin, :accelerated_spin, :normal_spin, :historical)
    @test getproperty.(stages, :forcing_days) ==
          (365, 20 * 365, 20 * 365, 114 * 365)
    @test getproperty.(stages, :repeats) == (100, 499, 499, 1)

    variables = TestbedNativeCASACNReconstruction.historical_variables()
    required = Set((
        "cleaf",
        "nleaf",
        "cwood",
        "nwood",
        "cfroot",
        "nfroot",
        "clitmetb",
        "nlitmetb",
        "clitstr",
        "nlitstr",
        "clitcwd",
        "nlitcwd",
        "csoilmic",
        "nsoilmic",
        "csoilslow",
        "nsoilslow",
        "csoilpass",
        "nsoilpass",
        "nMineral",
        "nMinDep",
        "nMinFix",
        "nMinUptake",
        "nMinLeach",
        "nMinLoss",
        "nLitMineralization",
        "nSoilMineralization",
        "nSoilImmob",
        "nNetMineralization",
        "cgpp",
        "cnpp",
        "cresp",
        "cLitInptMet",
        "cLitInptStruc",
        "cpassInpt",
        "nLitInptMet",
        "nLitInptStruc",
    ))
    @test Set(first.(variables)) == required
end

@testset "native CASA-CN boundary bookkeeping" begin
    points = 2
    plant_carbon = zeros(1, 1, 21, points)
    soil_carbon = zeros(1, 1, 8, points)
    soil_nitrogen = zeros(1, 1, 13, points)
    plant_carbon[1, 1, 15, :] .= (1, 2)
    plant_carbon[1, 1, 16, :] .= (3, 4)
    soil_carbon[1, 1, 7, :] .= (0.25, 0.5)
    soil_nitrogen[1, 1, 11, :] .= (5, 6)
    soil_nitrogen[1, 1, 12, :] .= (7, 8)
    soil_nitrogen[1, 1, 13, :] .= (9, 10)
    cache = (;
        casa_plant = (; carbon_fluxes = plant_carbon),
        casa_soil = (;
            carbon_fluxes = soil_carbon,
            nitrogen_fluxes = soil_nitrogen,
            nitrogen_deposition = reshape([11.0, 12.0], 1, 1, 1, :),
            nitrogen_fixation = reshape([13.0, 14.0], 1, 1, 1, :),
        ),
        nitrogen_plant_uptake = reshape([15.0, 16.0], 1, 1, 1, :),
    )
    bookkeeping = TestbedNativeCASACNReconstruction.BoundaryBookkeeping(points)
    TestbedNativeCASACNReconstruction.accumulate_bookkeeping!(
        bookkeeping,
        1,
        cache,
    )
    TestbedNativeCASACNReconstruction.accumulate_bookkeeping!(
        bookkeeping,
        2,
        cache,
    )
    scale = 2 * 1000 * 86400
    @test bookkeeping.values["casabal%Fcnppyear"] == scale .* [1, 2]
    @test bookkeeping.values["casabal%FCrsyear"] == scale .* [0.25, 0.5]
    @test bookkeeping.values["casabal%FCneeyear"] ==
          scale .* ([1, 2] .- [0.25, 0.5])
    @test bookkeeping.values["casabal%FCrpyear"] == scale .* [3, 4]
    @test bookkeeping.values["casabal%FNdepyear"] == scale .* [11, 12]
    @test bookkeeping.values["casabal%FNfixyear"] == scale .* [13, 14]
    @test bookkeeping.values["casabal%FNsnetyear"] == scale .* [5, 6]
    @test bookkeeping.values["casabal%FNupyear"] == scale .* [15, 16]
    @test bookkeeping.values["casabal%FNleachyear"] == scale .* [9, 10]
    @test bookkeeping.values["casabal%FNlossyear"] == scale .* [7, 8]

    TestbedNativeCASACNReconstruction.accumulate_bookkeeping!(
        bookkeeping,
        366,
        cache,
    )
    @test bookkeeping.values["casabal%Fcnppyear"] == 1000 * 86400 .* [1, 2]
    TestbedNativeCASACNReconstruction.accumulate_bookkeeping!(
        bookkeeping,
        367,
        cache,
    )
    @test @allocated(
        TestbedNativeCASACNReconstruction.accumulate_bookkeeping!(
            bookkeeping,
            368,
            cache,
        )
    ) == 0
end

@testset "native CASA-CN synthetic handoff and reports" begin
    mktempdir() do output_root
        result =
            TestbedNativeCASACNReconstruction.run_synthetic_case(output_root)
        report = TOML.parsefile(result.report)

        @test all(isfile, getproperty.(result.stages, :handoff_checkpoint))
        @test all(getproperty.(result.stages, :checkpoint_roundtrip_verified))
        @test report["passive_restoration"]["carbon"]["verified"]
        @test report["passive_restoration"]["nitrogen"]["verified"]
        @test report["passive_restoration"]["unaffected_verified"]
        @test report["carbon_budget"]["all_close"]
        @test report["nitrogen_budget"]["all_close"]
        @test Set(keys(report["historical_comparison"])) ==
              Set(("fresh_fortran", "published_archive"))
        @test report["historical_comparison"]["fresh_fortran"]["source"] ==
              "fresh_fortran"
        @test report["historical_comparison"]["published_archive"]["source"] ==
              "published_archive"
        NCDatasets.NCDataset(result.output) do output
            @test all(
                haskey(output, variable.native_name) for (_, variable) in
                TestbedNativeCASACNReconstruction.historical_variables()
            )
        end
    end
end
