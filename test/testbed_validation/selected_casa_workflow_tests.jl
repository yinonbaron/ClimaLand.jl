using Test
import Dates
import TOML

import NCDatasets

if !isdefined(@__MODULE__, :finish_representative_worker)
    include(joinpath(@__DIR__, "generate_selected_casa_workflow_reference.jl"))
end

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

@testset "selected CASA annual reducers preserve physical quantities" begin
    mktempdir() do directory
        path = joinpath(directory, "historical.nc")
        NCDatasets.NCDataset(path, "c") do output
            NCDatasets.defDim(output, "point", 2)
            NCDatasets.defDim(output, "time", 114 * 365)
            pool = NCDatasets.defVar(
                output,
                "casa_plant__c_leaf",
                Float64,
                ("point", "time"),
            )
            pool[:, :] .= 2
            flux = NCDatasets.defVar(
                output,
                "diagnostic__cgpp",
                Float64,
                ("point", "time"),
            )
            flux[:, :] .= 3
        end
        NCDatasets.NCDataset(path) do output
            reduced = TestbedSelectedCASAWorkflow.reduced_annual_values(
                output,
                Dict(
                    "annual_mean" => Dict("casa_plant.c_leaf" => Float64[]),
                    "end_of_year" => Dict("casa_plant.c_leaf" => Float64[]),
                    "annual_total" => Dict("diagnostic.cgpp" => Float64[]),
                ),
            )
            @test all(==(2), reduced["annual_mean"]["casa_plant.c_leaf"])
            @test all(==(2), reduced["end_of_year"]["casa_plant.c_leaf"])
            @test all(
                ==(3 * 365 * 86400),
                reduced["annual_total"]["diagnostic.cgpp"],
            )
        end
    end
end

@testset "selected-cell pinned reference contract" begin
    collection = TestbedReferenceCellComparisons.extended_cell_collection()
    reference =
        TestbedSelectedCASAWorkflow.workflow_reference(
            :carbon_only,
            collection,
        ).reference
    stage_names = collect(
        String.(
            getproperty.(TestbedSelectedCASAWorkflow.COMPLETE_STAGES, :name),
        ),
    )
    @test Int.(reference["cell_ids"]) == getproperty.(collection.cells, :id)
    expected_dates =
        string.([
            Dates.Date(year, month, 1) + Dates.Day(offset) for
            year in (1901, 1957, 2014) for month in (1, 4, 7, 10) for
            offset in 0:6
        ])
    @test reference["historical_coverage"]["dates"] == expected_dates
    @test reference["historical_coverage"]["final_boundary"] == "2014-12-31"
    for configuration in TestbedSelectedCASAWorkflow.supported_configurations()
        pinned = reference["configuration"][String(configuration)]
        measured = pinned["tolerance"]["fresh_fortran_boundary"]
        @test sort!(collect(keys(measured))) == sort(stage_names)
        @test all(
            haskey(tolerance, "measured_maximum_absolute_error") for
            stage in values(measured) for tolerance in values(stage)
        )
        if configuration == :carbon_nitrogen
            measured_errors = [
                tolerance["measured_maximum_absolute_error"] for
                stage in values(measured) for tolerance in values(stage)
            ]
            @test maximum(measured_errors) < 5e-3
        end
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
                if stage.name == :accelerated_spin
                    parameter = manifest["provenance"]["parameter_file"]
                    @test parameter["effective_passive_decay_rate_multiplier"] ==
                          10.0
                    @test occursin(
                        "accelerated-spin parameter file",
                        parameter["adjustment"],
                    )
                end
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
    cropland_mosaic = setup.normal.parameters[14]
    grassland = setup.normal.parameters[10]

    @test cropland_mosaic.leaf_phosphorus_to_nitrogen == 0.1
    @test grassland.leaf_phosphorus_to_nitrogen == inv(15.0)
    @test all(
        parameter.structural_litter_nitrogen_ratio == inv(150.0) for
        parameter in Base.values(setup.normal.parameters)
    )
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
    @test vec(
        Array(parent(setup.normal.model.casa_plant.nitrogen_parameters.active)),
    ) == map(point -> !setup.normal.parameters[point.pft].inactive, setup.grid)
    wood_lignin_nitrogen = vec(
        Array(
            parent(
                setup.normal.model.casa_plant.nitrogen_parameters.wood_lignin_nitrogen_ratio,
            ),
        ),
    )
    expected_wood_lignin_nitrogen = map(setup.grid) do point
        parameters = setup.normal.parameters[point.pft]
        inv(parameters.plant_nitrogen_ratio[2]) * parameters.lignin_wood
    end
    @test wood_lignin_nitrogen == expected_wood_lignin_nitrogen
    @test all(
        wood_lignin_nitrogen[index] == 60 for
        index in eachindex(setup.grid) if setup.grid[index].pft == 7
    )
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
    diagnostic_names =
        getproperty.(
            TestbedSelectedCASAWorkflow.default_diagnostics(
                :carbon_nitrogen,
                setup,
            ),
            :name,
        )
    @test "diagnostic__n_deposition" in diagnostic_names
    @test "diagnostic__n_net_mineralization" in diagnostic_names
end

@testset "selected-cell CASA-CN preserves the legacy first-step P:N" begin
    workflow = TestbedSelectedCASAWorkflow
    setup = workflow.load_setup(:carbon_nitrogen)
    model = setup.prespin.model
    field = model.casa_plant.parameters.leaf_phosphorus_to_nitrogen
    configured = copy(vec(parent(field)))

    fixed = workflow.use_initial_plant_stoichiometry!(
        model,
        setup.grid,
        setup.prespin.parameters,
        setup.initial_state,
    )

    initial_nitrogen = vec(parent(setup.initial_state.casa_plant.n_leaf))
    for (index, point) in enumerate(setup.grid)
        parameter = setup.prespin.parameters[point.pft]
        parameter.inactive && continue
        @test vec(parent(field))[index] ==
              parameter.initial_leaf_phosphorus / initial_nitrogen[index]
    end
    @test fixed == configured

    workflow.restore_plant_stoichiometry!(model, fixed)
    @test vec(parent(field)) == configured
end

@testset "selected-cell CASA-CN preserves legacy restart precision" begin
    workflow = TestbedSelectedCASAWorkflow
    state = workflow.load_setup(:carbon_nitrogen).initial_state
    fill!(parent(state.casa_plant.c_leaf), 0.41779600246129933)
    fill!(parent(state.casa_plant.c_labile), 0.0035819538579334293)
    fill!(parent(state.casa_soil.c_soil_passive), 2.137830043792065)
    fill!(parent(state.casa_soil.n_soil_passive), 0.07306635364914338)

    workflow.quantize_fortran_restart!(state, 10)

    @test all(==(0.417796002), parent(state.casa_plant.c_leaf))
    @test all(iszero, parent(state.casa_plant.c_labile))
    @test all(==(2.13783004), parent(state.casa_soil.c_soil_passive))
    @test all(==(0.07306635), parent(state.casa_soil.n_soil_passive))
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

    setup = TestbedSelectedCASAWorkflow.load_setup(
        :carbon_only;
        collection = subset,
    )
    reference =
        TestbedSelectedCASAWorkflow.workflow_reference(:carbon_only, subset)
    actual = TestbedSelectedCASAWorkflow.state_snapshot(setup.initial_state)
    malformed = copy(actual)
    malformed["casa_soil.c_soil_passive"] =
        malformed["casa_soil.c_soil_passive"][1:1]
    malformed_report = TestbedSelectedCASAWorkflow.compare_snapshot(
        malformed,
        reference.configuration["native_julia"]["initialization"],
        reference.configuration["tolerance"]["native_julia_initialization"],
        subset,
        reference.indices,
        TestbedReferenceCellComparisons.ConcurrencyBudget(1),
    )
    @test !malformed_report["all_match"]
    @test getindex.(malformed_report["cell_failures"], "cell_id") ==
          getproperty.(subset.cells, :id)

    reference_cell_count = length(reference.indices.by_id)
    ordered_report = TestbedSelectedCASAWorkflow.compare_snapshot(
        Dict(
            "casa_soil.c_soil_passive" => [0.0, 1.0],
            "casa_soil.n_soil_passive" => [1.0, 0.0],
        ),
        Dict(
            "casa_soil.c_soil_passive" => zeros(reference_cell_count),
            "casa_soil.n_soil_passive" => zeros(reference_cell_count),
        ),
        Dict("atol" => 0.0, "rtol" => 0.0),
        subset,
        reference.indices,
        TestbedReferenceCellComparisons.ConcurrencyBudget(2),
    )
    @test getindex.(ordered_report["cell_failures"], "cell_id") ==
          getproperty.(subset.cells, :id)
end

@testset "Representative CASA worker reports first Fortran nonfinites" begin
    cell_ids = [11, 22, 33]
    finite = [1.0, 2.0, 3.0]
    boundaries = Dict(
        stage => Dict("casa_plant.c_leaf" => copy(finite)) for
        stage in keys(STAGE_DIRECTORIES)
    )
    boundaries["accelerated_spin"]["casa_plant.c_leaf"][1] = Inf
    boundaries["historical"]["casa_plant.c_leaf"][1] = -Inf
    daily = Dict(
        "sample_days" => [1, 2],
        "casa_soil.n_mineral" => [1.0, NaN, 3.0, 1.0, NaN, 3.0],
    )
    annual = Dict(
        "years" => [1901, 1902],
        "annual_mean" => Dict(
            "casa_soil.c_soil_slow" => [1.0, 2.0, Inf, 1.0, 2.0, Inf],
        ),
        "annual_total" => Dict("diagnostic.cgpp" => ones(6)),
    )

    records = first_fortran_nonfinites(
        boundaries,
        annual,
        daily,
        cell_ids,
    )

    @test getindex.(records, "cell_id") == cell_ids
    @test getindex.(records, "first_nonfinite_stage") ==
          ["accelerated_spin", "historical", "historical"]
    @test getindex.(records, "first_nonfinite_date") ==
          ["1920-12-31", "1901-01-01", "1901-12-31"]
    @test getindex.(records, "first_nonfinite_variable") == [
        "casa_plant.c_leaf",
        "casa_soil.n_mineral",
        "annual_mean.casa_soil.c_soil_slow",
    ]
    @test all(record -> record["evidence_side"] == "fortran", records)
end

@testset "Representative CASA finish seam is exact and fail closed" begin
    mktempdir() do directory
        scope_path = joinpath(directory, "representative.toml")
        scope = Dict(
            "schema_version" => 1,
            "name" => "representative",
            "cell_ids" => collect(1:80),
        )
        open(scope_path, "w") do io
            TOML.print(io, scope; sorted = true)
        end
        fixture_file = joinpath(directory, "forcing.bin")
        write(fixture_file, "synthetic forcing marker")
        fixture_path = joinpath(directory, "fixture.toml")
        fixture = Dict(
            "schema_version" => 1,
            "selection" => Dict(
                "representative_cell_ids" => collect(1:80),
                "scope_manifest_sha256" =>
                    TestbedNativeWorkflow.sha256sum(scope_path),
            ),
            "fixture" => Dict(
                "forcing" => Dict(
                    "filename" => basename(fixture_file),
                    "bytes" => filesize(fixture_file),
                    "sha256" =>
                        TestbedNativeWorkflow.sha256sum(fixture_file),
                ),
            ),
            "cell" => [
                Dict("id" => id, "pft" => 1, "reasons" => ["synthetic"]) for
                id in 1:80
            ],
        )
        open(fixture_path, "w") do io
            TOML.print(io, fixture; sorted = true)
        end
        fortran_root = joinpath(directory, "fortran")
        mkpath(fortran_root)
        reference_template = joinpath(directory, "template.toml")
        write(reference_template, "schema_version = 1\n")
        build_metadata_path = joinpath(directory, "build_metadata.toml")
        write(build_metadata_path, "schema_version = 1\n")
        configurations = Symbol[]

        reference_builder = function (
            configuration,
            collection,
            root,
            template,
            output_path;
            build_metadata_path,
            scope_manifest_path,
        )
            push!(configurations, configuration)
            @test getproperty.(collection.cells, :id) == collect(1:80)
            @test root == fortran_root
            @test template == reference_template
            @test scope_manifest_path == scope_path
            @test isfile(build_metadata_path)
            write(output_path, "synthetic oracle")
            return (
                oracle_path = output_path,
                nonfinite_records = Dict{String, Any}[],
            )
        end
        julia_runner = function (output_root; kwargs...)
            @test kwargs[:reference_path] |> isfile
            @test kwargs[:compare_references]
            @test kwargs[:concurrency_budget].workers == 1
            mkpath(output_root)
            report = joinpath(output_root, "reconstruction_report.toml")
            write(report, "schema_version = 1\n")
            return (; report)
        end

        for configuration in (:carbon_only, :carbon_nitrogen)
            name = String(configuration)
            result = finish_representative_worker(
                configuration,
                fixture_path,
                scope_path,
                fortran_root,
                joinpath(directory, "julia-$name"),
                reference_template;
                build_metadata_path,
                oracle_path = joinpath(directory, "oracle-$name.toml"),
                reference_builder,
                julia_runner,
            )
            @test isfile(result.oracle_path)
            @test isfile(result.report_path)
            @test isempty(result.nonfinite_records)
        end
        @test configurations == [:carbon_only, :carbon_nitrogen]

        nonfinite = [
            nonfinite_record(
                1,
                "prespin",
                "1901-12-31",
                "casa_plant.c_leaf",
                "synthetic",
            ),
        ]
        blocked = finish_representative_worker(
            :carbon_only,
            fixture_path,
            scope_path,
            fortran_root,
            joinpath(directory, "julia-blocked"),
            reference_template;
            build_metadata_path,
            oracle_path = joinpath(directory, "oracle-blocked.toml"),
            reference_builder = (args...; kwargs...) -> (
                oracle_path = nothing,
                nonfinite_records = nonfinite,
            ),
            julia_runner = (args...; kwargs...) ->
                error("Julia must not run after Fortran nonfinite evidence"),
        )
        @test blocked.nonfinite_records == nonfinite
        @test isnothing(blocked.oracle_path)
        @test isnothing(blocked.julia)
        @test isnothing(blocked.report_path)

        julia_nonfinite = [
            Dict(
                "cell_id" => 2,
                "evidence_side" => "julia",
                "first_nonfinite_stage" => "historical",
                "first_nonfinite_date" => "1901-01-02",
                "first_nonfinite_step" => 2,
                "first_nonfinite_variable" => "casa_plant.c_leaf",
                "reason" =>
                    "native Julia CASA trajectory became nonfinite",
            ),
        ]
        throwing_runner = function (output_root; nonfinite_path, kwargs...)
            mkpath(output_root)
            open(nonfinite_path, "w") do io
                TOML.print(
                    io,
                    Dict(
                        "schema_version" => 1,
                        "model" => "CASA-C",
                        "scope" => "representative",
                        "nonfinite" => julia_nonfinite,
                    );
                    sorted = true,
                )
            end
            error("synthetic integration failure after nonfinite state")
        end
        observed = finish_representative_worker(
            :carbon_only,
            fixture_path,
            scope_path,
            fortran_root,
            joinpath(directory, "julia-nonfinite"),
            reference_template;
            build_metadata_path,
            oracle_path = joinpath(directory, "oracle-nonfinite.toml"),
            reference_builder,
            julia_runner = throwing_runner,
        )
        @test observed.nonfinite_records == julia_nonfinite
        @test isfile(observed.oracle_path)
        @test isnothing(observed.julia)
        @test isnothing(observed.report_path)

        @test_throws ErrorException finish_representative_worker(
            :carbon_only,
            fixture_path,
            scope_path,
            fortran_root,
            joinpath(directory, "julia-unexplained-error"),
            reference_template;
            build_metadata_path,
            oracle_path = joinpath(directory, "oracle-unexplained-error.toml"),
            reference_builder,
            julia_runner = (args...; kwargs...) -> error("unexplained"),
        )

        stale = deepcopy(fixture)
        stale["selection"]["scope_manifest_sha256"] = repeat("0", 64)
        open(fixture_path, "w") do io
            TOML.print(io, stale; sorted = true)
        end
        @test_throws ErrorException representative_collection(
            fixture_path,
            scope_path,
        )
        @test_throws ErrorException finish_representative_worker(
            :carbon_only,
            fixture_path,
            scope_path,
            fortran_root,
            joinpath(directory, "julia-missing-build"),
            reference_template;
            build_metadata_path = joinpath(directory, "missing-build.toml"),
        )
    end
end

@testset "selected CASA observes exact Julia trajectory nonfinites" begin
    mktempdir() do directory
        state = (
            casa_plant = (c_leaf = [1.0, 2.0, 3.0],),
            casa_soil = (c_soil_slow = [4.0, 5.0, 6.0],),
        )
        diagnostics = (
            (
                name = "diagnostic__cgpp",
                compute = (_, p) -> p.gpp,
            ),
        )
        path = joinpath(directory, "nonfinite_results.toml")
        observer = TestbedSelectedCASAWorkflow.NonfiniteObserver(
            [101, 202, 303],
            state,
            diagnostics;
            path,
            model = "CASA-C",
            scope = "representative",
        )
        stage = TestbedNativeWorkflow.NativeStage(:historical, 3, 1)
        state.casa_plant.c_leaf[2] = Inf
        observer(stage, 2, state, (; gpp = [1.0, 2.0, NaN]), 0.0)
        state.casa_soil.c_soil_slow[1] = -Inf
        state.casa_plant.c_leaf[2] = 2.0
        observer(stage, 3, state, (; gpp = [1.0, 2.0, 3.0]), 0.0)

        records = observer.records
        @test getindex.(records, "cell_id") == [101, 202, 303]
        @test getindex.(records, "evidence_side") == fill("julia", 3)
        @test getindex.(records, "first_nonfinite_stage") ==
              fill("historical", 3)
        @test getindex.(records, "first_nonfinite_date") ==
              ["1901-01-03", "1901-01-02", "1901-01-02"]
        @test getindex.(records, "first_nonfinite_step") == [3, 2, 2]
        @test getindex.(records, "first_nonfinite_variable") == [
            "casa_soil.c_soil_slow",
            "casa_plant.c_leaf",
            "diagnostic.cgpp",
        ]
        @test isfile(path)
        document = TOML.parsefile(path)
        @test document["schema_version"] == 1
        @test document["model"] == "CASA-C"
        @test document["scope"] == "representative"
        @test document["nonfinite"] == records

        state.casa_plant.c_leaf[2] = NaN
        observer(stage, 3, state, (; gpp = [1.0, 2.0, 3.0]), 0.0)
        @test observer.records == records
    end
end
