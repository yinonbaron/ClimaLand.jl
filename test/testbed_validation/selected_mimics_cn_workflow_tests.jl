using Test
import TOML

include(joinpath(@__DIR__, "selected_mimics_cn_workflow.jl"))
include(joinpath(@__DIR__, "generate_selected_mimics_cn_reference.jl"))
include(joinpath(@__DIR__, "generate_mimics_cn_boundary_calibration.jl"))
include(joinpath(@__DIR__, "generate_mimics_cn_historical_calibration.jl"))

const SelectedMIMICSCN = TestbedSelectedMIMICSCNWorkflow
const GenerateMIMICSCN = GenerateSelectedMIMICSCNReference
const MIMICSCNCalibration = TestbedMIMICSCNCalibration
const BoundaryCalibration = GenerateMIMICSCNBoundaryCalibration
const HistoricalCalibration = GenerateMIMICSCNHistoricalCalibration

function mimics_cn_test_collection(ids = [11, 22])
    return TestbedReferenceCellComparisons.ReferenceCellCollection(
        "representative",
        [
            TestbedReferenceCellComparisons.ReferenceCell(
                id,
                index,
                ["test cell $id"],
            ) for
            (index, id) in enumerate(ids)
        ],
        Dict{String, Any}(),
        Dict{String, String}(),
    )
end

function mimics_cn_test_policy()
    tolerance(names) =
        Dict(name => Dict("atol" => 0.0, "rtol" => 0.0) for name in names)
    return Dict(
        "fresh_fortran_boundary" => Dict(
            stage => tolerance(SelectedMIMICSCN.BOUNDARY_NAMES) for
            stage in SelectedMIMICSCN.STAGE_NAMES
        ),
        "fresh_fortran_annual" => Dict(
            "annual_mean" =>
                tolerance(SelectedMIMICSCN.ANNUAL_STATE_NAMES),
            "end_of_year" =>
                tolerance(SelectedMIMICSCN.ANNUAL_STATE_NAMES),
            "annual_total" =>
                tolerance(SelectedMIMICSCN.ANNUAL_FLUX_NAMES),
        ),
        "fresh_fortran_daily" =>
            tolerance(SelectedMIMICSCN.DAILY_NAMES),
        "fresh_fortran_budget" =>
            tolerance((
                "historical_residual_kg_c",
                "historical_residual_kg_n",
            )),
    )
end

function mimics_cn_test_reference(ids = [11, 22])
    cells = length(ids)
    years = length(SelectedMIMICSCN.HISTORICAL_YEARS)
    days = length(SelectedMIMICSCN.fixed_daily_sample_days())
    values(names, count) =
        Dict(name => fill(1.0, cells * count) for name in names)
    return Dict(
        "schema_version" => 1,
        "model" => "MIMICS-CN",
        "scope" => "representative",
        "cell_ids" => ids,
        "provenance" => Dict(
            "fortran_source_revision" => repeat("a", 40),
            "generator_sha256" => repeat("b", 64),
            "scope_manifest_sha256" => repeat("c", 64),
        ),
        "oracle" => Dict(
            "boundary" => Dict(
                stage => values(SelectedMIMICSCN.BOUNDARY_NAMES, 1) for
                stage in SelectedMIMICSCN.STAGE_NAMES
            ),
            "annual" => Dict(
                "years" => collect(SelectedMIMICSCN.HISTORICAL_YEARS),
                "annual_mean" =>
                    values(SelectedMIMICSCN.ANNUAL_STATE_NAMES, years),
                "end_of_year" =>
                    values(SelectedMIMICSCN.ANNUAL_STATE_NAMES, years),
                "annual_total" =>
                    values(SelectedMIMICSCN.ANNUAL_FLUX_NAMES, years),
            ),
            "daily" => Dict(
                "sample_days" => SelectedMIMICSCN.fixed_daily_sample_days(),
                "variable" => values(SelectedMIMICSCN.DAILY_NAMES, days),
            ),
            "budget" => Dict(
                "units" => Dict("carbon" => "kg C", "nitrogen" => "kg N"),
                "reducer" => "maximum_absolute_residual",
                "maximum_absolute_residual_kg_c" => 1.25,
                "historical_residual_kg_c" => [1.25, -1.0],
                "maximum_absolute_residual_kg_n" => 0.25,
                "historical_residual_kg_n" => [0.25, -0.1],
            ),
        ),
    )
end

function write_mimics_cn_test_reference(callback, reference)
    mktemp() do path, io
        TOML.print(io, reference; sorted = true)
        close(io)
        callback(path)
    end
end

@testset "MIMICS-CN calibration has no scientific absolute floor" begin
    zero = MIMICSCNCalibration.calibrated_envelope(
        zeros(3),
        zeros(3),
    )
    @test zero.raw_atol == 0.0
    @test zero.raw_rtol == 0.0
    @test zero.atol == zero.float_padding
    @test zero.atol <= 64eps(Float64) * floatmin(Float64)

    exact = MIMICSCNCalibration.calibrated_envelope(
        [0.0, 2.0, 100.0],
        [0.0, 2.0, 100.0],
    )
    @test exact.raw_atol == 0.0
    @test exact.raw_rtol == 0.0
    @test exact.atol == exact.float_padding
    @test exact.atol == 64eps(Float64) * 100

    fitted = MIMICSCNCalibration.calibrated_envelope(
        [1e-8, 2.001, 102.0],
        [0.0, 2.0, 100.0],
    )
    @test fitted.raw_atol >= 0
    @test fitted.raw_rtol >= 0
    @test all(
        fitted.errors .<=
        fitted.atol .+ fitted.rtol .* fitted.references,
    )
    @test_throws ErrorException MIMICSCNCalibration.calibrated_envelope(
        [1.0, Inf],
        [1.0, 2.0],
    )
end

@testset "MIMICS-CN consumes only fitted calibration policies" begin
    record = MIMICSCNCalibration.calibration_record(
        [1.0, 2.001],
        [1.0, 2.0];
        units = "kg C m^-2",
    )
    @test MIMICSCNCalibration.policy_record(record, "test") == Dict(
        "atol" => record["derived_policy"]["atol"],
        "rtol" => record["derived_policy"]["rtol"],
    )
    invalid = deepcopy(record)
    invalid["derived_policy"]["validation_failed_pairs"] = 1
    @test_throws ErrorException MIMICSCNCalibration.policy_record(
        invalid,
        "test",
    )
end

@testset "MIMICS-CN calibration records elemental units" begin
    @test BoundaryCalibration.units(:c_soil_available) == "kg C m^-2"
    @test BoundaryCalibration.units(:n_soil_available) == "kg N m^-2"
    @test HistoricalCalibration.units(
        "end_of_year",
        "mimics_soil.c_soil_available",
    ) == "kg C m^-2"
    @test HistoricalCalibration.units(
        "end_of_year",
        "mimics_soil.n_soil_available",
    ) == "kg N m^-2"
    @test HistoricalCalibration.units(
        "annual_total",
        "diagnostic.cnpp",
    ) == "kg C m^-2 year^-1"
    @test HistoricalCalibration.units(
        "daily",
        "diagnostic.n_deposition",
    ) == "kg N m^-2 s^-1"
end

@testset "MIMICS-CN boundary populations are immutable and reviewed" begin
    population_path = joinpath(
        @__DIR__,
        "validation",
        "mimics_cn_boundary_populations.toml",
    )
    scope_path =
        joinpath(@__DIR__, "validation", "scopes", "representative.toml")
    population = TOML.parsefile(population_path)
    random = only(population["population"])
    @test random["cell_count"] == 800
    @test random["eligible_cell_count"] == 790
    @test length(random["eligibility_gap"]) == 10
    @test all(gap -> gap["reviewed"] === true, random["eligibility_gap"])
    @test Set(Int.(getindex.(random["eligibility_gap"], "cell_id"))) ==
          Set([444, 633, 830, 1117, 1979, 1980, 12092, 13405, 13596, 13789])
    @test count(
        gap -> gap["first_nonfinite_stage"] == "historical",
        random["eligibility_gap"],
    ) == 1
    @test all(
        value -> occursin(r"^[0-9a-f]{64}$", value),
        (
            random["cell_ids_sha256"],
            random["grid_sha256"],
            random["selection_manifest_sha256"],
            BoundaryCalibration.sha256sum(population_path),
            BoundaryCalibration.sha256sum(scope_path),
        ),
    )
    scope = TOML.parsefile(scope_path)
    @test isempty(
        intersect(
            Set(Int.(scope["cell_ids"])),
            Set(Int.(getindex.(random["eligibility_gap"], "cell_id"))),
        ),
    )
end

@testset "MIMICS-CN calibration schema preserves coordinates and provenance" begin
    record = MIMICSCNCalibration.calibration_record(
        [1.2, 1.0],
        [1.0, 1.0];
        units = "kg C m^-2",
        observations = [
            (; cell_id = 11, latitude = -10.0, longitude = 20.0),
            (; cell_id = 22, latitude = 30.0, longitude = -40.0),
        ],
    )
    @test record["top_outlier"][1]["cell_id"] == 11
    @test record["top_outlier"][1]["latitude"] == -10.0
    @test record["top_outlier"][1]["longitude"] == 20.0
    @test record["derived_policy"]["validation_failed_pairs"] == 0

    generator_path =
        joinpath(@__DIR__, "generate_mimics_cn_boundary_calibration.jl")
    calibration_path = joinpath(@__DIR__, "mimics_cn_calibration.jl")
    @test occursin(
        r"^[0-9a-f]{64}$",
        BoundaryCalibration.sha256sum(generator_path),
    )
    @test occursin(
        r"^[0-9a-f]{64}$",
        BoundaryCalibration.sha256sum(calibration_path),
    )
end

@testset "frozen MIMICS-CN calibrations cover both populations" begin
    boundary_path = joinpath(
        @__DIR__,
        "validation",
        "mimics_cn_boundary_calibration.toml",
    )
    historical_path = joinpath(
        @__DIR__,
        "validation",
        "mimics_cn_historical_calibration.toml",
    )
    boundary = TOML.parsefile(boundary_path)
    historical = TOML.parsefile(historical_path)

    @test boundary["union_cell_count"] == 852
    @test Set(keys(boundary["population_validation"])) ==
          Set(("random_pft_800", "representative"))
    @test boundary["source_provenance"]["population"]["random_pft_800"][
        "eligible_cell_count"
    ] == 790
    @test boundary["source_provenance"]["population"]["representative"][
        "eligible_cell_count"
    ] == 80
    @test boundary["deduplication"]["overlapping_cell_count"] == 18
    @test boundary["deduplication"]["duplicate_pair_count"] == 18 * 4 * 24
    @test all(
        record["failed_pairs"] == 0 for population in
        values(boundary["population_validation"]) for stage in
        values(population) for record in values(stage)
    )
    @test all(
        record["finite_pair_count"] == 852 &&
        record["derived_policy"]["validation_failed_pairs"] == 0 &&
        length(record["top_outlier"]) == 6 &&
        all(
            outlier -> all(
                key -> haskey(outlier, key),
                ("cell_id", "latitude", "longitude", "pft"),
            ),
            record["top_outlier"],
        ) for stage in values(boundary["variable"]) for
        record in values(stage)
    )

    annual = [
        record for reducer in values(historical["annual"]) for
        record in values(reducer)
    ]
    daily = collect(values(historical["daily"]))
    budget = collect(values(historical["budget"]))
    @test length(annual) + length(daily) + length(budget) == 109
    @test all(record["finite_pair_count"] == 80 * 114 for record in annual)
    @test all(record["finite_pair_count"] == 80 * 84 for record in daily)
    @test all(record["finite_pair_count"] == 80 for record in budget)
    @test all(
        record["derived_policy"]["validation_failed_pairs"] == 0 for
        record in vcat(annual, daily, budget)
    )
    @test all(
        all(
            observation -> haskey(observation, "pft"),
            vcat(
                record["top_outlier"],
                record["active_constraint"]["observation"],
            ),
        ) for record in vcat(annual, daily, budget)
    )
    @test Set(getindex.(budget, "units")) == Set(("kg C", "kg N"))

    for (document, generator, calibration) in (
        (
            boundary,
            "generate_mimics_cn_boundary_calibration.jl",
            "mimics_cn_calibration.jl",
        ),
        (
            historical,
            "generate_mimics_cn_historical_calibration.jl",
            "mimics_cn_calibration.jl",
        ),
    )
        @test document["source_provenance"]["generator"]["sha256"] ==
              BoundaryCalibration.sha256sum(joinpath(@__DIR__, generator))
        @test document["source_provenance"]["calibration"]["sha256"] ==
              BoundaryCalibration.sha256sum(joinpath(@__DIR__, calibration))
    end
    @test !occursin(r"/Users/|/private/tmp|absolute_floor", read(boundary_path, String))
    @test !occursin(r"/Users/|/private/tmp|absolute_floor", read(historical_path, String))

    policy = MIMICSCNCalibration.comparison_policy(
        boundary_path,
        historical_path,
    )
    @test isnothing(SelectedMIMICSCN.validate_policy(policy))

    mktempdir() do directory
        invalid_boundary_path = joinpath(directory, "boundary.toml")
        invalid_historical_path = joinpath(directory, "historical.toml")
        function rejects(boundary_document, historical_document)
            open(invalid_boundary_path, "w") do io
                TOML.print(io, boundary_document; sorted = true)
            end
            open(invalid_historical_path, "w") do io
                TOML.print(io, historical_document; sorted = true)
            end
            return try
                MIMICSCNCalibration.comparison_policy(
                    invalid_boundary_path,
                    invalid_historical_path,
                )
                false
            catch error
                error isa ErrorException
            end
        end

        invalid_boundary = deepcopy(boundary)
        delete!(invalid_boundary, "model")
        @test rejects(invalid_boundary, historical)

        invalid_boundary = deepcopy(boundary)
        invalid_boundary["model"] = "MIMICS-C"
        @test rejects(invalid_boundary, historical)

        invalid_historical = deepcopy(historical)
        delete!(invalid_historical, "model")
        @test rejects(boundary, invalid_historical)

        invalid_historical = deepcopy(historical)
        invalid_historical["model"] = "MIMICS-C"
        @test rejects(boundary, invalid_historical)

        invalid_boundary = deepcopy(boundary)
        invalid_boundary["calibration_id"] = "wrong"
        @test rejects(invalid_boundary, historical)

        invalid_historical = deepcopy(historical)
        invalid_historical["calibration_id"] = "wrong"
        @test rejects(boundary, invalid_historical)

        invalid_boundary = deepcopy(boundary)
        delete!(invalid_boundary["method"], "selection")
        @test rejects(invalid_boundary, historical)

        invalid_boundary = deepcopy(boundary)
        invalid_boundary["source_provenance"]["population"]["representative"][
            "eligible_cell_count"
        ] = 79
        @test rejects(invalid_boundary, historical)

        invalid_boundary = deepcopy(boundary)
        invalid_boundary["source_provenance"]["calibration"]["sha256"] =
            repeat("0", 64)
        @test rejects(invalid_boundary, historical)

        invalid_historical = deepcopy(historical)
        invalid_historical["source_provenance"]["fresh_fortran_oracle"][
            "scope_manifest_sha256"
        ] = repeat("0", 64)
        @test rejects(boundary, invalid_historical)
    end
end

@testset "MIMICS-CN generator reads only supplied NetCDF locations" begin
    mktempdir() do directory
        path = joinpath(directory, "fresh_daily.nc")
        NCDatasets.NCDataset(path, "c") do dataset
            NCDatasets.defDim(dataset, "lon", 3)
            NCDatasets.defDim(dataset, "lat", 2)
            NCDatasets.defDim(dataset, "time", 365)
            variable = NCDatasets.defVar(
                dataset,
                "pool",
                Float64,
                ("lon", "lat", "time"),
            )
            variable[:, :, :] .= reshape(1.0:(3 * 2 * 365), 3, 2, 365)
        end
        grid = [
            (; cell_id = 22, longitude_index = 3, latitude_index = 2),
            (; cell_id = 11, longitude_index = 1, latitude_index = 1),
        ]
        values = NCDatasets.NCDataset(path) do dataset
            GenerateMIMICSCN.reference_matrix(
                dataset,
                path,
                "pool",
                grid,
            )
        end
        @test size(values) == (2, 365)
        @test values[1, :] ==
              reshape(1.0:(3 * 2 * 365), 3, 2, 365)[3, 2, :]
        @test values[2, :] ==
              reshape(1.0:(3 * 2 * 365), 3, 2, 365)[1, 1, :]
    end
end

@testset "MIMICS-CN reference budget excludes unapplied inactive deposition" begin
    points = 2
    years = length(SelectedMIMICSCN.HISTORICAL_YEARS)
    boundary = Dict(
        stage => Dict(
            name => zeros(points) for
            name in SelectedMIMICSCN.BOUNDARY_NAMES
        ) for
        stage in ("spin_continuation", "historical")
    )
    nitrogen_name = first(
        filter(
            name -> occursin(".n_", name),
            SelectedMIMICSCN.BOUNDARY_NAMES,
        ),
    )
    boundary["historical"][nitrogen_name][1] = 1.0
    deposition = zeros(points, years)
    deposition[1, 1] = 1.0
    deposition[2, 1] = 2.0
    annual = Dict(
        "annual_total" => Dict(
            "diagnostic.cnpp" => zeros(points * years),
            "diagnostic.mimics_respiration" => zeros(points * years),
            "diagnostic.n_deposition" => vec(deposition),
            "diagnostic.n_fixation" => zeros(points * years),
            "diagnostic.n_leaching" => zeros(points * years),
            "diagnostic.n_gaseous_loss" => zeros(points * years),
        ),
    )
    grid = [
        (; area_m2 = 1.0, active = true),
        (; area_m2 = 1.0, active = false),
    ]

    budget = GenerateMIMICSCN.budget_values(boundary, annual, grid)

    @test budget["historical_residual_kg_n"] == [0.0, 0.0]
end

@testset "MIMICS-CN reduced oracle accepts a replaceable exact collection" begin
    collection = mimics_cn_test_collection()
    reference = mimics_cn_test_reference()
    write_mimics_cn_test_reference(reference) do path
        loaded = SelectedMIMICSCN.workflow_reference(
            collection;
            path,
            comparison_policy = mimics_cn_test_policy(),
        )
        @test loaded.cell_ids == [11, 22]
        @test loaded.eligible_ids == [11, 22]
        @test isempty(loaded.eligibility_gaps)
        @test loaded.oracle["budget"]["reducer"] ==
              "maximum_absolute_residual"
        @test loaded.oracle["budget"]["units"] ==
              Dict("carbon" => "kg C", "nitrogen" => "kg N")
        @test length(loaded.oracle["daily"]["sample_days"]) == 84
    end

    reversed = mimics_cn_test_collection([22, 11])
    write_mimics_cn_test_reference(reference) do path
        @test_throws ErrorException SelectedMIMICSCN.workflow_reference(
            reversed;
            path,
            comparison_policy = mimics_cn_test_policy(),
        )
    end
end

@testset "MIMICS-CN eligibility is atomic and eligible nonfinites fail" begin
    collection = mimics_cn_test_collection()
    reference = mimics_cn_test_reference()
    reference["oracle"]["annual"]["annual_mean"][first(
        SelectedMIMICSCN.ANNUAL_STATE_NAMES,
    )][2] = Inf
    write_mimics_cn_test_reference(reference) do path
        error = try
            SelectedMIMICSCN.workflow_reference(
                collection;
                path,
                comparison_policy = mimics_cn_test_policy(),
            )
            nothing
        catch caught
            caught
        end
        @test error isa ErrorException
        @test occursin("eligible nonfinite", sprint(showerror, error))
        @test occursin("cell 22", sprint(showerror, error))
    end

    gap = Dict(
        "model" => "MIMICS-CN",
        "cell_id" => 22,
        "reason" => "fresh Fortran trajectory becomes nonfinite",
        "reviewed" => true,
        "first_nonfinite_stage" => "historical",
        "first_nonfinite_date" => "1901-01-01",
        "first_nonfinite_variable" =>
            first(SelectedMIMICSCN.ANNUAL_STATE_NAMES),
    )
    write_mimics_cn_test_reference(reference) do path
        loaded = SelectedMIMICSCN.workflow_reference(
            collection;
            path,
            comparison_policy = mimics_cn_test_policy(),
            eligibility_gaps = [gap],
        )
        @test loaded.eligible_ids == [11]
        @test loaded.eligibility_gaps == [gap]
    end
end

@testset "MIMICS-CN comparison reports a scientific failure by cell" begin
    collection = mimics_cn_test_collection()
    reference = mimics_cn_test_reference()
    expected = reference["oracle"]["boundary"]["prespin"]
    actual = deepcopy(expected)
    variable = first(SelectedMIMICSCN.BOUNDARY_NAMES)
    actual[variable][2] += 1
    comparison = SelectedMIMICSCN.compare_payload(
        actual,
        expected,
        mimics_cn_test_policy()["fresh_fortran_boundary"]["prespin"],
        collection,
        Dict(11 => 1, 22 => 2),
    )
    @test !comparison["all_match"]
    @test only(comparison["cell_failures"])["cell_id"] == 22
    @test comparison["variable"][variable]["failed_values"] == 1

    write_mimics_cn_test_reference(reference) do path
        loaded = SelectedMIMICSCN.workflow_reference(
            collection;
            path,
            comparison_policy = mimics_cn_test_policy(),
        )
        budget = deepcopy(reference["oracle"]["budget"])
        budget["historical_residual_kg_c"][2] = 0.0
        budget["maximum_absolute_residual_kg_c"] = 1.25
        budget["historical_residual_kg_n"][2] = 0.0
        budget["maximum_absolute_residual_kg_n"] = 0.25
        report = SelectedMIMICSCN.compare_budget_reference(
            loaded,
            budget,
            collection,
            TestbedReferenceCellComparisons.ConcurrencyBudget(1),
        )
        @test !report["all_match"]
        @test only(report["cell_failures"])["cell_id"] == 22
        @test report["reducer"] == "maximum_absolute_residual"
        @test report["units"] ==
              Dict("carbon" => "kg C", "nitrogen" => "kg N")
    end
end

@testset "selected MIMICS-CN setup uses the supplied cells exactly" begin
    core = TestbedReferenceCellComparisons.core_cell_collection()
    collection = TestbedReferenceCellComparisons.subset(
        core,
        getproperty.(core.cells[1:2], :id),
    )
    setup = SelectedMIMICSCN.load_setup(; collection)
    @test setup.cell_ids == getproperty.(collection.cells, :id)
    @test getproperty.(setup.grid, :cell_id) == setup.cell_ids
    @test propertynames(setup.initial_state) == (:casa_plant, :mimics_soil)
    @test propertynames(setup.initial_state.mimics_soil) == (
        :c_litter_metabolic,
        :c_litter_structural,
        :c_litter_cwd,
        :c_microbe_r,
        :c_microbe_k,
        :c_soil_available,
        :c_soil_chemical,
        :c_soil_physical,
        :n_litter_metabolic,
        :n_litter_structural,
        :n_microbe_r,
        :n_microbe_k,
        :n_soil_available,
        :n_soil_chemical,
        :n_soil_physical,
        :n_litter_cwd,
        :n_mineral,
    )
    stage = TestbedNativeWorkflow.NativeStage(
        :prespin,
        365,
        1;
        write_output = false,
    )
    SelectedMIMICSCN.update_forcing!(setup.forcing, stage, 1, 0.0)
    @test all(isfinite, vec(parent(setup.buffers.liquid_saturation)))
    @test all(isfinite, vec(parent(setup.buffers.frozen_saturation)))
    @test all(isfinite, vec(parent(setup.buffers.annual_npp)))
end

@testset "selected MIMICS-CN short workflow reports budgets" begin
    core = TestbedReferenceCellComparisons.core_cell_collection()
    collection = TestbedReferenceCellComparisons.subset(
        core,
        getproperty.(core.cells[1:2], :id),
    )
    stages = (
        TestbedNativeWorkflow.NativeStage(
            :prespin,
            2,
            1;
            write_output = false,
        ),
        TestbedNativeWorkflow.NativeStage(
            :spin,
            2,
            1;
            write_output = false,
        ),
        TestbedNativeWorkflow.NativeStage(
            :spin_continuation,
            2,
            1;
            write_output = false,
        ),
        TestbedNativeWorkflow.NativeStage(:historical, 2, 1),
    )
    mktempdir() do output_root
        result = SelectedMIMICSCN.run_selected_case(
            output_root;
            collection,
            stages,
            compare_references = false,
        )
        report = TOML.parsefile(result.report)
        @test report["coverage"]["scope_cell_ids"] ==
              getproperty.(collection.cells, :id)
        @test report["coverage"]["compared_cells"] == 2
        @test isempty(report["coverage"]["eligibility_gaps"])
        @test report["carbon_budget"]["all_close"]
        @test report["carbon_budget"]["reducer"] ==
              "maximum_absolute_residual"
        @test report["carbon_budget"]["units"] == "kg C"
        @test isfinite(
            report["carbon_budget"]["maximum_absolute_residual_kg_c"],
        )
        @test report["nitrogen_budget"]["all_close"]
        @test report["nitrogen_budget"]["reducer"] ==
              "maximum_absolute_residual"
        @test report["nitrogen_budget"]["units"] == "kg N"
        @test isfinite(
            report["nitrogen_budget"]["maximum_absolute_residual_kg_n"],
        )
    end
end
