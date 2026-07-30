using Test
import SHA
import TOML

include(joinpath(@__DIR__, "selected_mimics_c_workflow.jl"))
include(joinpath(@__DIR__, "generate_selected_mimics_c_reference.jl"))
include(joinpath(@__DIR__, "generate_mimics_c_boundary_calibration.jl"))
include(joinpath(@__DIR__, "generate_mimics_c_historical_calibration.jl"))

const SelectedMIMICSC = TestbedSelectedMIMICSCWorkflow
const GenerateMIMICSC = GenerateSelectedMIMICSCReference
const MIMICSCCalibration = TestbedMIMICSCCalibration
const BoundaryCalibration = GenerateMIMICSCBoundaryCalibration
const HistoricalCalibration = GenerateMIMICSCHistoricalCalibration

function mimics_c_test_collection(ids = [11, 22])
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

function mimics_c_test_policy()
    tolerance(names) =
        Dict(name => Dict("atol" => 0.0, "rtol" => 0.0) for name in names)
    return Dict(
        "fresh_fortran_boundary" => Dict(
            stage => tolerance(SelectedMIMICSC.BOUNDARY_NAMES) for
            stage in SelectedMIMICSC.STAGE_NAMES
        ),
        "fresh_fortran_annual" => Dict(
            "annual_mean" =>
                tolerance(SelectedMIMICSC.ANNUAL_STATE_NAMES),
            "end_of_year" =>
                tolerance(SelectedMIMICSC.ANNUAL_STATE_NAMES),
            "annual_total" =>
                tolerance(SelectedMIMICSC.ANNUAL_FLUX_NAMES),
        ),
        "fresh_fortran_daily" =>
            tolerance(SelectedMIMICSC.DAILY_NAMES),
        "fresh_fortran_budget" =>
            tolerance(("historical_residual_kg_c",)),
    )
end

function mimics_c_test_reference(ids = [11, 22])
    cells = length(ids)
    years = length(SelectedMIMICSC.HISTORICAL_YEARS)
    days = length(SelectedMIMICSC.fixed_daily_sample_days())
    values(names, count) =
        Dict(name => fill(1.0, cells * count) for name in names)
    return Dict(
        "schema_version" => 1,
        "model" => "MIMICS-C",
        "scope" => "representative",
        "cell_ids" => ids,
        "cell" => [
            Dict(
                "cell_id" => id,
                "pft" => index,
                "latitude" => -45.0 + index,
                "longitude" => 90.0 + index,
            ) for (index, id) in enumerate(ids)
        ],
        "provenance" => Dict(
            "fortran_source_revision" => repeat("a", 40),
            "generator_sha256" => repeat("b", 64),
            "scope_manifest_sha256" => repeat("c", 64),
        ),
        "oracle" => Dict(
            "boundary" => Dict(
                stage => values(SelectedMIMICSC.BOUNDARY_NAMES, 1) for
                stage in SelectedMIMICSC.STAGE_NAMES
            ),
            "annual" => Dict(
                "years" => collect(SelectedMIMICSC.HISTORICAL_YEARS),
                "annual_mean" =>
                    values(SelectedMIMICSC.ANNUAL_STATE_NAMES, years),
                "end_of_year" =>
                    values(SelectedMIMICSC.ANNUAL_STATE_NAMES, years),
                "annual_total" =>
                    values(SelectedMIMICSC.ANNUAL_FLUX_NAMES, years),
            ),
            "daily" => Dict(
                "sample_days" => SelectedMIMICSC.fixed_daily_sample_days(),
                "variable" => values(SelectedMIMICSC.DAILY_NAMES, days),
            ),
            "budget" => Dict(
                "units" => "kg C",
                "reducer" => "maximum_absolute_residual",
                "maximum_absolute_residual_kg_c" => 1.25,
                "historical_residual_kg_c" => [1.25, -1.0],
            ),
        ),
    )
end

function write_mimics_c_test_reference(
    callback,
    reference;
    gaps = Any[],
)
    mktemp() do path, io
        scope = Dict(
            "schema_version" => 1,
            "name" => "representative",
            "cell_ids" => reference["cell_ids"],
            "eligibility_gaps" => gaps,
        )
        TOML.print(io, scope; sorted = true)
        close(io)
        reference["provenance"]["scope_manifest_sha256"] =
            bytes2hex(SHA.sha256(read(path)))
        mktemp() do reference_path, reference_io
            TOML.print(reference_io, reference; sorted = true)
            close(reference_io)
            callback(reference_path, path)
        end
    end
end

@testset "MIMICS-C calibration has no scientific absolute floor" begin
    zero = MIMICSCCalibration.calibrated_envelope(
        zeros(3),
        zeros(3),
    )
    @test zero.raw_atol == 0.0
    @test zero.raw_rtol == 0.0
    @test zero.atol == zero.float_padding
    @test zero.atol <= 64eps(Float64) * floatmin(Float64)

    exact = MIMICSCCalibration.calibrated_envelope(
        [0.0, 2.0, 100.0],
        [0.0, 2.0, 100.0],
    )
    @test exact.raw_atol == 0.0
    @test exact.raw_rtol == 0.0
    @test exact.atol == exact.float_padding
    @test exact.atol == 64eps(Float64) * 100

    fitted = MIMICSCCalibration.calibrated_envelope(
        [1e-8, 2.001, 102.0],
        [0.0, 2.0, 100.0],
    )
    @test fitted.raw_atol >= 0
    @test fitted.raw_rtol >= 0
    @test all(
        fitted.errors .<=
        fitted.atol .+ fitted.rtol .* fitted.references,
    )
    @test_throws ErrorException MIMICSCCalibration.calibrated_envelope(
        [1.0, Inf],
        [1.0, 2.0],
    )
    @test_throws ErrorException MIMICSCCalibration.calibration_record(
        [1.0],
        [nextfloat(0.0)];
        units = "kg C m^-2",
    )
end

@testset "MIMICS-C calibration preserves observation coordinates" begin
    record = MIMICSCCalibration.calibration_record(
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
end

@testset "MIMICS-C calibration populations are immutable" begin
    population_path = joinpath(
        @__DIR__,
        "validation",
        "mimics_c_boundary_population.toml",
    )
    population = TOML.parsefile(population_path)["population"]
    @test population["label"] == "global"
    @test population["cell_count"] == 4263
    @test population["eligible_cell_count"] == 4263
    @test isempty(population["eligibility_gaps"])
    @test all(
        value -> occursin(r"^[0-9a-f]{64}$", value),
        (
            population["cell_ids_sha256"],
            population["grid_sha256"],
            BoundaryCalibration.sha256sum(population_path),
        ),
    )
    @test HistoricalCalibration.eligible_values(
        [1.0, 2.0, 3.0, 4.0],
        [11, 22],
        [22],
    ) == [2.0, 4.0]
end

@testset "MIMICS-C consumes only fitted calibration policies" begin
    cells = (
        (; cell_id = 11, pft = 1, latitude = -10.0, longitude = 20.0),
        (; cell_id = 22, pft = 2, latitude = 30.0, longitude = -40.0),
    )
    record(observations, units = "kg C m^-2") =
        MIMICSCCalibration.calibration_record(
            fill(1.001, length(observations)),
            ones(length(observations));
            units,
            observations,
        )
    annual_observations = [
        merge(cell, (; year)) for year in 1901:2014 for cell in cells
    ]
    daily_observations = [
        merge(
            cell,
            (;
                sample_day,
                year = 1901 + (sample_day - 1) ÷ 365,
                day_of_year = mod1(sample_day, 365),
            ),
        ) for sample_day in SelectedMIMICSC.fixed_daily_sample_days() for
        cell in cells
    ]
    digest() = Dict("sha256" => repeat("a", 64))
    method = Dict(
        "error" => "e_i = abs(Julia_i - Fortran_i)",
        "reference_magnitude" => "x_i = abs(Fortran_i)",
        "raw_absolute" => "a(r) = max(0, max_i(e_i - r*x_i))",
        "selection" => "smallest minimizing r",
        "safety_margin" => "5% plus scale-aware Float64 padding",
        "nonfinite" => "fail",
    )
    boundary_provenance = Dict{String, Any}(
        name => digest() for name in (
            "population_manifest",
            "grid",
            "casa_parameters",
            "mimics_parameters",
            "fresh_fortran_build",
            "fresh_fortran_workflow",
        )
    )
    boundary_provenance["git_revision_basis"] = repeat("b", 40)
    boundary_provenance["julia_version"] = string(VERSION)
    boundary_provenance["generator"] = Dict(
        "id" => "generate_mimics_c_boundary_calibration.jl",
        "sha256" => BoundaryCalibration.sha256sum(
            joinpath(@__DIR__, "generate_mimics_c_boundary_calibration.jl"),
        ),
    )
    boundary_provenance["calibration"] = Dict(
        "id" => "mimics_c_calibration.jl",
        "sha256" => BoundaryCalibration.sha256sum(
            joinpath(@__DIR__, "mimics_c_calibration.jl"),
        ),
    )
    boundary = Dict(
        "schema_version" => 1,
        "model" => "MIMICS-C",
        "eligible_cell_count" => 2,
        "method" => method,
        "source_provenance" => boundary_provenance,
        "variable" => Dict(
            stage => Dict(name => record(cells) for name in
                SelectedMIMICSC.BOUNDARY_NAMES) for
            stage in SelectedMIMICSC.STAGE_NAMES
        ),
    )
    historical_provenance = Dict{String, Any}(
        name => digest() for name in (
            "scope_manifest",
            "current_julia_output",
            "current_julia_report",
            "fresh_fortran_oracle",
        )
    )
    historical_provenance["git_revision_basis"] = repeat("b", 40)
    historical_provenance["julia_version"] = string(VERSION)
    historical_provenance["generator"] = Dict(
        "id" => "generate_mimics_c_historical_calibration.jl",
        "sha256" => HistoricalCalibration.sha256sum(
            joinpath(@__DIR__, "generate_mimics_c_historical_calibration.jl"),
        ),
    )
    historical_provenance["calibration"] = Dict(
        "id" => "mimics_c_calibration.jl",
        "sha256" => HistoricalCalibration.sha256sum(
            joinpath(@__DIR__, "mimics_c_calibration.jl"),
        ),
    )
    historical = Dict(
        "schema_version" => 1,
        "model" => "MIMICS-C",
        "eligible_cell_count" => 2,
        "method" => method,
        "source_provenance" => historical_provenance,
        "annual" => Dict(
            "annual_mean" => Dict(
                name => record(annual_observations) for
                name in SelectedMIMICSC.ANNUAL_STATE_NAMES
            ),
            "end_of_year" => Dict(
                name => record(annual_observations) for
                name in SelectedMIMICSC.ANNUAL_STATE_NAMES
            ),
            "annual_total" => Dict(
                name => record(
                    annual_observations,
                    "kg C m^-2 year^-1",
                ) for
                name in SelectedMIMICSC.ANNUAL_FLUX_NAMES
            ),
        ),
        "daily" => Dict(
            name => record(daily_observations) for
            name in SelectedMIMICSC.DAILY_NAMES
        ),
        "budget" => record(cells, "kg C"),
    )
    mktempdir() do directory
        boundary_path = joinpath(directory, "boundary.toml")
        historical_path = joinpath(directory, "historical.toml")
        open(boundary_path, "w") do io
            TOML.print(io, boundary)
        end
        open(historical_path, "w") do io
            TOML.print(io, historical)
        end
        policy = MIMICSCCalibration.comparison_policy(
            boundary_path,
            historical_path,
        )
        SelectedMIMICSC.validate_policy(policy)
        @test policy["fresh_fortran_daily"][first(
            SelectedMIMICSC.DAILY_NAMES,
        )] == Dict(
            "atol" => historical["daily"][first(
                SelectedMIMICSC.DAILY_NAMES,
            )]["derived_policy"]["atol"],
            "rtol" => historical["daily"][first(
                SelectedMIMICSC.DAILY_NAMES,
            )]["derived_policy"]["rtol"],
        )

        stale = deepcopy(boundary)
        stale["source_provenance"]["calibration"]["sha256"] =
            repeat("0", 64)
        open(boundary_path, "w") do io
            TOML.print(io, stale)
        end
        @test_throws ErrorException MIMICSCCalibration.comparison_policy(
            boundary_path,
            historical_path,
        )

        open(boundary_path, "w") do io
            TOML.print(io, boundary)
        end
        incomplete = deepcopy(historical)
        delete!(
            incomplete["daily"][first(SelectedMIMICSC.DAILY_NAMES)][
                "top_outlier"
            ][1],
            "latitude",
        )
        open(historical_path, "w") do io
            TOML.print(io, incomplete)
        end
        @test_throws ErrorException MIMICSCCalibration.comparison_policy(
            boundary_path,
            historical_path,
        )
    end
end

@testset "MIMICS-C generator reads only supplied NetCDF locations" begin
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
            GenerateMIMICSC.reference_matrix(
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

@testset "MIMICS-C reduced oracle accepts a replaceable exact collection" begin
    collection = mimics_c_test_collection()
    reference = mimics_c_test_reference()
    write_mimics_c_test_reference(reference) do path, scope_path
        loaded = SelectedMIMICSC.workflow_reference(
            collection;
            path,
            comparison_policy = mimics_c_test_policy(),
            scope_manifest_path = scope_path,
        )
        @test loaded.cell_ids == [11, 22]
        @test loaded.eligible_ids == [11, 22]
        @test isempty(loaded.eligibility_gaps)
        @test loaded.oracle["budget"]["reducer"] ==
              "maximum_absolute_residual"
        @test loaded.oracle["budget"]["units"] == "kg C"
        @test length(loaded.oracle["daily"]["sample_days"]) == 84
    end

    reversed = mimics_c_test_collection([22, 11])
    write_mimics_c_test_reference(reference) do path, scope_path
        @test_throws ErrorException SelectedMIMICSC.workflow_reference(
            reversed;
            path,
            comparison_policy = mimics_c_test_policy(),
            scope_manifest_path = scope_path,
        )
    end
end

@testset "MIMICS-C eligibility is atomic and eligible nonfinites fail" begin
    collection = mimics_c_test_collection()
    reference = mimics_c_test_reference()
    reference["oracle"]["annual"]["annual_mean"][first(
        SelectedMIMICSC.ANNUAL_STATE_NAMES,
    )][2] = Inf
    write_mimics_c_test_reference(reference) do path, scope_path
        error = try
            SelectedMIMICSC.workflow_reference(
                collection;
                path,
                comparison_policy = mimics_c_test_policy(),
                scope_manifest_path = scope_path,
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
        "model" => "MIMICS-C",
        "cell_id" => 22,
        "reason" => "fresh Fortran trajectory becomes nonfinite",
        "reviewed" => true,
        "first_nonfinite_stage" => "historical",
        "first_nonfinite_date" => "1901-01-01",
        "first_nonfinite_variable" =>
            first(SelectedMIMICSC.ANNUAL_STATE_NAMES),
    )
    write_mimics_c_test_reference(reference; gaps = [gap]) do path, scope_path
        loaded = SelectedMIMICSC.workflow_reference(
            collection;
            path,
            comparison_policy = mimics_c_test_policy(),
            scope_manifest_path = scope_path,
        )
        @test loaded.eligible_ids == [11]
        @test loaded.eligibility_gaps == [gap]
        @test_throws ErrorException SelectedMIMICSC.workflow_reference(
            collection;
            path,
            comparison_policy = mimics_c_test_policy(),
            scope_manifest_path = scope_path,
            eligibility_gaps = Any[],
        )
    end
end

@testset "MIMICS-C comparison reports a scientific failure by cell" begin
    collection = mimics_c_test_collection()
    reference = mimics_c_test_reference()
    expected = reference["oracle"]["boundary"]["prespin"]
    actual = deepcopy(expected)
    variable = first(SelectedMIMICSC.BOUNDARY_NAMES)
    actual[variable][2] += 1
    comparison = SelectedMIMICSC.compare_payload(
        actual,
        expected,
        mimics_c_test_policy()["fresh_fortran_boundary"]["prespin"],
        collection,
        Dict(11 => 1, 22 => 2),
    )
    @test !comparison["all_match"]
    @test only(comparison["cell_failures"])["cell_id"] == 22
    @test comparison["variable"][variable]["failed_values"] == 1

    write_mimics_c_test_reference(reference) do path, scope_path
        loaded = SelectedMIMICSC.workflow_reference(
            collection;
            path,
            comparison_policy = mimics_c_test_policy(),
            scope_manifest_path = scope_path,
        )
        budget = deepcopy(reference["oracle"]["budget"])
        budget["historical_residual_kg_c"][2] = 0.0
        budget["maximum_absolute_residual_kg_c"] = 1.25
        report = SelectedMIMICSC.compare_budget_reference(
            loaded,
            budget,
            collection,
            TestbedReferenceCellComparisons.ConcurrencyBudget(1),
        )
        @test !report["all_match"]
        @test only(report["cell_failures"])["cell_id"] == 22
        @test report["reducer"] == "maximum_absolute_residual"
        @test report["units"] == "kg C"
    end
end

@testset "selected MIMICS-C setup uses the supplied cells exactly" begin
    core = TestbedReferenceCellComparisons.core_cell_collection()
    collection = TestbedReferenceCellComparisons.subset(
        core,
        getproperty.(core.cells[1:2], :id),
    )
    setup = SelectedMIMICSC.load_setup(; collection)
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
    )
    stage = TestbedNativeWorkflow.NativeStage(
        :prespin,
        365,
        1;
        write_output = false,
    )
    SelectedMIMICSC.update_forcing!(setup.forcing, stage, 1, 0.0)
    @test all(isfinite, vec(parent(setup.buffers.liquid_saturation)))
    @test all(isfinite, vec(parent(setup.buffers.frozen_saturation)))
    @test all(isfinite, vec(parent(setup.buffers.annual_npp)))
end

@testset "selected MIMICS-C short workflow reports budgets" begin
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
        TestbedNativeWorkflow.NativeStage(:historical, 2, 1),
    )
    mktempdir() do output_root
        result = SelectedMIMICSC.run_selected_case(
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
    end
end
