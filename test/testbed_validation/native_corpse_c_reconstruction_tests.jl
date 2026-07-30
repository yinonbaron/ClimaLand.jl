using Test

include(joinpath(@__DIR__, "native_corpse_c_reconstruction.jl"))
include(joinpath(@__DIR__, "generate_corpse_c_full_grid_calibration.jl"))

const NativeCORPSE = TestbedNativeCORPSECReconstruction
const CORPSECalibration = TestbedCORPSEFullGridCalibration

@testset "CORPSE public full-grid seam" begin
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

@testset "CORPSE calibration policy derivation" begin
    grid = [(cell_id = index, pft = 1) for index in 1:8]
    expected = [0.0, 1e-6, 1e-3, 0.1, 1.0, 2.0, 3.0, 4.0]
    actual = expected .+ [0.0, 3e-7, 2e-6, 4e-5, 2e-4, 5e-4, 9e-4, 1e-3]
    record = CORPSECalibration.calibration_record(
        actual,
        expected,
        grid;
        absolute_floor = 5e-7,
    )
    policy = record["derived_policy"]
    @test policy["atol"] >= 1.05 * policy["raw_atol"]
    @test policy["rtol"] == 1.05 * policy["raw_rtol"]
    @test policy["absolute_floor"] > 5e-7
    @test policy["validation_failed_pairs"] == 0
    @test length(record["top_outlier"]) == 6
    @test record["finite_pair_count"] == length(grid)

    @test_throws ErrorException CORPSECalibration.calibration_record(
        [1.0, Inf],
        [1.0, 2.0],
        grid[1:2];
        absolute_floor = 5e-7,
    )

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
