using Test
using NCDatasets
import ClimaLand
import ClimaComms
import ClimaCore
import ForwardDiff
ClimaComms.@import_required_backends
using ClimaLand.Soil.Biogeochemistry
using ClimaLand.Domains: Plane, Point
import ClimaTimeSteppers as CTS

include("../../../testbed_validation/model_architecture.jl")

const MIMICS = Biogeochemistry.MIMICS
const FORWARD_EULER = CTS.ExplicitAlgorithm(
    CTS.ExplicitTableau(;
        a = zeros(Int, 1, 1),
        b = ones(Int, 1),
        c = zeros(Int, 1),
    ),
)

function mimics_carbon_parameters(::Type{FT}) where {FT}
    return MIMICS.CarbonParameters{FT}(;
        vmax_slope = ntuple(_ -> FT(0.063), 6),
        vmax_intercept = ntuple(_ -> FT(5.47), 6),
        vmax_prefactor = ntuple(_ -> FT(1.25e-8), 6),
        vmax_modifier = FT.((10, 2, 10, 3, 3, 2)),
        km_slope = ntuple(_ -> FT(0.02), 6),
        km_intercept = ntuple(_ -> FT(3.19), 6),
        km_prefactor = ntuple(_ -> FT(0.015625), 6),
        km_modifier = FT.((8, 2, 4, 2, 4, 6)),
        oxidation_modifier = FT.((4, 4)),
        microbial_growth_efficiency = FT.((0.5, 0.25, 0.7, 0.35)),
        r_turnover = FT.((0.00052, 0.3)),
        k_turnover = FT.((0.00024, 0.1)),
        turnover_npp_denominator = FT(100),
        turnover_modifier_minimum = FT(0.6),
        turnover_modifier_maximum = FT(1.3),
        r_physical_partition = FT.((0.03, 1.3)),
        k_physical_partition = FT.((0.02, 0.8)),
        r_chemical_partition = FT.((0.1, -3, 3)),
        k_chemical_partition = FT.((0.3, -3, 3)),
        desorption = FT.((1.05e-6, -2)),
        physical_scalar = FT.((3, -2)),
        input_protection = FT.((0.005, 0.30)),
        depth_cm = FT(100),
    )
end

function mimics_model_parameters(::Type{FT}; clay = FT(0.21805)) where {FT}
    carbon = mimics_carbon_parameters(FT)
    parameter_type = MIMICS.MIMICSSoilModelParameters{FT, typeof(carbon)}
    return parameter_type(;
        carbon,
        clay,
        freezing_temperature = FT(273.15),
        cwd_q10 = FT(1.72),
        cwd_litter_optimum = FT(0.4),
        cwd_base_rate = inv(FT(365 * 0.824 * 86400)),
        cwd_respiration_fraction = FT(0.48),
    )
end

function mimics_nitrogen_parameters(::Type{FT}) where {FT}
    return MIMICS.NitrogenParameters{FT}(;
        nitrogen_use_efficiency = FT.((0.85, 0.85, 0.85, 0.85)),
        microbial_carbon_nitrogen_ratio = FT.((6, 10)),
        carbon_nitrogen_modifier = FT(0.4),
        mineral_nitrogen_available_fraction = FT(0.5),
        microbial_turnover_density_exponent = one(FT),
    )
end

function daily_map_allocations(parameters, state, inputs, environment)
    MIMICS.daily_carbon_map(parameters, state, inputs, environment)
    return @allocated MIMICS.daily_carbon_map(
        parameters,
        state,
        inputs,
        environment,
    )
end


function daily_cn_map_allocations(arguments...)
    MIMICS.daily_carbon_nitrogen_map(arguments...)
    return @allocated MIMICS.daily_carbon_nitrogen_map(arguments...)
end

function combined_carbon_allocations(
    parameters,
    state,
    temperature,
    liquid,
    frozen,
    inputs,
    metabolic_fraction,
    annual_npp,
)
    MIMICS.combined_carbon_fluxes(
        parameters,
        state...,
        temperature,
        liquid,
        frozen,
        inputs...,
        metabolic_fraction,
        annual_npp,
    )
    return @allocated MIMICS.combined_carbon_fluxes(
        parameters,
        state...,
        temperature,
        liquid,
        frozen,
        inputs...,
        metabolic_fraction,
        annual_npp,
    )
end

function combined_carbon_nitrogen_allocations(
    parameters,
    nitrogen_parameters,
    carbon,
    nitrogen,
    mineral_nitrogen,
    environment,
    carbon_inputs,
    nitrogen_inputs,
    external_nitrogen,
    litter_metabolic_fraction,
    annual_npp,
)
    MIMICS.combined_carbon_nitrogen_fluxes(
        parameters,
        nitrogen_parameters,
        carbon...,
        nitrogen...,
        mineral_nitrogen,
        environment...,
        carbon_inputs...,
        nitrogen_inputs...,
        external_nitrogen...,
        litter_metabolic_fraction,
        annual_npp,
    )
    return @allocated MIMICS.combined_carbon_nitrogen_fluxes(
        parameters,
        nitrogen_parameters,
        carbon...,
        nitrogen...,
        mineral_nitrogen,
        environment...,
        carbon_inputs...,
        nitrogen_inputs...,
        external_nitrogen...,
        litter_metabolic_fraction,
        annual_npp,
    )
end

for FT in (Float32, Float64)
    @testset "MIMICS carbon kernels, FT = $FT" begin
        parameters = mimics_carbon_parameters(FT)
        @test isbits(parameters)
        @test MIMICS.moisture_factor(FT(0.3), FT(0.2)) >= FT(0.05)
        environment = @inferred MIMICS.environmental_parameters(
            parameters,
            FT(10),
            FT(0.3),
            FT(0.1),
            FT(0.5),
            FT(300),
            FT(0.2),
        )
        negative_npp_environment = @inferred MIMICS.environmental_parameters(
            parameters,
            FT(10),
            FT(0.3),
            FT(0.1),
            FT(0.5),
            FT(-1),
            FT(0.2),
        )
        @test negative_npp_environment.r_turnover ≈
              parameters.r_turnover[1] *
              exp(parameters.r_turnover[2] * FT(0.5)) *
              parameters.turnover_modifier_minimum *
              negative_npp_environment.moisture
        state = FT.((1, 2, 0.03, 0.04, 3, 4, 5))
        inputs = FT.((0.01, 0.02))
        mapped = @inferred MIMICS.daily_carbon_map(
            parameters,
            state,
            inputs,
            environment,
        )
        hourly = @inferred MIMICS.hourly_carbon_map(
            parameters,
            state,
            inputs,
            environment,
        )
        r_loss = state[3] * environment.r_turnover
        k_loss = state[4] * environment.k_turnover
        expected_processes =
            FT.((
                r_loss,
                k_loss,
                inputs[1] / 24 * parameters.input_protection[1] +
                r_loss * environment.r_partition[1] +
                k_loss * environment.k_partition[1],
                inputs[2] / 24 * parameters.input_protection[2] +
                r_loss * environment.r_partition[2] +
                k_loss * environment.k_partition[2],
                state[7] * environment.desorption,
                state[4] * environment.vmax[5] * state[6] / (
                    parameters.oxidation_modifier[2] * environment.km[5] +
                    state[4]
                ) +
                state[3] * environment.vmax[2] * state[6] / (
                    parameters.oxidation_modifier[1] * environment.km[2] +
                    state[3]
                ),
            ))
        @test all(
            isapprox.(hourly.processes, expected_processes; rtol = 8eps(FT)),
        )
        @test daily_map_allocations(parameters, state, inputs, environment) == 0
        budget_tolerance =
            max(FT(2e-5) * sum(inputs), 32eps(FT) * sum(abs, state))
        @test sum(mapped.state .- state) + mapped.respiration ≈ sum(inputs) atol =
            budget_tolerance
    end
end


for FT in (Float32, Float64)
    @testset "MIMICS carbon-nitrogen kernels, FT = $FT" begin
        carbon_parameters = mimics_carbon_parameters(FT)
        nitrogen_parameters = mimics_nitrogen_parameters(FT)
        @test isbits(nitrogen_parameters)
        environment = MIMICS.environmental_parameters(
            carbon_parameters,
            FT(10),
            FT(0.3),
            FT(0.1),
            FT(0.5),
            FT(300),
            FT(0.2),
        )
        carbon = FT.((1, 2, 0.03, 0.04, 3, 4, 5))
        nitrogen = FT.((0.05, 0.04, 0.005, 0.004, 0.2, 0.1, 0.3))
        mineral_nitrogen = FT(0.01)
        carbon_inputs = FT.((0.01, 0.02))
        nitrogen_inputs = FT.((0.001, 0.002))
        ordered_environment =
            merge(environment, (r_partition = FT.((0.03, 0.11, 0.79)),))
        hourly = @inferred MIMICS.hourly_carbon_nitrogen_map(
            carbon_parameters,
            nitrogen_parameters,
            carbon,
            nitrogen,
            mineral_nitrogen,
            carbon_inputs,
            nitrogen_inputs,
            ordered_environment,
        )
        litter_r_m =
            carbon[3] * environment.vmax[1] * carbon[1] /
            (environment.km[1] + carbon[3])
        litter_r_s =
            carbon[3] * environment.vmax[2] * carbon[2] /
            (environment.km[2] + carbon[3])
        soil_r =
            carbon[3] * environment.vmax[3] * carbon[5] /
            (environment.km[3] + carbon[3])
        turnover_r =
            carbon[3]^nitrogen_parameters.microbial_turnover_density_exponent *
            ordered_environment.r_turnover
        turnover_r_partitions =
            turnover_r * ordered_environment.r_partition[1] +
            turnover_r * ordered_environment.r_partition[2] +
            turnover_r * ordered_environment.r_partition[3]
        din_r = mineral_nitrogen * carbon[3] / (carbon[3] + carbon[4])
        mge = carbon_parameters.microbial_growth_efficiency
        nue = nitrogen_parameters.nitrogen_use_efficiency
        small = FT(1e-10)
        uptake_r_c = mge[1] * (litter_r_m + soil_r) + mge[2] * litter_r_s
        uptake_r_n =
            nue[1] * (
                litter_r_m * nitrogen[1] / (carbon[1] + small) +
                soil_r * nitrogen[5] / (carbon[5] + small)
            ) +
            nue[2] * litter_r_s * nitrogen[2] / (carbon[2] + small) +
            din_r
        target_r =
            nitrogen_parameters.microbial_carbon_nitrogen_ratio[1] * sqrt(
                nitrogen_parameters.carbon_nitrogen_modifier /
                environment.litter_metabolic_fraction,
            )
        uptake_ratio_r = uptake_r_c / (uptake_r_n + small)
        overflow_r = uptake_r_c - uptake_r_n * min(target_r, uptake_ratio_r)
        expected_mic_r =
            carbon[3] + (uptake_r_c - turnover_r_partitions - overflow_r)
        @test hourly.carbon[3] == expected_mic_r
        mapped = @inferred MIMICS.daily_carbon_nitrogen_map(
            carbon_parameters,
            nitrogen_parameters,
            carbon,
            nitrogen,
            mineral_nitrogen,
            carbon_inputs,
            nitrogen_inputs,
            environment,
        )
        @test daily_cn_map_allocations(
            carbon_parameters,
            nitrogen_parameters,
            carbon,
            nitrogen,
            mineral_nitrogen,
            carbon_inputs,
            nitrogen_inputs,
            environment,
        ) == 0
        carbon_tolerance =
            max(FT(2e-5) * sum(carbon_inputs), 64eps(FT) * sum(carbon))
        @test sum(mapped.carbon .- carbon) + mapped.respiration ≈
              sum(carbon_inputs) atol = carbon_tolerance
        nitrogen_tolerance = max(
            FT(2e-5) * sum(nitrogen_inputs),
            128eps(FT) * (sum(nitrogen) + mineral_nitrogen),
        )
        @test sum(mapped.nitrogen .- nitrogen) + mapped.mineral_nitrogen -
              mineral_nitrogen ≈ sum(nitrogen_inputs) atol = nitrogen_tolerance
        @test mapped.microbial_assimilation >=
              mapped.overflow_r + mapped.overflow_k
        @test mapped.physical_protection >= zero(FT)

        combined_carbon = (
            carbon[1],
            carbon[2],
            FT(0.2),
            carbon[3],
            carbon[4],
            carbon[5],
            carbon[6],
            carbon[7],
        )
        combined_nitrogen = (
            nitrogen[1],
            nitrogen[2],
            nitrogen[3],
            nitrogen[4],
            nitrogen[5],
            nitrogen[6],
            nitrogen[7],
            FT(0.01),
        )
        combined_arguments = (
            mimics_model_parameters(FT),
            nitrogen_parameters,
            combined_carbon,
            combined_nitrogen,
            mineral_nitrogen,
            FT.((283.15, 0.3, 0.1)),
            FT.((1e-8, 2e-8, 3e-8)),
            FT.((1e-9, 2e-9, 3e-9)),
            FT.((1e-10, 2e-10, 3e-10)),
            FT(0.5),
            FT(0.3),
        )
        combined = @inferred MIMICS.combined_carbon_nitrogen_fluxes(
            combined_arguments[1],
            combined_arguments[2],
            combined_arguments[3]...,
            combined_arguments[4]...,
            combined_arguments[5],
            combined_arguments[6]...,
            combined_arguments[7]...,
            combined_arguments[8]...,
            combined_arguments[9]...,
            combined_arguments[10],
            combined_arguments[11],
        )
        @test length(combined) == 29
        @test combined_carbon_nitrogen_allocations(combined_arguments...) == 0
        negative_mineral = FT(-1e-7)
        negative_mineral_combined =
            @inferred MIMICS.combined_carbon_nitrogen_fluxes(
                combined_arguments[1],
                combined_arguments[2],
                combined_arguments[3]...,
                combined_arguments[4]...,
                negative_mineral,
                combined_arguments[6]...,
                combined_arguments[7]...,
                combined_arguments[8]...,
                combined_arguments[9]...,
                combined_arguments[10],
                combined_arguments[11],
            )
        @test negative_mineral_combined[21] ≈
              nitrogen_parameters.leach_rate * negative_mineral rtol = eps(FT)

        zero_microbe_carbon =
            FT.((carbon[1], carbon[2], 0, 0, carbon[5], carbon[6], carbon[7]))
        zero_microbe_nitrogen =
            FT.((
                nitrogen[1],
                nitrogen[2],
                0,
                0,
                nitrogen[5],
                nitrogen[6],
                nitrogen[7],
            ))
        zero_microbe_map = @inferred MIMICS.daily_carbon_nitrogen_map(
            carbon_parameters,
            nitrogen_parameters,
            zero_microbe_carbon,
            zero_microbe_nitrogen,
            mineral_nitrogen,
            carbon_inputs,
            nitrogen_inputs,
            environment,
        )
        @test all(isfinite, zero_microbe_map.carbon)
        @test all(isfinite, zero_microbe_map.nitrogen)
        @test zero_microbe_map.mineral_nitrogen == mineral_nitrogen
    end
end

@testset "MIMICS temporal modes" begin
    FT = Float64
    parameters = mimics_model_parameters(FT)
    drivers = MIMICS.PrescribedDrivers(
        t -> FT(283.15),
        t -> FT(0.3),
        t -> FT(0.1),
        t -> FT(1e-8),
        t -> FT(2e-8),
        t -> FT(3e-8),
        t -> FT(0.5),
        t -> FT(0.3),
    )
    domain = Point(; z_sfc = zero(FT), context = ClimaComms.context())
    legacy = MIMICS.MIMICSSoilModel{FT}(; parameters, drivers, domain)
    continuous = MIMICS.MIMICSSoilModel{FT}(;
        parameters,
        drivers,
        domain,
        temporal_mode = MIMICS.ContinuousRate(),
    )

    @test legacy.temporal_mode isa MIMICS.LegacyDaily
    @test continuous.temporal_mode isa MIMICS.ContinuousRate
    @test ClimaLand.prognostic_vars(continuous) ==
          ClimaLand.prognostic_vars(legacy)
    @test ClimaLand.auxiliary_vars(continuous) ==
          ClimaLand.auxiliary_vars(legacy)
    nitrogen_drivers = MIMICS.NitrogenPrescribedDrivers(
        t -> zero(FT),
        t -> zero(FT),
        t -> zero(FT),
        t -> zero(FT),
        t -> zero(FT),
        t -> zero(FT),
    )
    @test_throws ErrorException MIMICS.MIMICSSoilModel{FT}(;
        configuration = MIMICS.CarbonNitrogen(),
        parameters,
        nitrogen_parameters = mimics_nitrogen_parameters(FT),
        drivers,
        nitrogen_drivers,
        domain,
        temporal_mode = MIMICS.ContinuousRate(),
    )

    initial = FT.((1, 2, 0.5, 0.03, 0.04, 3, 4, 5))
    inputs = FT.((1e-8, 2e-8, 3e-8))
    fluxes = @inferred MIMICS.continuous_carbon_fluxes(
        parameters,
        initial...,
        FT(283.15),
        FT(0.3),
        FT(0.1),
        inputs...,
        FT(0.5),
        FT(0.3),
    )
    @test @allocated(
        MIMICS.continuous_carbon_fluxes(
            parameters,
            initial...,
            FT(283.15),
            FT(0.3),
            FT(0.1),
            inputs...,
            FT(0.5),
            FT(0.3),
        )
    ) == 0
    @test sum(fluxes[1:8]) + fluxes[9] ≈ sum(inputs) rtol = 32eps(FT)

    Y, p, _ = ClimaLand.initialize(continuous)
    for (name, value) in zip(ClimaLand.prognostic_vars(continuous), initial)
        getproperty(Y.mimics_soil, name) .= value
    end
    ClimaLand.make_set_initial_cache(continuous)(p, Y, zero(FT))
    @test p.mimics_soil.carbon_fluxes[] == fluxes
end

for FT in (Float32, Float64)
    @testset "MIMICS ContinuousRate AD compatibility, FT = $FT" begin
        parameters = mimics_model_parameters(FT)
        initial = FT.((1, 2, 0.5, 0.03, 0.04, 3, 4, 5))
        inputs = FT.((1e-8, 2e-8, 3e-8))
        function metabolic_litter_tendency(c_litter_metabolic)
            return MIMICS.continuous_carbon_fluxes(
                parameters,
                c_litter_metabolic,
                initial[2:end]...,
                FT(283.15),
                FT(0.3),
                FT(0.1),
                inputs...,
                FT(0.5),
                FT(0.3),
            )[1]
        end

        derivative =
            ForwardDiff.derivative(metabolic_litter_tendency, initial[1])
        step = cbrt(eps(FT)) * max(one(FT), abs(initial[1]))
        finite_difference =
            (
                metabolic_litter_tendency(initial[1] + step) -
                metabolic_litter_tendency(initial[1] - step)
            ) / (FT(2) * step)
        @test isfinite(derivative)
        @test derivative ≈ finite_difference rtol = FT(2e-3)
    end
end

@testset "MIMICS standalone soil model" begin
    for FT in (Float32, Float64)
        parameters = mimics_model_parameters(FT)
        inputs = FT.((1e-8, 2e-8, 3e-8))
        drivers = MIMICS.PrescribedDrivers(
            t -> FT(283.15),
            t -> FT(0.3),
            t -> FT(0.1),
            t -> inputs[1],
            t -> inputs[2],
            t -> inputs[3],
            t -> FT(0.5),
            t -> FT(0.3),
        )
        domain = Point(; z_sfc = zero(FT), context = ClimaComms.context())
        model = MIMICS.MIMICSSoilModel{FT}(; parameters, drivers, domain)
        @test model isa Biogeochemistry.AbstractSoilBiogeochemistryModel{FT}
        @test ClimaLand.name(model) == :mimics_soil
        Y, p, _ = ClimaLand.initialize(model)
        initial = FT.((1, 2, 0.5, 0.03, 0.04, 3, 4, 5))
        for (name, value) in zip(ClimaLand.prognostic_vars(model), initial)
            getproperty(Y.mimics_soil, name) .= value
        end
        tendency! = ClimaLand.make_exp_tendency(model)
        ClimaLand.make_set_initial_cache(model)(p, Y, zero(FT))
        FT == Float32 && test_model_diagnostics(model, Y, p, zero(FT))
        dY = similar(Y)
        tendency!(dY, Y, p, zero(FT))
        fluxes = p.mimics_soil.carbon_fluxes[]
        direct_fluxes = @inferred MIMICS.combined_carbon_fluxes(
            parameters,
            initial...,
            FT(283.15),
            FT(0.3),
            FT(0.1),
            inputs...,
            FT(0.5),
            FT(0.3),
        )
        @test fluxes == direct_fluxes
        @test combined_carbon_allocations(
            parameters,
            initial,
            FT(283.15),
            FT(0.3),
            FT(0.1),
            inputs,
            FT(0.5),
            FT(0.3),
        ) == 0
        day = FT(86400)
        concentration_factor = FT(100) / parameters.carbon.depth_cm
        temperature = Biogeochemistry.CASA.temperature_factor(
            parameters.cwd_q10,
            FT(283.15),
            parameters.freezing_temperature,
        )
        cwd_moisture = Biogeochemistry.CASA.moisture_factor(FT(0.3), false)
        cwd_fraction =
            parameters.cwd_base_rate *
            day *
            parameters.cwd_litter_optimum *
            temperature *
            cwd_moisture
        cwd_loss = cwd_fraction * initial[3]
        cwd_transfer =
            (one(FT) - parameters.cwd_respiration_fraction) * cwd_loss
        environment = MIMICS.environmental_parameters(
            parameters.carbon,
            FT(10),
            FT(0.3),
            FT(0.1),
            FT(0.5),
            FT(300),
            parameters.clay,
        )
        mapped = MIMICS.daily_carbon_map(
            parameters.carbon,
            (
                initial[1],
                initial[2],
                initial[4],
                initial[5],
                initial[6],
                initial[7],
                initial[8],
            ),
            (
                inputs[1] * day * concentration_factor,
                (inputs[2] * day + cwd_transfer) * concentration_factor,
            ),
            environment,
        )
        expected_processes = mapped.processes ./ (concentration_factor * day)
        @test all(
            isapprox.(fluxes[11:16], expected_processes; rtol = 16eps(FT)),
        )
        @test fluxes[17] ≈ cwd_transfer / day rtol = 16eps(FT)
        tendencies = map(ClimaLand.prognostic_vars(model)) do name
            Array(parent(getproperty(dY.mimics_soil, name)))[1]
        end
        @test tendencies == Tuple(fluxes[1:8])
        budget_tolerance =
            max(FT(2e-5) * sum(inputs), 32eps(FT) * sum(abs, initial) / day)
        @test sum(tendencies) + fluxes[9] ≈ sum(inputs) atol = budget_tolerance

        continuous_model = MIMICS.MIMICSSoilModel{FT}(;
            parameters,
            drivers,
            domain,
            temporal_mode = MIMICS.ContinuousRate(),
        )
        continuous_Y, continuous_p, _ = ClimaLand.initialize(continuous_model)
        for (name, value) in
            zip(ClimaLand.prognostic_vars(continuous_model), initial)
            getproperty(continuous_Y.mimics_soil, name) .= value
        end
        ClimaLand.make_set_initial_cache(continuous_model)(
            continuous_p,
            continuous_Y,
            zero(FT),
        )
        continuous_fluxes = @inferred MIMICS.continuous_carbon_fluxes(
            parameters,
            initial...,
            FT(283.15),
            FT(0.3),
            FT(0.1),
            inputs...,
            FT(0.5),
            FT(0.3),
        )
        @test continuous_p.mimics_soil.carbon_fluxes[] == continuous_fluxes
        @test sum(continuous_fluxes[1:8]) + continuous_fluxes[9] ≈ sum(inputs) rtol =
            FT(64) * eps(FT)

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
        actual = map(ClimaLand.prognostic_vars(model)) do name
            Array(parent(getproperty(integrator.u.mimics_soil, name)))[1]
        end
        @test all(isapprox.(actual, expected; rtol = 16eps(FT)))
        if FT == Float32
            test_checkpoint_roundtrip(model, integrator.u, Float64(day))
            test_checkpoint_roundtrip(
                continuous_model,
                continuous_Y,
                Float64(day),
            )
            plane = Plane(;
                xlim = FT.((0, 2)),
                ylim = FT.((0, 2)),
                nelements = (2, 2),
                context = ClimaComms.context(),
            )
            grid_model = MIMICS.MIMICSSoilModel{FT}(;
                parameters,
                drivers,
                domain = plane,
            )
            test_gridded_tendency(
                grid_model,
                initial,
                tendencies,
                zero(FT),
                16eps(FT),
            )
            continuous_grid_model = MIMICS.MIMICSSoilModel{FT}(;
                parameters,
                drivers,
                domain = plane,
                temporal_mode = MIMICS.ContinuousRate(),
            )
            test_gridded_tendency(
                continuous_grid_model,
                initial,
                Tuple(continuous_fluxes[1:8]),
                zero(FT),
                16eps(FT),
            )

            spatial_variant = mimics_model_parameters(FT; clay = FT(0.4))
            x = ClimaCore.Fields.coordinate_field(plane.space.surface).x
            spatial_parameters =
                @. ifelse(x < FT(1), parameters, spatial_variant)
            @test axes(spatial_parameters) == plane.space.surface
            @test eltype(spatial_parameters) == typeof(parameters)

            spatial_model = MIMICS.MIMICSSoilModel{FT}(;
                parameters = spatial_parameters,
                drivers,
                domain = plane,
            )
            spatial_Y, spatial_p, _ = ClimaLand.initialize(spatial_model)
            for (name, value) in
                zip(ClimaLand.prognostic_vars(spatial_model), initial)
                getproperty(spatial_Y.mimics_soil, name) .= value
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

            right_fluxes = MIMICS.combined_carbon_fluxes(
                spatial_variant,
                initial...,
                FT(283.15),
                FT(0.3),
                FT(0.1),
                inputs...,
                FT(0.5),
                FT(0.3),
            )
            x_values = Array(parent(x))
            left = x_values .< FT(1)
            right = .!left
            spatial_tendency =
                Array(parent(spatial_dY.mimics_soil.c_soil_available))
            @test all(spatial_tendency[left] .≈ tendencies[6])
            @test all(spatial_tendency[right] .≈ right_fluxes[6])
        end
    end
end


function integrate_mimics(model, initial, stop_time, timestep)
    Y, p, _ = ClimaLand.initialize(model)
    for (name, value) in zip(ClimaLand.prognostic_vars(model), initial)
        getproperty(Y.mimics_soil, name) .= value
    end
    tendency! = ClimaLand.make_exp_tendency(model)
    problem = CTS.ODEProblem(
        CTS.ClimaODEFunction((T_exp!) = tendency!),
        Y,
        (0.0, Float64(stop_time)),
        p,
    )
    integrator = CTS.init(
        problem,
        FORWARD_EULER;
        dt = Float64(timestep),
        save_everystep = false,
    )
    for _ in 1:round(Int, stop_time / timestep)
        CTS.step!(integrator)
    end
    return map(ClimaLand.prognostic_vars(model)) do name
        getproperty(integrator.u.mimics_soil, name)[]
    end
end

@testset "MIMICS ContinuousRate timestep refinement" begin
    FT = Float64
    day = FT(86400)
    parameters = mimics_model_parameters(FT)
    inputs = FT.((1e-8, 2e-8, 3e-8))
    drivers = MIMICS.PrescribedDrivers(
        t -> FT(283.15),
        t -> FT(0.3),
        t -> FT(0.1),
        t -> inputs[1],
        t -> inputs[2],
        t -> inputs[3],
        t -> FT(0.5),
        t -> FT(0.3),
    )
    domain = Point(; z_sfc = zero(FT), context = ClimaComms.context())
    continuous = MIMICS.MIMICSSoilModel{FT}(;
        parameters,
        drivers,
        domain,
        temporal_mode = MIMICS.ContinuousRate(),
    )
    legacy = MIMICS.MIMICSSoilModel{FT}(; parameters, drivers, domain)
    initial = FT.((1, 2, 0.5, 0.03, 0.04, 3, 4, 5))
    timesteps = FT.((3600, 1800, 900, 450))
    solutions = map(timesteps) do timestep
        integrate_mimics(continuous, initial, day, timestep)
    end
    refinement_errors = map(1:3) do index
        sum(abs.(solutions[index] .- solutions[index + 1]))
    end
    @test refinement_errors[2] < FT(0.55) * refinement_errors[1]
    @test refinement_errors[3] < FT(0.55) * refinement_errors[2]

    legacy_day = integrate_mimics(legacy, initial, day, day)
    relative_legacy_distance =
        sum(abs.(solutions[end] .- legacy_day)) / sum(abs, legacy_day)
    @test relative_legacy_distance ≈ FT(2.2978040984025262e-8) rtol = FT(1e-6)
end


@testset "MIMICS standalone carbon-nitrogen model" begin
    for FT in (Float32, Float64)
        parameters = mimics_model_parameters(FT)
        nitrogen_parameters = mimics_nitrogen_parameters(FT)
        carbon_inputs = FT.((1e-8, 2e-8, 3e-8))
        nitrogen_inputs = FT.((1e-10, 2e-10, 3e-10))
        deposition = FT(4e-11)
        fixation = FT(5e-11)
        uptake = FT(6e-11)
        drivers = MIMICS.PrescribedDrivers(
            t -> FT(283.15),
            t -> FT(0.3),
            t -> FT(0.1),
            t -> carbon_inputs[1],
            t -> carbon_inputs[2],
            t -> carbon_inputs[3],
            t -> FT(0.5),
            t -> FT(0.3),
        )
        nitrogen_drivers = MIMICS.NitrogenPrescribedDrivers(
            t -> nitrogen_inputs[1],
            t -> nitrogen_inputs[2],
            t -> nitrogen_inputs[3],
            t -> deposition,
            t -> fixation,
            t -> uptake,
        )
        domain = Point(; z_sfc = zero(FT), context = ClimaComms.context())
        model = MIMICS.MIMICSSoilModel{FT}(;
            configuration = MIMICS.CarbonNitrogen(),
            parameters,
            nitrogen_parameters,
            drivers,
            nitrogen_drivers,
            domain,
        )
        @test length(ClimaLand.prognostic_vars(model)) == 17
        Y, p, _ = ClimaLand.initialize(model)
        initial =
            FT.((
                1,
                2,
                0.5,
                0.03,
                0.04,
                3,
                4,
                5,
                0.05,
                0.04,
                0.005,
                0.004,
                0.2,
                0.1,
                0.3,
                0.002,
                0.01,
            ))
        for (name, value) in zip(ClimaLand.prognostic_vars(model), initial)
            getproperty(Y.mimics_soil, name) .= value
        end
        ClimaLand.make_set_initial_cache(model)(p, Y, zero(FT))
        FT == Float32 && test_model_diagnostics(model, Y, p, zero(FT))
        dY = similar(Y)
        ClimaLand.make_exp_tendency(model)(dY, Y, p, zero(FT))
        point_tendencies = map(ClimaLand.prognostic_vars(model)) do name
            getproperty(dY.mimics_soil, name)[]
        end
        nitrogen_names = ClimaLand.prognostic_vars(model)[9:17]
        nitrogen_tendency =
            sum(getproperty(dY.mimics_soil, name)[] for name in nitrogen_names)
        nitrogen_fluxes = p.mimics_soil.nitrogen_fluxes[]
        conservation_tolerance = max(
            FT(256) * eps(FT) * sum(nitrogen_inputs),
            FT(256) * eps(FT) * sum(initial[9:17]) / FT(86400),
        )
        @test nitrogen_tendency +
              nitrogen_fluxes[10] +
              nitrogen_fluxes[11] +
              uptake ≈ sum(nitrogen_inputs) + deposition + fixation atol =
            conservation_tolerance

        day = FT(86400)
        problem = CTS.ODEProblem(
            CTS.ClimaODEFunction((T_exp!) = ClimaLand.make_exp_tendency(model)),
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
        @test all(
            isfinite(getproperty(integrator.u.mimics_soil, name)[]) for
            name in ClimaLand.prognostic_vars(model)
        )
        if FT == Float32
            test_checkpoint_roundtrip(model, integrator.u, Float64(day))
            plane = Plane(;
                xlim = FT.((0, 2)),
                ylim = FT.((0, 2)),
                nelements = (2, 2),
                context = ClimaComms.context(),
            )
            grid_model = MIMICS.MIMICSSoilModel{FT}(;
                configuration = MIMICS.CarbonNitrogen(),
                parameters,
                nitrogen_parameters,
                drivers,
                nitrogen_drivers,
                domain = plane,
            )
            test_gridded_tendency(
                grid_model,
                initial,
                point_tendencies,
                zero(FT),
                64eps(FT),
            )

            x = ClimaCore.Fields.coordinate_field(plane.space.surface).x
            nitrogen_variant = MIMICS.NitrogenParameters{FT}(;
                nitrogen_use_efficiency = nitrogen_parameters.nitrogen_use_efficiency,
                microbial_carbon_nitrogen_ratio = nitrogen_parameters.microbial_carbon_nitrogen_ratio,
                carbon_nitrogen_modifier = nitrogen_parameters.carbon_nitrogen_modifier,
                mineral_nitrogen_available_fraction = FT(0.25),
                microbial_turnover_density_exponent = nitrogen_parameters.microbial_turnover_density_exponent,
                maximum_fine_litter = nitrogen_parameters.maximum_fine_litter,
                maximum_cwd = nitrogen_parameters.maximum_cwd,
                loss_threshold = nitrogen_parameters.loss_threshold,
                loss_fraction = nitrogen_parameters.loss_fraction,
                leach_rate = nitrogen_parameters.leach_rate,
            )
            spatial_nitrogen_parameters =
                @. ifelse(x < FT(1), nitrogen_parameters, nitrogen_variant)
            @test axes(spatial_nitrogen_parameters) == plane.space.surface
            @test eltype(spatial_nitrogen_parameters) ==
                  typeof(nitrogen_parameters)
            spatial_model = MIMICS.MIMICSSoilModel{FT}(;
                configuration = MIMICS.CarbonNitrogen(),
                parameters,
                nitrogen_parameters = spatial_nitrogen_parameters,
                drivers,
                nitrogen_drivers,
                domain = plane,
            )
            spatial_Y, spatial_p, _ = ClimaLand.initialize(spatial_model)
            for (name, value) in
                zip(ClimaLand.prognostic_vars(spatial_model), initial)
                getproperty(spatial_Y.mimics_soil, name) .= value
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
            x_values = Array(parent(x))
            mineral_tendency = Array(parent(spatial_dY.mimics_soil.n_mineral))
            left = mineral_tendency[x_values .< FT(1)]
            right = mineral_tendency[x_values .>= FT(1)]
            @test all(left .≈ first(left))
            @test all(right .≈ first(right))
            @test !isapprox(first(left), first(right); rtol = 64eps(FT))
        end
    end
end

function fixture_litter_quality(mimics, casa, day)
    root_turnover = Float64(casa["cfroot"][1, 1, day - 1]) / (5 * 365)
    leaf_fraction = 0.75 * (0.85 - 0.013 * 8)
    root_fraction = 0.75 * (0.85 - 0.013 * 8.2)
    metabolic = Float64(mimics["cLitInput_metb"][1, 1, day])
    structural = Float64(mimics["cLitInput_struc"][1, 1, day])
    leaf_turnover = (metabolic - root_fraction * root_turnover) / leaf_fraction
    cwd_to_structural =
        structural - leaf_turnover * (1 - leaf_fraction) -
        root_turnover * (1 - root_fraction)
    total = leaf_turnover + root_turnover + cwd_to_structural
    lignin_to_nitrogen = min(
        40.0,
        (8 * leaf_turnover + 8.2 * root_turnover + 60 * cwd_to_structural) /
        max(0.001, total),
    )
    return 0.75 * (0.85 - 0.013 * lignin_to_nitrogen)
end


function fixture_cn_litter_quality(mimics, casa, day)
    value(dataset, name, index) = Float64(dataset[name][1, 1, index])
    previous = day - 1
    leaf_carbon = value(casa, "cleaf", previous)
    root_carbon = value(casa, "cfroot", previous)
    leaf_nitrogen = value(casa, "nleaf", previous)
    root_nitrogen = value(casa, "nfroot", previous)
    leaf_ratio = min(leaf_carbon / max(1e-10, leaf_nitrogen), 50.0) / 0.5 * 0.2
    root_ratio = min(root_carbon / max(1e-10, root_nitrogen), 41.0) / 0.9 * 0.2
    temperature = value(casa, "tsoilC", day) + 273.15
    liquid = value(mimics, "thetaLiq", day)
    temperature_factor = 1.72^(0.1 * (temperature - 273.15 - 35))
    cwd_moisture = Biogeochemistry.CASA.moisture_factor(liquid, false)
    previous_cwd = value(casa, "clitcwd", previous)
    cwd_loss =
        0.4 * temperature_factor * cwd_moisture / (365 * 0.824) * previous_cwd
    cwd_to_structural = 0.52 * cwd_loss
    total_fine_litter =
        value(mimics, "cLitInput_metb", day) +
        value(mimics, "cLitInput_struc", day) - cwd_to_structural
    root_turnover = root_carbon / (5 * 365)
    leaf_turnover = total_fine_litter - root_turnover
    total = leaf_turnover + root_turnover + cwd_to_structural
    average_ratio = min(
        40.0,
        (
            leaf_ratio * leaf_turnover +
            root_ratio * root_turnover +
            60 * cwd_to_structural
        ) / max(0.001, total),
    )
    return 0.75 * (0.85 - 0.013 * average_ratio)
end

@testset "MIMICS productive-cell daily map" begin
    fixture = normpath(
        joinpath(
            @__DIR__,
            "../../../testbed_validation/fixtures/mimics_c_cell_11060",
        ),
    )
    parameters = mimics_model_parameters(Float64)
    mimics_path = joinpath(fixture, "mimics_1901_1905_cell_11060.nc")
    casa_path = joinpath(fixture, "casa_1901_1905_cell_11060.nc")
    NCDataset(mimics_path) do mimics
        NCDataset(casa_path) do casa
            mimics_names =
                ("cLITm", "cLITs", "cMICr", "cMICk", "cSOMa", "cSOMc", "cSOMp")
            maximum_relative_error = 0.0
            maximum_respiration_error = 0.0
            maximum_moisture_error = 0.0
            continuous_state = (
                Float64(mimics[mimics_names[1]][1, 1, 1]) / 1000,
                Float64(mimics[mimics_names[2]][1, 1, 1]) / 1000,
                Float64(casa["clitcwd"][1, 1, 1]) / 1000,
                ntuple(
                    index ->
                        Float64(mimics[mimics_names[index]][1, 1, 1]) / 1000,
                    7,
                )[3:end]...,
            )
            maximum_continuous_pool_error = 0.0
            maximum_continuous_respiration_error = 0.0
            for day in 2:365
                previous = ntuple(
                    index ->
                        Float64(mimics[mimics_names[index]][1, 1, day - 1]) / 1000,
                    7,
                )
                expected_mimics = ntuple(
                    index ->
                        Float64(mimics[mimics_names[index]][1, 1, day]) / 1000,
                    7,
                )
                previous_cwd = Float64(casa["clitcwd"][1, 1, day - 1]) / 1000
                expected_cwd = Float64(casa["clitcwd"][1, 1, day]) / 1000
                liquid = Float64(mimics["thetaLiq"][1, 1, day])
                frozen = Float64(mimics["thetaFrzn"][1, 1, day])
                temperature = Float64(casa["tsoilC"][1, 1, day]) + 273.15
                temperature_factor = 1.72^(0.1 * (temperature - 273.15 - 35))
                cwd_moisture =
                    Biogeochemistry.CASA.moisture_factor(liquid, false)
                cwd_loss =
                    0.4 * temperature_factor * cwd_moisture / (365 * 0.824) *
                    previous_cwd
                cwd_to_structural = 0.52 * cwd_loss
                cwd_input = expected_cwd - previous_cwd + cwd_loss
                metabolic_input =
                    Float64(mimics["cLitInput_metb"][1, 1, day]) / 1000
                structural_input =
                    Float64(mimics["cLitInput_struc"][1, 1, day]) / 1000 -
                    cwd_to_structural
                state = (
                    previous[1],
                    previous[2],
                    previous_cwd,
                    previous[3],
                    previous[4],
                    previous[5],
                    previous[6],
                    previous[7],
                )
                fluxes = MIMICS.combined_carbon_fluxes(
                    parameters,
                    state...,
                    temperature,
                    liquid,
                    frozen,
                    metabolic_input / 86400,
                    structural_input / 86400,
                    cwd_input / 86400,
                    fixture_litter_quality(mimics, casa, day),
                    0.3,
                )
                actual = state .+ 86400 .* Tuple(fluxes[1:8])
                expected = (
                    expected_mimics[1],
                    expected_mimics[2],
                    expected_cwd,
                    expected_mimics[3],
                    expected_mimics[4],
                    expected_mimics[5],
                    expected_mimics[6],
                    expected_mimics[7],
                )
                continuous_respiration = 0.0
                for _ in 1:96
                    continuous_fluxes = MIMICS.continuous_carbon_fluxes(
                        parameters,
                        continuous_state...,
                        temperature,
                        liquid,
                        frozen,
                        metabolic_input / 86400,
                        structural_input / 86400,
                        cwd_input / 86400,
                        fixture_litter_quality(mimics, casa, day),
                        0.3,
                    )
                    continuous_state =
                        continuous_state .+ 900 .* Tuple(continuous_fluxes[1:8])
                    continuous_respiration += 900 * continuous_fluxes[9]
                end
                maximum_continuous_pool_error = max(
                    maximum_continuous_pool_error,
                    maximum(abs.(1000 .* (continuous_state .- expected))),
                )
                maximum_relative_error = max(
                    maximum_relative_error,
                    maximum(abs.((actual .- expected) ./ expected)),
                )
                expected_respiration =
                    Float64(mimics["cHresp"][1, 1, day]) / 1000 / 86400
                maximum_respiration_error = max(
                    maximum_respiration_error,
                    abs(fluxes[9] - expected_respiration),
                )
                maximum_continuous_respiration_error = max(
                    maximum_continuous_respiration_error,
                    abs(
                        1000 * continuous_respiration -
                        Float64(mimics["cHresp"][1, 1, day]),
                    ),
                )
                maximum_moisture_error = max(
                    maximum_moisture_error,
                    abs(fluxes[10] - Float64(mimics["fW"][1, 1, day])),
                )
            end
            @test maximum_relative_error < 2e-7
            @test maximum_respiration_error < 2e-15
            @test maximum_moisture_error < 7e-8
            @test maximum_continuous_pool_error < 0.0011
            @test maximum_continuous_respiration_error < 4e-5
        end
    end
end


@testset "MIMICS productive-cell carbon-nitrogen daily map" begin
    fixture = normpath(
        joinpath(
            @__DIR__,
            "../../../testbed_validation/fixtures/mimics_cn_cell_11060",
        ),
    )
    carbon_parameters = mimics_carbon_parameters(Float64)
    nitrogen_parameters = mimics_nitrogen_parameters(Float64)
    mimics_path = joinpath(fixture, "mimics_1901_1905_cell_11060.nc")
    casa_path = joinpath(fixture, "casa_1901_1905_cell_11060.nc")
    NCDataset(mimics_path) do mimics
        NCDataset(casa_path) do casa
            carbon_names =
                ("cLITm", "cLITs", "cMICr", "cMICk", "cSOMa", "cSOMc", "cSOMp")
            nitrogen_names =
                ("nLITm", "nLITs", "nMICr", "nMICk", "nSOMa", "nSOMc", "nSOMp")
            value(dataset, name, day) = Float64(dataset[name][1, 1, day])
            maximum_carbon_error = 0.0
            maximum_nitrogen_error = 0.0
            maximum_din_error = 0.0
            maximum_respiration_error = 0.0
            maximum_overflow_error = 0.0
            maximum_nitrogen_flux_error = 0.0
            for day in 2:365
                concentration(name, index) = value(mimics, name, index) / 1000
                carbon = ntuple(
                    index -> concentration(carbon_names[index], day - 1),
                    7,
                )
                nitrogen = ntuple(
                    index -> concentration(nitrogen_names[index], day - 1),
                    7,
                )
                carbon_inputs = (
                    concentration("cLitInput_metb", day),
                    concentration("cLitInput_struc", day),
                )
                nitrogen_inputs = (
                    concentration("nLitInput_metb", day),
                    concentration("nLitInput_struc", day),
                )
                mineral_nitrogen =
                    0.5 * (
                        value(casa, "nMineral", day - 1) -
                        value(casa, "nMinLeach", day)
                    ) / 1000
                environment = MIMICS.environmental_parameters(
                    carbon_parameters,
                    value(casa, "tsoilC", day),
                    value(mimics, "thetaLiq", day),
                    value(mimics, "thetaFrzn", day),
                    fixture_cn_litter_quality(mimics, casa, day),
                    300.0,
                    0.21805,
                )
                mapped = MIMICS.daily_carbon_nitrogen_map(
                    carbon_parameters,
                    nitrogen_parameters,
                    carbon,
                    nitrogen,
                    mineral_nitrogen,
                    carbon_inputs,
                    nitrogen_inputs,
                    environment,
                )
                expected_carbon =
                    ntuple(index -> concentration(carbon_names[index], day), 7)
                expected_nitrogen = ntuple(
                    index -> concentration(nitrogen_names[index], day),
                    7,
                )
                maximum_carbon_error = max(
                    maximum_carbon_error,
                    maximum(
                        abs.(
                            (mapped.carbon .- expected_carbon) ./
                            expected_carbon
                        ),
                    ),
                )
                maximum_nitrogen_error = max(
                    maximum_nitrogen_error,
                    maximum(
                        abs.(
                            (mapped.nitrogen .- expected_nitrogen) ./
                            expected_nitrogen
                        ),
                    ),
                )
                maximum_din_error = max(
                    maximum_din_error,
                    abs(mapped.mineral_nitrogen - concentration("DIN", day)),
                )
                temperature_factor =
                    1.72^(0.1 * (value(casa, "tsoilC", day) - 35))
                cwd_moisture = Biogeochemistry.CASA.moisture_factor(
                    value(mimics, "thetaLiq", day),
                    false,
                )
                cwd_respiration =
                    0.48 * 0.4 * temperature_factor * cwd_moisture /
                    (365 * 0.824) * value(casa, "clitcwd", day - 1) / 1000
                maximum_respiration_error = max(
                    maximum_respiration_error,
                    abs(
                        mapped.respiration + cwd_respiration -
                        concentration("cHresp", day),
                    ),
                )
                maximum_overflow_error = max(
                    maximum_overflow_error,
                    abs(mapped.overflow_r - concentration("cOverflow_r", day)),
                    abs(mapped.overflow_k - concentration("cOverflow_k", day)),
                )
                nitrogen_fluxes = (
                    mapped.litter_mineralization,
                    mapped.soil_mineralization,
                    mapped.immobilization,
                )
                expected_fluxes = (
                    value(casa, "nLitMineralization", day) / 1000,
                    value(casa, "nSoilMineralization", day) / 1000,
                    value(casa, "nSoilImmob", day) / 1000,
                )
                maximum_nitrogen_flux_error = max(
                    maximum_nitrogen_flux_error,
                    maximum(abs.(nitrogen_fluxes .- expected_fluxes)),
                )
            end
            @test maximum_carbon_error < 3e-6
            @test maximum_nitrogen_error < 3e-6
            @test maximum_din_error < 3e-9
            @test maximum_respiration_error < 3e-9
            @test maximum_overflow_error < 3e-9
            @test maximum_nitrogen_flux_error < 3e-9
        end
    end
end
