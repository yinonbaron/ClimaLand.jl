using Test
import ClimaLand

struct DrivenTrajectoryTestModel{FT, Domain} <: ClimaLand.AbstractExpModel{FT}
    domain::Domain
end

function DrivenTrajectoryTestModel(::Type{FT}) where {FT}
    domain = ClimaLand.Domains.Point(; z_sfc = zero(FT))
    return DrivenTrajectoryTestModel{FT, typeof(domain)}(domain)
end

ClimaLand.name(::DrivenTrajectoryTestModel) = :trajectory_state
ClimaLand.prognostic_vars(::DrivenTrajectoryTestModel) = (:level, :reserve)
ClimaLand.prognostic_types(::DrivenTrajectoryTestModel{FT}) where {FT} =
    (FT, FT)
ClimaLand.prognostic_domain_names(::DrivenTrajectoryTestModel) =
    (:surface, :surface)
ClimaLand.make_set_initial_cache(::DrivenTrajectoryTestModel) =
    (p, Y, t) -> nothing

function trajectory_case(::Type{FT} = Float64) where {FT}
    model = DrivenTrajectoryTestModel(FT)
    times = FT.((0, 1, 2, 3, 4))
    initial_state = (level = FT[10], reserve = FT[-1])
    advance! = function (Y, p, t, dt)
        state = getproperty(Y, ClimaLand.name(model))
        state.level .+= dt * (t < FT(2) ? one(FT) : FT(3))
        state.reserve .+= FT(2) * dt
        return nothing
    end
    reference = (
        level = map(value -> FT[value], FT.((10, 11, 12, 15, 18.25))),
        reserve = map(value -> FT[value], FT.((-1, 1, 3, 5, 7))),
    )
    tolerances = (
        level = (atol = FT(0.3), rtol = zero(FT)),
        reserve = (atol = zero(FT), rtol = zero(FT)),
    )
    drivers = NamedTuple{(:times, :initial_state, :advance!)}((
        times,
        initial_state,
        advance!,
    ))
    return (; model, drivers, reference, tolerances)
end

@testset "driven trajectory compares every public state snapshot" begin
    case = trajectory_case()

    metrics = test_driven_trajectory(
        case.model,
        case.drivers,
        case.reference,
        case.tolerances,
    )

    @test metrics.level.maximum_absolute_error == 0.25
    @test metrics.level.maximum_absolute_error_step == 5
    @test metrics.level.maximum_relative_error == 0.25 / 18.25
    @test metrics.level.compared_steps == length(case.drivers.times)
    @test metrics.reserve.maximum_absolute_error == 0.0
    @test metrics.reserve.compared_steps == length(case.drivers.times)
end

@testset "driven trajectory verifies discontinuities before exceptions" begin
    case = trajectory_case()
    exception = (step = 4, variable = :level, minimum_increment_change = 1.5)

    metrics = test_driven_trajectory(
        case.model,
        case.drivers,
        case.reference,
        case.tolerances;
        exception_steps = (regime_change = exception,),
    )

    @test metrics.level.compared_steps == length(case.drivers.times) - 1
    @test metrics.reserve.compared_steps == length(case.drivers.times)

    continuous_step =
        (step = 3, variable = :level, minimum_increment_change = 0.1)
    @test_throws ArgumentError test_driven_trajectory(
        case.model,
        case.drivers,
        case.reference,
        case.tolerances;
        exception_steps = (not_discontinuous = continuous_step,),
    )

    @test_throws ArgumentError test_driven_trajectory(
        case.model,
        case.drivers,
        case.reference,
        case.tolerances;
        exception_steps = (exception,),
    )

    non_prognostic_exception =
        (step = 4, variable = :diagnostic_flux, minimum_increment_change = 1.5)
    reference_with_diagnostic =
        merge(case.reference, (diagnostic_flux = case.reference.level,))
    @test_throws ArgumentError test_driven_trajectory(
        case.model,
        case.drivers,
        reference_with_diagnostic,
        case.tolerances;
        exception_steps = (not_prognostic = non_prognostic_exception,),
    )
end
