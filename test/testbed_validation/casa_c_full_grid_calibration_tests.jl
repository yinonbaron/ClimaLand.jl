using Test

include("generate_casa_c_full_grid_calibration.jl")

@testset "CASA-C full-grid mixed tolerance calibration" begin
    floor_limited = calibrated_envelope([1.0e-12, 2.0e-12], [0.1, 1.0])
    @test floor_limited.raw_rtol == 0
    @test floor_limited.raw_atol >= 5.0e-10

    proportional = calibrated_envelope([1.0, 2.0], [1.0, 2.0])
    @test proportional.raw_rtol > 0
    @test proportional.raw_atol >= 5.0e-10
    @test all(
        [1.0, 2.0] .<= proportional.atol .+ proportional.rtol .* [1.0, 2.0],
    )

    intersection = calibrated_envelope([2.0, 3.0, 0.0], [1.0, 3.0, 2.0])
    @test intersection.raw_rtol ≈ 0.5
    @test intersection.raw_atol ≈ 1.5
end
