using Test
import ClimaLand
import ClimaComms
import ClimaCore
ClimaComms.@import_required_backends
using ClimaLand.Soil.Biogeochemistry
using ClimaLand.Domains: Plane, Point
import ClimaTimeSteppers as CTS
import StaticArrays

include("../../../testbed_validation/model_architecture.jl")
include("../../../shared_utilities/corpse_test_parameters.jl")

using .TestCORPSEParameters: corpse_carbon_parameters

const CORPSE = Biogeochemistry.CORPSE
const FORWARD_EULER = CTS.ExplicitAlgorithm(
    CTS.ExplicitTableau(;
        a = zeros(Int, 1, 1),
        b = ones(Int, 1),
        c = zeros(Int, 1),
    ),
)

function corpse_model_parameters(
    ::Type{FT};
    mineral_protection_capacity = FT(0.05),
) where {FT}
    carbon = corpse_carbon_parameters(FT)
    parameter_type = CORPSE.CORPSESoilModelParameters{FT, typeof(carbon)}
    return parameter_type(;
        carbon,
        mineral_protection_capacity,
        layer_thickness = FT(0.15),
        rhizosphere_fraction = FT(0.3),
        litter_option = 1,
        freezing_temperature = FT(273.15),
        cwd_q10 = FT(1.72),
        cwd_litter_optimum = FT(0.4),
        cwd_base_rate = inv(FT(365 * 0.824 * 86400)),
        cwd_respiration_fraction = FT(0.48),
    )
end

function valid_cohort(::Type{FT}) where {FT}
    active = FT.((0.2, 1.3, 0.05, 0.01, 0.2, 0.03, 0.02))
    carbon_dioxide = FT(0.4)
    return StaticArrays.SVector(
        active...,
        carbon_dioxide,
        sum(active) + carbon_dioxide,
    )
end

for FT in (Float32, Float64)
    @testset "CORPSE carbon kernels, FT = $FT" begin
        parameters = corpse_carbon_parameters(FT)
        @test isbits(parameters)
        cohort = valid_cohort(FT)
        mapped = @inferred CORPSE.update_cohort(
            parameters,
            cohort,
            FT(283.15),
            FT(0.3),
            FT(0.4),
            FT(0.05),
            FT(0.15),
        )
        @test @allocated(
            CORPSE.update_cohort(
                parameters,
                cohort,
                FT(283.15),
                FT(0.3),
                FT(0.4),
                FT(0.05),
                FT(0.15),
            )
        ) == 0
        @test CORPSE.cohort_carbon(mapped.state) ≈ CORPSE.cohort_carbon(cohort) rtol =
            16eps(FT)
        @test mapped.state[9] == cohort[9]
        @test mapped.moisture >= parameters.minimum_moisture_factor
        @test CORPSE.mineral_protection_capacity(FT(0.2), FT(0.45)) > zero(FT)
        dry = CORPSE.update_cohort(
            parameters,
            cohort,
            FT(283.15),
            zero(FT),
            FT(0.5),
            FT(0.05),
            FT(0.15),
        )
        @test dry.respiration > zero(FT)
        @test dry.state[8] > cohort[8]

        litter_rate = StaticArrays.SVector(FT(1e-8), FT(2e-8), zero(FT))
        exudate_rate =
            StaticArrays.SVector(FT(3e-9), zero(FT), zero(FT))
        fraction = FT(0.3)
        continuous = @inferred CORPSE.continuous_cohort_tendencies(
            parameters,
            cohort,
            litter_rate,
            exudate_rate,
            fraction,
            FT(283.15),
            FT(0.3),
            FT(0.4),
            FT(0.05),
            FT(0.15),
        )
        CORPSE.continuous_cohort_tendencies(
            parameters,
            cohort,
            litter_rate,
            exudate_rate,
            fraction,
            FT(283.15),
            FT(0.3),
            FT(0.4),
            FT(0.05),
            FT(0.15),
        )
        @test @allocated(
            CORPSE.continuous_cohort_tendencies(
                parameters,
                cohort,
                litter_rate,
                exudate_rate,
                fraction,
                FT(283.15),
                FT(0.3),
                FT(0.4),
                FT(0.05),
                FT(0.15),
            )
        ) == 0
        input_rate = sum(litter_rate) * fraction + sum(exudate_rate)
        @test sum(continuous.state[1:7]) + continuous.respiration ≈ input_rate rtol =
            64eps(FT)
        @test continuous.state[8] == continuous.respiration
        @test continuous.state[9] == input_rate

        no_inputs = CORPSE.continuous_cohort_tendencies(
            parameters,
            cohort,
            zero(litter_rate),
            zero(exudate_rate),
            fraction,
            FT(283.15),
            FT(0.3),
            FT(0.4),
            FT(0.05),
            FT(0.15),
        )
        direct_input_effect = continuous.state - no_inputs.state
        substrate_fraction =
            (one(FT) - parameters.minimum_microbe_fraction) * fraction
        @test direct_input_effect[1:3] ≈
              litter_rate .* substrate_fraction + exudate_rate rtol =
            8eps(FT)
        @test direct_input_effect[4:6] == zero(litter_rate)
        @test direct_input_effect[7] ≈
              sum(litter_rate) * parameters.minimum_microbe_fraction * fraction rtol =
            sqrt(eps(FT))
        @test direct_input_effect[8] == zero(FT)
        @test direct_input_effect[9] == input_rate

        zero_cohort = zero(cohort)
        states = (cohort, zero_cohort, zero_cohort, zero_cohort)
        root_litter = StaticArrays.SVector(FT(0.001), FT(0.002), zero(FT))
        leaf_litter = StaticArrays.SVector(FT(0.003), FT(0.004), zero(FT))
        exudate = StaticArrays.SVector(FT(0.0001), zero(FT), zero(FT))
        inputs = (; root_litter, leaf_litter, exudate)
        environment = (;
            rhizosphere_fraction = FT(0.3),
            temperature = FT(283.15),
            liquid_saturation = FT(0.3),
            air_filled_porosity = FT(0.4),
            qmax = FT(0.05),
            layer_thickness = FT(0.15),
        )
        day = @inferred CORPSE.daily_carbon_map(
            parameters,
            states,
            inputs,
            environment,
        )
        CORPSE.daily_carbon_map(parameters, states, inputs, environment)
        @test @allocated(
            CORPSE.daily_carbon_map(parameters, states, inputs, environment)
        ) == 0
        previous_carbon = sum(CORPSE.cohort_carbon.(states))
        input_carbon = sum(root_litter) + sum(leaf_litter) + sum(exudate)
        @test sum(CORPSE.cohort_carbon.(day.state)) ≈
              previous_carbon + input_carbon rtol = 32eps(FT)
        for next_cohort in day.state
            @test next_cohort[9] ≈ CORPSE.cohort_carbon(next_cohort) rtol =
                32eps(FT)
        end
    end
end

@testset "CORPSE pinned calculation order regression" begin
    parameters = corpse_carbon_parameters(Float32)
    mapped = CORPSE.update_cohort(
        parameters,
        valid_cohort(Float32),
        283.15f0,
        0.3f0,
        0.4f0,
        0.05f0,
        0.15f0,
    )
    fortran_expected = StaticArrays.SVector{9, Float32}(
        1.9918233156204224e-1,
        1.2999147176742554,
        5.0028387457132339e-2,
        1.0004136711359024e-2,
        1.9999323785305023e-1,
        3.0009185895323753e-2,
        2.0340774208307266e-2,
        4.0052723884582520e-1,
        2.2100000381469727,
    )
    @test mapped.state == fortran_expected
    fortran_respiration = Float32(5.2722467808052897e-4)
    @test abs(mapped.respiration - fortran_respiration) <=
          2eps(fortran_respiration)
end

@testset "CORPSE standalone soil model" begin
    for FT in (Float32, Float64)
        parameters = corpse_model_parameters(FT)
        inputs = FT.((1e-8, 2e-8, 3e-8, 4e-8, 1e-9, 5e-9))
        drivers = CORPSE.PrescribedDrivers(
            t -> FT(283.15),
            t -> FT(0.3),
            t -> FT(0.1),
            t -> inputs[1],
            t -> inputs[2],
            t -> inputs[3],
            t -> inputs[4],
            t -> inputs[5],
            t -> inputs[6],
        )
        domain = Point(; z_sfc = zero(FT), context = ClimaComms.context())
        model = CORPSE.CORPSESoilModel{FT}(; parameters, drivers, domain)
        continuous_model = CORPSE.CORPSESoilModel{FT}(;
            parameters,
            drivers,
            domain,
            temporal_mode = CORPSE.ContinuousRate(),
        )
        @test model isa Biogeochemistry.AbstractSoilBiogeochemistryModel{FT}
        @test model.temporal_mode isa CORPSE.LegacyDaily
        @test continuous_model.temporal_mode isa CORPSE.ContinuousRate
        @test ClimaLand.prognostic_vars(continuous_model) ==
              ClimaLand.prognostic_vars(model)
        @test ClimaLand.auxiliary_vars(continuous_model) ==
              ClimaLand.auxiliary_vars(model)
        @test ClimaLand.name(model) == :corpse_soil
        Y, p, _ = ClimaLand.initialize(model)
        for variable in ClimaLand.prognostic_vars(model)
            getproperty(Y.corpse_soil, variable) .= zero(FT)
        end
        Y.corpse_soil.c_litter_cwd .= FT(0.5)
        initial_cohort = valid_cohort(FT)
        for (offset, variable) in
            enumerate(ClimaLand.prognostic_vars(model)[2:10])
            getproperty(Y.corpse_soil, variable) .= initial_cohort[offset]
        end

        tendency! = ClimaLand.make_exp_tendency(model)
        ClimaLand.make_set_initial_cache(model)(p, Y, zero(FT))
        FT == Float32 && test_model_diagnostics(model, Y, p, zero(FT))
        dY = similar(Y)
        tendency!(dY, Y, p, zero(FT))
        fluxes = p.corpse_soil.carbon_fluxes[]
        tendencies = map(ClimaLand.prognostic_vars(model)) do variable
            Array(parent(getproperty(dY.corpse_soil, variable)))[1]
        end
        @test tendencies == Tuple(fluxes[1:37])
        physical_indices = (
            1,
            2,
            3,
            4,
            5,
            6,
            7,
            8,
            11,
            12,
            13,
            14,
            15,
            16,
            17,
            20,
            21,
            22,
            23,
            24,
            25,
            26,
            29,
            30,
            31,
            32,
            33,
            34,
            35,
        )
        input_rate = inputs[1] + inputs[2] + inputs[3] + inputs[4] + inputs[6]
        @test sum(tendencies[index] for index in physical_indices) +
              fluxes[38] ≈ input_rate rtol = FT(5e-5)

        day = FT(86400)
        initial = map(ClimaLand.prognostic_vars(model)) do variable
            Array(parent(getproperty(Y.corpse_soil, variable)))[1]
        end
        expected = initial .+ day .* tendencies
        problem = CTS.ODEProblem(
            CTS.ClimaODEFunction((T_exp!) = tendency!),
            Y,
            (0.0, Float64(day)),
            p,
        )
        integrator = CTS.init(
            problem,
            FORWARD_EULER;
            dt = Float64(day),
            save_everystep = false,
        )
        CTS.step!(integrator)
        actual = map(ClimaLand.prognostic_vars(model)) do variable
            Array(parent(getproperty(integrator.u.corpse_soil, variable)))[1]
        end
        @test all(isapprox.(actual, expected; rtol = 32eps(FT)))

        continuous_Y, continuous_p, _ = ClimaLand.initialize(continuous_model)
        for (variable, value) in
            zip(ClimaLand.prognostic_vars(continuous_model), initial)
            getproperty(continuous_Y.corpse_soil, variable) .= value
        end
        ClimaLand.make_set_initial_cache(continuous_model)(
            continuous_p,
            continuous_Y,
            zero(FT),
        )
        continuous_fluxes = continuous_p.corpse_soil.carbon_fluxes[]
        @test continuous_fluxes == CORPSE.continuous_carbon_fluxes(
            parameters,
            initial[1],
            StaticArrays.SVector{9, FT}(initial[2:10]),
            StaticArrays.SVector{9, FT}(initial[11:19]),
            StaticArrays.SVector{9, FT}(initial[20:28]),
            StaticArrays.SVector{9, FT}(initial[29:37]),
            FT(283.15),
            FT(0.3),
            FT(0.1),
            inputs...,
        )
        @test sum(continuous_fluxes[index] for index in physical_indices) +
              continuous_fluxes[38] ≈ input_rate rtol = 64eps(FT)

        continuous_tendency! = ClimaLand.make_exp_tendency(continuous_model)
        hour = FT(3600)
        continuous_problem = CTS.ODEProblem(
            CTS.ClimaODEFunction((T_exp!) = continuous_tendency!),
            continuous_Y,
            (0.0, Float64(hour)),
            continuous_p,
        )
        continuous_integrator = CTS.init(
            continuous_problem,
            FORWARD_EULER;
            dt = Float64(hour),
            save_everystep = false,
        )
        CTS.step!(continuous_integrator)
        continuous_actual =
            map(ClimaLand.prognostic_vars(continuous_model)) do variable
            Array(
                parent(
                    getproperty(
                        continuous_integrator.u.corpse_soil,
                        variable,
                    ),
                ),
            )[1]
        end
        continuous_expected = initial .+ hour .* continuous_fluxes[1:37]
        @test all(
            isapprox.(continuous_actual, continuous_expected; rtol = 32eps(FT)),
        )
        if FT == Float32
            test_checkpoint_roundtrip(model, integrator.u, Float64(day))
            plane = Plane(;
                xlim = FT.((0, 2)),
                ylim = FT.((0, 2)),
                nelements = (2, 2),
                context = ClimaComms.context(),
            )
            grid_model = CORPSE.CORPSESoilModel{FT}(;
                parameters,
                drivers,
                domain = plane,
            )
            test_gridded_tendency(
                grid_model,
                initial,
                tendencies,
                zero(FT),
                32eps(FT),
            )
            continuous_grid_model = CORPSE.CORPSESoilModel{FT}(;
                parameters,
                drivers,
                domain = plane,
                temporal_mode = CORPSE.ContinuousRate(),
            )
            test_gridded_tendency(
                continuous_grid_model,
                initial,
                Tuple(continuous_fluxes[1:37]),
                zero(FT),
                32eps(FT),
            )

            spatial_variant = corpse_model_parameters(
                FT;
                mineral_protection_capacity = FT(0.1),
            )
            x = ClimaCore.Fields.coordinate_field(plane.space.surface).x
            spatial_parameters =
                @. ifelse(x < FT(1), parameters, spatial_variant)
            @test axes(spatial_parameters) == plane.space.surface
            @test eltype(spatial_parameters) == typeof(parameters)

            spatial_model = CORPSE.CORPSESoilModel{FT}(;
                parameters = spatial_parameters,
                drivers,
                domain = plane,
            )
            spatial_Y, spatial_p, _ = ClimaLand.initialize(spatial_model)
            for (variable, value) in
                zip(ClimaLand.prognostic_vars(spatial_model), initial)
                getproperty(spatial_Y.corpse_soil, variable) .= value
            end
            ClimaLand.make_set_initial_cache(spatial_model)(
                spatial_p,
                spatial_Y,
                zero(FT),
            )
            spatial_dY = similar(spatial_Y)
            ClimaLand.make_exp_tendency(spatial_model)(
                spatial_dY,
                spatial_Y,
                spatial_p,
                zero(FT),
            )

            right_fluxes = CORPSE.combined_carbon_fluxes(
                spatial_variant,
                initial[1],
                StaticArrays.SVector{9, FT}(initial[2:10]),
                StaticArrays.SVector{9, FT}(initial[11:19]),
                StaticArrays.SVector{9, FT}(initial[20:28]),
                StaticArrays.SVector{9, FT}(initial[29:37]),
                FT(283.15),
                FT(0.3),
                FT(0.1),
                inputs...,
            )
            x_values = Array(parent(x))
            left = x_values .< FT(1)
            right = .!left
            spatial_tendency =
                Array(parent(spatial_dY.corpse_soil.soil_rhiz_protected_labile))
            @test all(spatial_tendency[left] .≈ tendencies[5])
            @test all(spatial_tendency[right] .≈ right_fluxes[5])
        end
    end
end

@testset "CORPSE simultaneous ODE convergence and legacy proximity" begin
    FT = Float64
    parameters = corpse_model_parameters(FT)
    inputs = FT.((1e-8, 2e-8, 3e-8, 4e-8, 1e-9, 5e-9))
    cohort = valid_cohort(FT)
    empty_cohort = zero(cohort)
    initial = StaticArrays.SVector{37, FT}(
        FT(0.5),
        Tuple(cohort)...,
        Tuple(empty_cohort)...,
        Tuple(empty_cohort)...,
        Tuple(empty_cohort)...,
    )
    drivers = (FT(283.15), FT(0.3), FT(0.1), inputs...)
    unpack(state) = (
        state[1],
        StaticArrays.SVector{9, FT}(state[2:10]),
        StaticArrays.SVector{9, FT}(state[11:19]),
        StaticArrays.SVector{9, FT}(state[20:28]),
        StaticArrays.SVector{9, FT}(state[29:37]),
    )
    initial_parts = unpack(initial)
    continuous_fluxes = @inferred CORPSE.continuous_carbon_fluxes(
        parameters,
        initial_parts...,
        drivers...,
    )
    CORPSE.continuous_carbon_fluxes(parameters, initial_parts..., drivers...)
    @test @allocated(
        CORPSE.continuous_carbon_fluxes(
            parameters,
            initial_parts...,
            drivers...,
        )
    ) == 0
    @test continuous_fluxes == CORPSE.continuous_carbon_fluxes(
        parameters,
        initial_parts...,
        drivers...,
    )
    legacy_fluxes = CORPSE.combined_carbon_fluxes(
        parameters,
        initial_parts...,
        drivers...,
    )
    legacy_day = initial + FT(86400) * legacy_fluxes[1:37]

    function integrate_continuous_day(dt)
        state = initial
        for _ in 1:round(Int, FT(86400) / dt)
            fluxes = CORPSE.continuous_carbon_fluxes(
                parameters,
                unpack(state)...,
                drivers...,
            )
            state += dt * fluxes[1:37]
        end
        return state
    end

    timesteps = FT.((3600, 1800, 900, 450))
    solutions = integrate_continuous_day.(timesteps)
    refinement_errors = map(1:3) do index
        sum(abs, solutions[index] - solutions[index + 1])
    end
    @test refinement_errors[2] < FT(0.55) * refinement_errors[1]
    @test refinement_errors[3] < FT(0.55) * refinement_errors[2]

    physical_indices = (
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        11,
        12,
        13,
        14,
        15,
        16,
        17,
        20,
        21,
        22,
        23,
        24,
        25,
        26,
        29,
        30,
        31,
        32,
        33,
        34,
        35,
    )
    finest = solutions[end]
    relative_legacy_distance =
        sum(abs(finest[index] - legacy_day[index]) for index in physical_indices) /
        sum(abs(legacy_day[index]) for index in physical_indices)
    @test relative_legacy_distance < 2e-5
    @test relative_legacy_distance > 1e-6
end
