using Test
import ClimaLand
import NCDatasets
import StaticArrays
import TOML

@testset "native MIMICS-C pinned CASA parameters" begin
    path = joinpath(
        @__DIR__,
        "fixtures",
        "selected_cells",
        "pftlookup_igbp_updated4.csv",
    )
    parameters =
        TestbedNativeMIMICSCReconstruction.casa().read_pft_parameters(path)
    @test parameters[1].cues == (0.45, 0.45, 0.7, 0.4, 0.7, 1.0, 1.0, 0.45)

    mimics_path = joinpath(
        @__DIR__,
        "fixtures",
        "selected_cells",
        "pftlookup_LIDET-MIM-REV_CN_desorb2xKO4_micCN_FI30.csv",
    )
    fmet = TestbedNativeMIMICSCReconstruction.read_mimics_scalars(mimics_path)
    expected =
        fmet["fmet_p(1)"] * (
            fmet["fmet_p(2)"] -
            fmet["fmet_p(3)"] * parameters[1].lignin_leaf /
            parameters[1].plant_nitrogen_ratio[1]
        )
    @test TestbedNativeMIMICSCReconstruction.mimics_metabolic_fraction(
        parameters[1],
        :leaf,
        fmet,
    ) == expected
    initial_mimics_carbon =
        TestbedNativeMIMICSCReconstruction.initial_mimics_carbon
    @test initial_mimics_carbon(:c_litter_metabolic) == 1.0
    @test initial_mimics_carbon(:c_microbe_r) == 0.015
    @test initial_mimics_carbon(:c_microbe_k) == 0.025
    @test initial_mimics_carbon(:c_soil_physical) == 1.0
    boundary_scale = TestbedNativeMIMICSCReconstruction.boundary_reference_scale
    @test boundary_scale(:casa) == 1000.0
    @test boundary_scale(:mimics) == 1.0
end

@testset "native MIMICS-C reconstruction run-case seam" begin
    mktempdir() do output_root
        result =
            TestbedNativeMIMICSCReconstruction.run_synthetic_case(output_root)
        report = TOML.parsefile(result.report)

        @test getproperty.(result.stages, :name) ==
              (:prespin, :spin, :historical)
        @test all(isfile, getproperty.(result.stages, :checkpoint))
        @test result.before_step_calls == 6
        @test report["historical_output"]["records"] == 2
        @test Set(keys(report["boundary_comparison"])) ==
              Set(("prespin", "spin", "historical"))
        @test Set(keys(report["historical_comparison"])) ==
              Set(("fresh_fortran", "published_archive"))
        @test all(
            haskey(report["process_comparison"], process) for process in (
                "respiration",
                "litter_inputs",
                "microbial_turnover",
                "protection",
                "desorption",
                "oxidation",
                "cwd_transfer",
            )
        )
        @test report["carbon_budget"]["all_close"]
        NCDatasets.NCDataset(result.output) do output
            @test eltype(output["mimics_soil__c_soil_physical"]) == Float32
            @test all(
                haskey(output, name) for name in (
                    "mimics_soil__c_litter_metabolic",
                    "mimics_soil__c_litter_structural",
                    "mimics_soil__c_microbe_r",
                    "mimics_soil__c_microbe_k",
                    "mimics_soil__c_soil_available",
                    "mimics_soil__c_soil_chemical",
                    "mimics_soil__c_soil_physical",
                    "diagnostic__mimics_respiration",
                    "diagnostic__mimics_physical_protection",
                    "diagnostic__mimics_r_turnover",
                    "diagnostic__mimics_k_turnover",
                    "diagnostic__mimics_chemical_protection",
                    "diagnostic__mimics_desorption",
                    "diagnostic__mimics_oxidation",
                    "diagnostic__mimics_cwd_transfer",
                )
            )
        end
    end
end


@testset "native MIMICS-C budget callback allocations" begin
    stage = TestbedNativeMIMICSCReconstruction.native_workflow().NativeStage(
        :historical,
        1,
        1,
    )
    budget = TestbedNativeMIMICSCReconstruction.CarbonBudgetAccumulator([
        (; area_m2 = 1.0),
        (; area_m2 = 1.0),
    ],)
    plant_fluxes = fill(zero(StaticArrays.SVector{21, Float64}), 2)
    soil_fluxes = fill(zero(StaticArrays.SVector{17, Float64}), 2)
    p = (;
        casa_plant = (; carbon_fluxes = plant_fluxes),
        mimics_soil = (; carbon_fluxes = soil_fluxes),
    )
    TestbedNativeMIMICSCReconstruction.accumulate_budget!(budget, stage, p)
    @test @allocated(
        TestbedNativeMIMICSCReconstruction.accumulate_budget!(budget, stage, p),
    ) == 0
end
