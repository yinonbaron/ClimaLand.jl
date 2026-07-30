using Test
import NCDatasets
import TOML

include(joinpath(@__DIR__, "native_corpse_c_reconstruction.jl"))
include(joinpath(@__DIR__, "generate_corpse_c_representative_calibration.jl"))
include(joinpath(@__DIR__, "generate_representative_corpse_reference.jl"))

const NativeCORPSE = TestbedNativeCORPSECReconstruction
const CORPSECalibration = TestbedCORPSERepresentativeCalibration
const CORPSEReference = GenerateRepresentativeCORPSEReference

struct ConstantCORPSEFields{F}
    values::Vector{Float64}
    fluxes::F
end

function Base.getproperty(fields::ConstantCORPSEFields, name::Symbol)
    name == :values && return getfield(fields, :values)
    name == :fluxes && return getfield(fields, :fluxes)
    name == :carbon_fluxes && return getfield(fields, :fluxes)
    return getfield(fields, :values)
end

struct ConstantCORPSEState
    fields::ConstantCORPSEFields
end

function Base.getproperty(state::ConstantCORPSEState, name::Symbol)
    name == :fields && return getfield(state, :fields)
    return getfield(state, :fields)
end

@testset "CORPSE public workflow seam" begin
    stages = NativeCORPSE.canonical_stages()
    @test getproperty.(stages, :name) ==
          (:prespin, :spin, :spin_continuation, :historical)
    @test getproperty.(stages, :forcing_days) ==
          (365, 20 * 365, 20 * 365, 114 * 365)
    @test getproperty.(stages, :repeats) == (100, 499, 499, 1)
    @test all(!stage.write_output for stage in stages)
    @test NativeCORPSE.comparison_variable_count() == (5, 36)

    grid = [
        (cell_id = index, pft = pft) for
        (index, pft) in enumerate((1, 11, 12, 13, 15, 17, 18))
    ]
    @test getproperty.(filter(NativeCORPSE.eligible_cell, grid), :cell_id) ==
          [1, 3, 7]
    @test isnothing(NativeCORPSE.assert_single_threaded())

    roots = [0.25, 0.75]
    frozen = [0.2, 0.4]
    @test NativeCORPSE.root_weighted_saturation(roots, frozen, 0.5) ≈ 0.7
end

@testset "pinned CORPSE Representative calibration" begin
    calibration_path = joinpath(
        @__DIR__,
        "validation",
        "corpse_c_representative_calibration.toml",
    )
    calibration = NativeCORPSE.calibration_policy(calibration_path)
    stage_records = [
        record for records in values(calibration["stage"]) for
        record in values(records)
    ]
    reducer_records = [
        record for records in values(calibration["reducer"]) for
        record in values(records)
    ]
    @test length(stage_records) == 164
    @test length(reducer_records) == 62
    @test all(
        record["derived_policy"]["validation_failed_pairs"] == 0 for
        record in (stage_records..., reducer_records...)
    )
    @test all(
        length(record["top_outlier"]) == 6 for
        record in (stage_records..., reducer_records...)
    )
    @test calibration["provenance"]["scope_manifest"]["sha256"] ==
          NativeCORPSE.native_workflow().sha256sum(
        joinpath(@__DIR__, "validation", "scopes", "representative.toml"),
    )
    for reducer in ("annual_total", "fixed_daily_sample")
        litter = calibration["reducer"][reducer]["LitterLayer_CO2"]
        @test litter["derived_policy"]["rtol"] < 1e-3
        @test maximum(
            abs(outlier["julia_value"]) for
            outlier in litter["top_outlier"]
        ) > 0
    end
end

@testset "CORPSE Representative population and reducers" begin
    manifest = joinpath(@__DIR__, "validation", "scopes", "representative.toml")
    scope = NativeCORPSE.representative_scope(manifest)
    @test scope.name == "representative"
    @test length(scope.cell_ids) == 80
    @test scope.cell_ids == sort(unique(scope.cell_ids))
    @test scope.gaps == Dict(51 => 17, 3442 => 11)
    @test scope.eligible_cell_ids ==
          filter(id -> !haskey(scope.gaps, id), scope.cell_ids)

    tracker = NativeCORPSE.ReducedCORPSEHistorical(2)
    @test length(NativeCORPSE.REDUCED_SAMPLE_DAYS) == 84
    @test length(tracker.annual_mean) == 18
    @test length(tracker.annual_total) == 4
    @test all(
        size(values) == (2, 114) for values in values(tracker.annual_mean)
    )
    @test all(
        size(values) == (2, 114) for values in values(tracker.end_of_year)
    )
    @test all(size(values) == (2, 84) for values in values(tracker.samples))

    state = ConstantCORPSEState(
        ConstantCORPSEFields(
            [1.0, 2.0],
            [ntuple(_ -> value, 39) for value in (1.0, 2.0)],
        ),
    )
    historical = (name = :historical,)
    for day in 1:365
        tracker(historical, day, state, state, nothing)
    end
    first_variable = first(NativeCORPSE.REDUCED_VARIABLES).name
    @test tracker.annual_mean[first_variable][:, 1] == [365000.0, 730000.0]
    @test tracker.end_of_year[first_variable][:, 1] == [1000.0, 2000.0]
    @test tracker.samples[first_variable][:, 1] == [1000.0, 2000.0]
    first_flux = first(NativeCORPSE.REDUCED_FLUX_VARIABLES).name
    @test tracker.annual_total[first_flux][:, 1] ==
          365 * NativeCORPSE.DAY_SECONDS * [1000.0, 2000.0]
    litter_respiration = only(
        filter(
            variable -> variable.name == "LitterLayer_CO2",
            NativeCORPSE.REDUCED_FLUX_VARIABLES,
        ),
    )
    respiration_fluxes = [
        ntuple(
            index -> index == 38 ? 10.0 : index in (9, 18) ? 2.0 : 0.0,
            39,
        ),
    ]
    respiration_state = ConstantCORPSEState(
        ConstantCORPSEFields([0.0], respiration_fluxes),
    )
    @test only(
        NativeCORPSE.reduced_field(
            litter_respiration,
            respiration_state,
            respiration_state,
        ),
    ) == [6.0]
    mktempdir() do directory
        path = joinpath(directory, "reduced.nc")
        NativeCORPSE.write_reduced_historical(
            path,
            tracker,
            [(cell_id = 1,), (cell_id = 2,)],
            [true, true],
        )
        NCDatasets.NCDataset(path) do dataset
            @test dataset["annual_mean__cleaf"].attrib["units"] == "g C m-2"
            @test dataset["annual_total__cgpp"].attrib["units"] ==
                  "g C m-2 year-1"
            @test dataset["fixed_daily_sample__cgpp"].attrib["units"] ==
                  "g C m-2 day-1"
            @test dataset["fixed_daily_sample__Ts"].attrib["units"] == "K"
        end
    end

    mktempdir() do directory
        invalid = TOML.parsefile(manifest)
        invalid["eligibility_gaps"][1]["reviewed"] = false
        invalid_path = joinpath(directory, "unreviewed.toml")
        open(invalid_path, "w") do io
            TOML.print(io, invalid; sorted = true)
        end
        @test_throws ErrorException NativeCORPSE.representative_scope(
            invalid_path,
        )
    end
end

@testset "CORPSE calibration policy derivation" begin
    grid = [
        (
            cell_id = index,
            pft = 1,
            latitude = 10.0 + index,
            longitude = -20.0 - index,
        ) for index in 1:8
    ]
    expected = [0.0, 1e-6, 1e-3, 0.1, 1.0, 2.0, 3.0, 4.0]
    actual = expected .+ [0.0, 3e-7, 2e-6, 4e-5, 2e-4, 5e-4, 9e-4, 1e-3]
    record = CORPSECalibration.calibration_record(
        actual,
        expected,
        grid;
        units = "kg C m-2",
    )
    policy = record["derived_policy"]
    @test policy["atol"] >= 1.05 * policy["raw_atol"]
    @test policy["rtol"] == 1.05 * policy["raw_rtol"]
    @test policy["raw_atol"] >= 0
    @test policy["raw_rtol"] >= 0
    @test policy["validation_failed_pairs"] == 0
    @test length(record["top_outlier"]) == 6
    @test record["top_outlier"][1]["latitude"] == 18.0
    @test record["top_outlier"][1]["longitude"] == -28.0
    @test !haskey(record["top_outlier"][1], "year")
    @test record["finite_pair_count"] == length(grid)
    @test record["units"] == "kg C m-2"
    @test CORPSECalibration.CALIBRATION_ID ==
          "corpse-c-representative-fresh-fortran-v1"

    exact = CORPSECalibration.calibration_record(
        expected,
        expected,
        grid;
        units = "kg C m-2",
    )
    @test exact["derived_policy"]["raw_atol"] == 0
    @test exact["derived_policy"]["raw_rtol"] == 0
    @test exact["derived_policy"]["atol"] ==
          exact["derived_policy"]["absolute_numerical_padding"]
    @test exact["derived_policy"]["absolute_numerical_padding"] ==
          64eps(Float64) * maximum(abs, expected)
    applied = NativeCORPSE.calibrated_metrics(actual, expected, record)
    @test applied["all_match"]
    perturbed = copy(actual)
    perturbed[end] += 1
    @test !NativeCORPSE.calibrated_metrics(perturbed, expected, record)["all_match"]
    @test_throws ErrorException NativeCORPSE.calibrated_metrics(
        [Inf],
        [1.0],
        CORPSECalibration.calibration_record(
            [1.0],
            [1.0],
            grid[1:1];
            units = "kg C m-2",
        ),
    )

    @test_throws ErrorException CORPSECalibration.calibration_record(
        [1.0, Inf],
        [1.0, 2.0],
        grid[1:2],
        units = "kg C m-2",
    )

    historical = CORPSECalibration.calibration_record(
        [1.0, 4.0],
        [1.0, 2.0],
        grid[1:2];
        units = "g C m-2",
        coordinate_schema = :fixed_daily,
        coordinates = Dict(
            "year" => [1957, 1957],
            "sample_day" => [20_441, 20_532],
            "day_of_year" => [1, 92],
        ),
    )
    @test historical["top_outlier"][1]["cell_id"] == 2
    @test historical["top_outlier"][1]["latitude"] == 12.0
    @test historical["top_outlier"][1]["longitude"] == -22.0
    @test historical["top_outlier"][1]["year"] == 1957
    @test historical["top_outlier"][1]["sample_day"] == 20_532
    @test historical["top_outlier"][1]["day_of_year"] == 92
    mktempdir() do directory
        path = joinpath(directory, "calibration.toml")
        open(path, "w") do io
            TOML.print(io, Dict("record" => historical); sorted = true)
        end
        parsed = TOML.parsefile(path)["record"]["top_outlier"][1]
        @test parsed["latitude"] == 12.0
        @test parsed["year"] == 1957
        @test parsed["sample_day"] == 20_532
        @test parsed["day_of_year"] == 92
    end
    @test_throws ErrorException CORPSECalibration.calibration_record(
        [1.0, 4.0],
        [1.0, 2.0],
        grid[1:2];
        units = "g C m-2",
        coordinate_schema = :fixed_daily,
        coordinates = Dict("year" => [1957]),
    )
    annual_grid, annual_coordinates, annual_schema =
        CORPSECalibration.calibration_population(
            grid[1:2],
            "annual_mean",
            [1901, 1902],
        )
    @test getproperty.(annual_grid, :cell_id) == [1, 2, 1, 2]
    @test annual_coordinates == Dict(
        "year" => [1901, 1901, 1902, 1902],
    )
    @test annual_schema == :annual
    daily_grid, daily_coordinates, daily_schema =
        CORPSECalibration.calibration_population(
            grid[1:2],
            "fixed_daily_sample",
            [1, 92, 20_441],
        )
    @test getproperty.(daily_grid, :cell_id) == [1, 2, 1, 2, 1, 2]
    @test daily_coordinates == Dict(
        "year" => [1901, 1901, 1901, 1901, 1957, 1957],
        "sample_day" => [1, 1, 92, 92, 20_441, 20_441],
        "day_of_year" => [1, 1, 92, 92, 1, 1],
    )
    @test daily_schema == :fixed_daily
    @test_throws ErrorException CORPSECalibration.calibration_record(
        [1.0, 4.0],
        [1.0, 2.0],
        grid[1:2];
        units = "g C m-2",
        coordinate_schema = :annual,
        coordinates = Dict(
            "year" => [1957, 1957],
            "sample_day" => [20_441, 20_532],
        ),
    )

    mktempdir() do directory
        record(path, id) = Dict(
            "id" => id,
            "sha256" => NativeCORPSE.native_workflow().sha256sum(path),
        )
        report = joinpath(directory, "reconstruction_report.toml")
        write(report, "status = \"complete\"\n")
        stage_records = Dict{String, Any}()
        for stage in NativeCORPSE.canonical_stages()
            stage_name = String(stage.name)
            stage_directory = NativeCORPSE.stage_directory(stage)
            stage_root = joinpath(directory, "stages", stage_directory)
            mkpath(stage_root)
            paths = Dict(
                "casa_boundary" => joinpath(stage_root, "casa_final.csv"),
                "corpse_boundary" => joinpath(stage_root, "corpse_final.csv"),
                "metadata" => joinpath(stage_root, "stage_metadata.toml"),
            )
            foreach(path -> write(path, stage_name), values(paths))
            stage_records[stage_name] = Dict(
                key => record(
                    path,
                    "fortran/$stage_directory/$(basename(path))",
                ) for (key, path) in paths
            )
        end
        boundary_calibration = Dict(
            "provenance" => Dict(
                "fortran_reconstruction_report" =>
                    record(report, "fortran/reconstruction_report.toml"),
                "fortran_stage" => stage_records,
            ),
        )
        @test isnothing(
            NativeCORPSE.verify_boundary_reference(
                boundary_calibration,
                directory,
            ),
        )
        write(
            joinpath(directory, "stages", "01-prespin", "casa_final.csv"),
            "changed",
        )
        @test_throws ErrorException NativeCORPSE.verify_boundary_reference(
            boundary_calibration,
            directory,
        )
    end

    sleepy = `$(Base.julia_cmd()) --startup-file=no -e "sleep(1)"`
    @test_throws ErrorException NativeCORPSE.run_with_timeout(
        sleepy;
        timeout_seconds = 0.01,
    )
    @test_throws ErrorException CORPSECalibration.run_with_timeout(
        sleepy;
        timeout_seconds = 0.01,
    )
end

@testset "CORPSE reduced Fortran extraction" begin
    mktempdir() do directory
        path = joinpath(directory, "daily.nc")
        NCDatasets.NCDataset(path, "c") do dataset
            NCDatasets.defDim(dataset, "time", 3)
            NCDatasets.defDim(dataset, "lat", 1)
            NCDatasets.defDim(dataset, "lon", 2)
            NCDatasets.defVar(dataset, "cellid", Int, ("lat", "lon"))[:, :] =
                reshape([51, 532], 1, 2)
            variable = NCDatasets.defVar(
                dataset,
                "cleaf",
                Float64,
                ("time", "lat", "lon"),
            )
            variable[:, :, :] = reshape(1.0:6.0, 3, 1, 2)
        end
        NCDatasets.NCDataset(path) do dataset
            @test CORPSEReference.selected_series(
                dataset,
                "cleaf",
                [532, 51],
            ) == [4.0 5.0 6.0; 1.0 2.0 3.0]
        end
    end
end
