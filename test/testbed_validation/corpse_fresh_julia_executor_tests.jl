using Test

include(joinpath(@__DIR__, "corpse_fresh_julia_executor.jl"))
const FreshCORPSEJulia = TestbedCORPSEFreshJuliaExecutor

@testset "CORPSE Julia fresh observer dates repeated stages exactly" begin
    stage = (; name = :prespin, forcing_days = 365)
    @test FreshCORPSEJulia.noleap_date(stage, 1) == "1901-01-01"
    @test FreshCORPSEJulia.noleap_date(stage, 365) == "1901-12-31"
    @test FreshCORPSEJulia.noleap_date(stage, 366) == "1901-01-01"
    history = (; name = :historical, forcing_days = 114 * 365)
    @test FreshCORPSEJulia.noleap_date(history, 365 + 60) == "1902-03-01"
end

@testset "CORPSE Julia fresh observer includes reduced diagnostics" begin
    native = FreshCORPSEJulia.native_corpse()
    @test length(native.REDUCED_STATE_VARIABLES) == 18
    @test length(native.REDUCED_FLUX_VARIABLES) == 4
    @test Set(getproperty.(native.REDUCED_VARIABLES, :name)) >=
          Set(("Soil_C1", "Soil_CO2", "cgpp", "thetaLiq"))
end
