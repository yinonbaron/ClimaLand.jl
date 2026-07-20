using Test
import TOML

import NCDatasets

@testset "selected-cell complete CASA workflow contract" begin
    stages = TestbedSelectedCASAWorkflow.COMPLETE_STAGES

    @test getproperty.(stages, :name) ==
          (:prespin, :accelerated_spin, :normal_spin, :historical)
    @test getproperty.(stages, :forcing_days) ==
          (365, 20 * 365, 20 * 365, 114 * 365)
    @test getproperty.(stages, :repeats) == (100, 499, 499, 1)
    @test TestbedSelectedCASAWorkflow.supported_configurations() ==
          (:carbon_only, :carbon_nitrogen)
end

@testset "selected-cell pinned reference contract" begin
    collection = TestbedReferenceCellComparisons.extended_cell_collection()
    reference =
        TestbedSelectedCASAWorkflow.workflow_reference(:carbon_only, collection).reference
    stage_names = collect(
        String.(
            getproperty.(TestbedSelectedCASAWorkflow.COMPLETE_STAGES, :name),
        ),
    )
    @test Int.(reference["cell_ids"]) == getproperty.(collection.cells, :id)
    @test reference["historical_coverage"]["dates"] ==
          ["1901-01-01", "1957-07-02", "2014-12-31"]
    for configuration in TestbedSelectedCASAWorkflow.supported_configurations()
        pinned = reference["configuration"][String(configuration)]
        measured = pinned["tolerance"]["fresh_fortran_boundary"]
        @test sort!(collect(keys(measured))) == sort(stage_names)
        @test all(
            haskey(tolerance, "measured_maximum_absolute_error") for
            stage in values(measured) for tolerance in values(stage)
        )
        @test Set(
            keys(pinned["provenance"]["fresh_fortran_boundary_sha256"]),
        ) == Set(stage_names)
        expected_state_count = configuration == :carbon_only ? 10 : 20
        @test length(pinned["native_julia"]["initialization"]) ==
              expected_state_count
        @test haskey(pinned["tolerance"], "native_julia_initialization")
    end
end

@testset "selected-cell staged checkpoint handoff" begin
    stages = (
        TestbedNativeWorkflow.NativeStage(:prespin, 2, 1; write_output = false),
        TestbedNativeWorkflow.NativeStage(
            :accelerated_spin,
            2,
            1;
            write_output = false,
        ),
        TestbedNativeWorkflow.NativeStage(
            :normal_spin,
            2,
            1;
            write_output = false,
        ),
        TestbedNativeWorkflow.NativeStage(:historical, 3, 1),
    )
    for configuration in TestbedSelectedCASAWorkflow.supported_configurations()
        mktempdir() do output_root
            result = TestbedSelectedCASAWorkflow.run_selected_case(
                output_root;
                configuration,
                stages,
            )
            report = TOML.parsefile(result.report)

            @test getproperty.(result.stages, :name) ==
                  (:prespin, :accelerated_spin, :normal_spin, :historical)
            @test all(isfile, getproperty.(result.stages, :checkpoint))
            @test all(isfile, getproperty.(result.stages, :handoff_checkpoint))
            @test all(
                getproperty.(result.stages, :checkpoint_roundtrip_verified),
            )
            @test report["initialization_comparison"]["skipped"] ==
                  "reference comparison disabled"
            @test report["passive_restoration"]["carbon"]["verified"]
            @test report["passive_restoration"]["unaffected_verified"]
            unaffected = get(
                report["passive_restoration"],
                "unaffected_fields",
                String[],
            )
            @test !("casa_soil.c_soil_passive" in unaffected)
            @test report["passive_restoration"]["checkpoint_roundtrip_verified"]
            @test report["historical_output"]["records"] == 3
            @test report["carbon_budget"]["all_close"]
            @test report["carbon_budget"]["workflow"]["close"]
            if configuration == :carbon_nitrogen
                @test report["passive_restoration"]["nitrogen"]["verified"]
                @test !("casa_soil.n_soil_passive" in unaffected)
                @test length(unaffected) == 18
                @test report["nitrogen_budget"]["all_close"]
                @test report["nitrogen_budget"]["workflow"]["close"]
            else
                @test length(unaffected) == 9
            end
            for stage in result.stages
                manifest = TOML.parsefile(stage.manifest)
                @test manifest["state_updates"] == "ClimaTimeSteppers only"
            end
            NCDatasets.NCDataset(result.output) do output
                @test size(output["time"], 1) == 3
                if configuration == :carbon_nitrogen
                    @test haskey(output, "casa_plant__n_leaf")
                    @test haskey(output, "casa_soil__n_mineral")
                end
            end
        end
    end
end

@testset "selected-cell CASA-CN setup" begin
    setup = TestbedSelectedCASAWorkflow.load_setup(:carbon_nitrogen)

    @test getproperty.(setup.grid, :cell_id) == setup.cell_ids
    @test propertynames(setup.initial_state.casa_plant) == (
        :c_leaf,
        :c_wood,
        :c_fine_root,
        :c_labile,
        :n_leaf,
        :n_wood,
        :n_fine_root,
    )
    @test propertynames(setup.initial_state.casa_soil) == (
        :c_litter_metabolic,
        :c_litter_structural,
        :c_litter_cwd,
        :c_soil_microbial,
        :c_soil_slow,
        :c_soil_passive,
        :n_litter_metabolic,
        :n_litter_structural,
        :n_litter_cwd,
        :n_soil_microbial,
        :n_soil_slow,
        :n_soil_passive,
        :n_mineral,
    )
    @test setup.prespin.parameters[1].fixation_rate ==
          0.21 / 1000 / (365 * 86400)
    @test all(
        iszero,
        vec(
            Array(
                parent(
                    TestbedSelectedCASAWorkflow.PlantCASA.root_exudate_fraction.(
                        setup.normal.model.casa_plant.parameters,
                    ),
                ),
            ),
        ),
    )
    normal_rates = setup.normal.model.casa_soil.parameters.soil_base_rates
    accelerated_rates =
        setup.accelerated.model.casa_soil.parameters.soil_base_rates
    values(field) = vec(Array(parent(field)))
    @test values(getindex.(accelerated_rates, 1)) ==
          values(getindex.(normal_rates, 1))
    @test values(getindex.(accelerated_rates, 2)) ==
          values(getindex.(normal_rates, 2))
    @test values(getindex.(accelerated_rates, 3)) ==
          10 .* values(getindex.(normal_rates, 3))
    @test first(values(setup.initial_state.casa_soil.n_mineral)) == 0
    @test values(setup.initial_state.casa_soil.n_mineral)[2:end] == ones(10)
end

@testset "selected-cell CASA-C setup" begin
    collection = TestbedReferenceCellComparisons.ordinary_cell_collection()
    setup = TestbedSelectedCASAWorkflow.load_setup(:carbon_only; collection)

    @test getproperty.(setup.grid, :cell_id) == setup.cell_ids
    @test setup.cell_ids == getproperty.(collection.cells, :id)
    @test propertynames(setup.initial_state) == (:casa_plant, :casa_soil)
    @test propertynames(setup.initial_state.casa_plant) ==
          (:c_leaf, :c_wood, :c_fine_root, :c_labile)
    @test propertynames(setup.initial_state.casa_soil) == (
        :c_litter_metabolic,
        :c_litter_structural,
        :c_litter_cwd,
        :c_soil_microbial,
        :c_soil_slow,
        :c_soil_passive,
    )
    normal_rates = setup.normal.model.casa_soil.parameters.soil_base_rates
    accelerated_rates =
        setup.accelerated.model.casa_soil.parameters.soil_base_rates
    values(field) = vec(Array(parent(field)))
    @test values(getindex.(accelerated_rates, 1)) ==
          values(getindex.(normal_rates, 1))
    @test values(getindex.(accelerated_rates, 2)) ==
          values(getindex.(normal_rates, 2))
    @test values(getindex.(accelerated_rates, 3)) ==
          10 .* values(getindex.(normal_rates, 3))
    stoichiometry =
        TestbedNativeCASACReconstruction.CarbonOnlyPlantStoichiometry(
            setup.grid,
            setup.normal.parameters,
        )
    fill!(stoichiometry.nitrogen, -1)
    TestbedNativeCASACReconstruction.restore_stoichiometry!(
        stoichiometry,
        setup.initial_state,
    )
    @test stoichiometry.nitrogen ==
          max.(0.0, values(setup.initial_state.casa_plant.c_leaf)) .*
          stoichiometry.nitrogen_per_carbon
    initial_phase = copy(setup.forcing.phase)
    for day in 1:365
        TestbedNativeCASACReconstruction.update_phenology!(setup.forcing, day)
    end
    @test setup.forcing.phase == initial_phase
end

@testset "CASA comparison accepts replaceable cell collections" begin
    ordinary = TestbedReferenceCellComparisons.ordinary_cell_collection()
    subset = TestbedReferenceCellComparisons.subset(
        ordinary,
        getproperty.(ordinary.cells[1:2], :id),
    )
    for collection in (ordinary, subset)
        setup = TestbedSelectedCASAWorkflow.load_setup(:carbon_only; collection)
        reference = TestbedSelectedCASAWorkflow.workflow_reference(
            :carbon_only,
            collection,
        )
        comparison =
            TestbedSelectedCASAWorkflow.compare_initialization_reference(
                reference,
                setup.initial_state,
                collection,
                TestbedReferenceCellComparisons.ConcurrencyBudget(2),
            )
        @test comparison["all_match"]
        @test comparison["cell_ids"] == getproperty.(collection.cells, :id)
        @test comparison["provenance"] == reference.provenance
    end
end
