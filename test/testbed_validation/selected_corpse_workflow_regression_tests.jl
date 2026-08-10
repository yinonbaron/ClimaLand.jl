using Test

import NCDatasets
import TOML

@testset "complete selected-cell CORPSE regression" begin
    collection = TestbedReferenceCellComparisons.extended_cell_collection()
    expected_ids = getproperty.(collection.cells, :id)
    expected_pfts = sort!(unique(getproperty.(collection.cells, :pft)))
    expected_regimes =
        sort!(unique(vcat(getproperty.(collection.cells, :reasons)...)))

    mktempdir() do output_root
        result = TestbedSelectedCORPSEWorkflow.run_selected_case(
            output_root;
            collection,
        )
        report = TOML.parsefile(result.report)

        @test getproperty.(result.stages, :name) ==
              (:prespin, :spin, :restart, :historical)
        @test all(getproperty.(result.stages, :checkpoint_roundtrip_verified))
        @test all(getproperty.(result.stages, :checkpoint_handoff_verified))
        @test all(getproperty.(result.stages, :restart_transform_verified))
        @test all(getproperty.(result.stages, :complete_corpse_state_verified))
        @test all(getproperty.(result.stages, :conservation_verified))
        @test result.full_workflow_conservation_verified
        @test report["full_workflow_conservation"]["verified"]
        @test all(isfile, getproperty.(result.stages, :checkpoint))
        @test result.reference.all_match
        @test all(
            comparison["all_match"] for
            comparison in values(result.reference.boundary)
        )
        @test all(
            haskey(comparison["variable"], "corpse_soil.c_litter_cwd") for
            comparison in values(result.reference.boundary)
        )
        @test result.reference.historical["all_match"]
        @test result.reference.historical["years"] == [1901, 1957, 2014]
        @test report["reference_comparison"] == "passed"
        @test report["selection"]["cell_ids"] == expected_ids
        @test report["selection"]["pfts"] == expected_pfts
        @test report["selection"]["forcing_regimes"] == expected_regimes
        @test report["age_representation"] == "fixed cohort identity"
        @test occursin("original carbon", report["volume_representation"])

        NCDatasets.NCDataset(result.output) do output
            @test size(output["time"], 1) == 114 * 365
        end
        for (stage, specification) in
            zip(result.stages, TestbedSelectedCORPSEWorkflow.COMPLETE_STAGES)
            manifest = TOML.parsefile(stage.manifest)
            @test manifest["recorded_steps"] ==
                  TestbedNativeWorkflow.step_count(specification)
            @test manifest["state_updates"] == "ClimaTimeSteppers only"
        end

        setup = TestbedSelectedCORPSEWorkflow.load_complete_setup(collection)
        @test setup.model.corpse_soil.temporal_mode isa
              TestbedSelectedCORPSEWorkflow.CORPSE.LegacyDaily
    end
end
