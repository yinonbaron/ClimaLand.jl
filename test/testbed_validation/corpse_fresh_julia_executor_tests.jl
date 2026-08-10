using Test

include(joinpath(@__DIR__, "corpse_fresh_worker.jl"))
include(joinpath(@__DIR__, "corpse_fresh_julia_executor.jl"))
const FreshCORPSEJulia = TestbedCORPSEFreshJuliaExecutor
const FreshCORPSEWorker = TestbedCORPSEFreshWorker

function trajectory_observer_cost(observer, observations)
    observer(:prespin, 1, nothing, FreshCORPSEJulia.FINITE_OBSERVATION)
    GC.gc(false)
    bytes = Base.@allocated for step in 2:(observations + 1)
        observer(:prespin, step, nothing, FreshCORPSEJulia.FINITE_OBSERVATION)
    end
    seconds = @elapsed for step in (observations + 2):(2 * observations + 1)
        observer(:prespin, step, nothing, FreshCORPSEJulia.FINITE_OBSERVATION)
    end
    return (; bytes, seconds)
end

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

@testset "CORPSE finite trajectory observations are allocation-free" begin
    observer =
        FreshCORPSEWorker.TrajectoryObserver("julia", [51, 532], [51, 532])
    cost = trajectory_observer_cost(observer, 10_000)
    @test cost.bytes == 0
    @test cost.seconds < 1.0
end
