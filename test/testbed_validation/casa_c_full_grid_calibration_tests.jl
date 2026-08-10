using Test

include("generate_casa_c_full_grid_calibration.jl")

@testset "CASA-C full-grid mixed tolerance calibration" begin
    zero_error =
        calibrated_envelope(zeros(2), [0.1, 1.0]; numerical_scale = 1.0)
    @test zero_error.raw_rtol == 0
    @test zero_error.raw_atol == 0
    @test zero_error.atol == 64eps(1.0)

    proportional =
        calibrated_envelope([1.0, 2.0], [1.0, 2.0]; numerical_scale = 3.0)
    @test proportional.raw_rtol > 0
    @test proportional.raw_atol == 0
    @test all(
        [1.0, 2.0] .<= proportional.atol .+ proportional.rtol .* [1.0, 2.0],
    )

    intersection = calibrated_envelope(
        [2.0, 3.0, 0.0],
        [1.0, 3.0, 2.0];
        numerical_scale = 6.0,
    )
    @test intersection.raw_rtol ≈ 0.5
    @test intersection.raw_atol ≈ 1.5

    contexts = [
        (
            cell_id = index,
            pft = index,
            latitude = Float64(index),
            longitude = -Float64(index),
            year = 1900 + index,
        ) for index in 1:6
    ]
    record = calibration_record(
        collect(1.0:6.0),
        collect(1.0:6.0),
        contexts;
        units = "kg N m^-2",
    )
    @test record["units"] == "kg N m^-2"
    @test !haskey(record["derived_policy"], "absolute_floor")
    @test record["derived_policy"]["numerical_padding"] > 0
    @test record["active_constraint_count"] == 6
    @test length(record["active_constraint_sample"]) == 6
    @test !haskey(record, "active_constraint_cell_ids")
    @test !haskey(record, "active_constraint_objective_slopes")
    @test all(
        all(
            haskey(observation, key) for key in (
                "cell_id",
                "pft",
                "latitude",
                "longitude",
                "year",
                "objective_slope",
            )
        ) for observation in record["active_constraint_sample"]
    )
    @test all(
        all(
            haskey(outlier, key) for
            key in ("cell_id", "pft", "latitude", "longitude", "year")
        ) for outlier in record["top_outlier"]
    )
end

@testset "CASA calibration source records distinguish sharded outputs" begin
    mktempdir() do root
        shard_roots = [joinpath(root, "shard-001"), joinpath(root, "shard-002")]
        for (index, shard_root) in enumerate(shard_roots)
            mkpath(shard_root)
            write(joinpath(shard_root, "reduced_historical.nc"), "shard $index")
        end
        outputs = [
            (
                index = index,
                first_grid_index = index,
                last_grid_index = index,
                output_root = shard_root,
            ) for (index, shard_root) in enumerate(shard_roots)
        ]
        records = output_source_records(
            outputs,
            "reduced_historical.nc",
            "julia/reduced_historical.nc",
        )
        @test getindex.(records["shard"], "index") == [1, 2]
        @test getindex.(getindex.(records["shard"], "file"), "id") == [
            joinpath("julia", "shard-001", "reduced_historical.nc"),
            joinpath("julia", "shard-002", "reduced_historical.nc"),
        ]

        monolithic = output_source_records(
            [first(outputs)],
            "reduced_historical.nc",
            "julia/reduced_historical.nc",
        )
        @test monolithic["id"] == "julia/reduced_historical.nc"
    end
end
