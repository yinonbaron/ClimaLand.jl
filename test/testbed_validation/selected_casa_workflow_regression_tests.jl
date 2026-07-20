using Test
import TOML

@testset "complete selected-cell CASA regressions" begin
    collection = TestbedReferenceCellComparisons.extended_cell_collection()
    expected_ids = getproperty.(collection.cells, :id)
    expected_pfts = sort!(unique(getproperty.(collection.cells, :pft)))
    expected_regimes =
        sort!(unique(vcat(getproperty.(collection.cells, :reasons)...)))
    for configuration in TestbedSelectedCASAWorkflow.supported_configurations()
        mktempdir() do output_root
            result = TestbedSelectedCASAWorkflow.run_selected_case(
                output_root;
                configuration,
                collection,
            )
            report = TOML.parsefile(result.report)

            @test report["initialization_comparison"]["all_match"]
            @test getproperty.(result.stages, :name) == getproperty.(
                TestbedSelectedCASAWorkflow.COMPLETE_STAGES,
                :name,
            )
            @test all(
                comparison["all_match"] for
                comparison in values(report["boundary_comparison"])
            )
            @test all(
                source["all_match"] for
                comparison in values(report["boundary_comparison"]) for
                source in values(comparison["source"])
            )
            expected_state_count = configuration == :carbon_only ? 10 : 20
            @test all(
                length(comparison["source"]["native_julia"]["variable"]) ==
                expected_state_count for
                comparison in values(report["boundary_comparison"])
            )
            @test report["historical_comparison"]["all_match"]
            @test report["historical_comparison"]["selected_dates"]["all_match"]
            @test haskey(
                report["historical_comparison"]["selected_dates"]["comparison"],
                "CASA environmental-trajectory",
            )
            @test report["historical_comparison"]["selected_dates"]["cell_ids"] ==
                  expected_ids
            @test report["historical_comparison"]["selected_dates"]["pfts"] ==
                  expected_pfts
            @test report["historical_comparison"]["selected_dates"]["forcing_regimes"] ==
                  expected_regimes
            @test all(
                metric["compared_values"] == 3length(expected_ids) for
                metric in values(
                    report["historical_comparison"]["selected_dates"]["variable"],
                )
            )
            @test report["historical_output"]["records"] == 114 * 365
            @test report["carbon_budget"]["all_close"]
            @test report["carbon_budget"]["workflow"]["close"]
            @test report["passive_restoration"]["carbon"]["verified"]
            @test report["passive_restoration"]["unaffected_verified"]
            @test report["passive_restoration"]["checkpoint_roundtrip_verified"]
            @test all(
                getproperty.(result.stages, :checkpoint_roundtrip_verified),
            )
            @test all(isfile, getproperty.(result.stages, :handoff_checkpoint))
            if configuration == :carbon_nitrogen
                initialization_groups =
                    report["initialization_comparison"]["comparison"]
                @test haskey(initialization_groups, "CASA soil-carbon")
                @test haskey(initialization_groups, "CASA soil-nitrogen")
                @test haskey(initialization_groups, "CASA plant-nitrogen")
                @test report["nitrogen_budget"]["all_close"]
                @test report["nitrogen_budget"]["workflow"]["close"]
                @test report["passive_restoration"]["nitrogen"]["verified"]
            end
            for stage in result.stages
                manifest = TOML.parsefile(stage.manifest)
                specification = only(
                    filter(
                        candidate -> candidate.name == stage.name,
                        TestbedSelectedCASAWorkflow.COMPLETE_STAGES,
                    ),
                )
                @test manifest["recorded_steps"] ==
                      TestbedNativeWorkflow.step_count(specification)
                @test manifest["state_updates"] == "ClimaTimeSteppers only"
            end
        end
    end
end
