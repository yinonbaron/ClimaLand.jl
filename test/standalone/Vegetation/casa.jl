using Test
using NCDatasets
import ClimaLand
import ClimaComms
import ClimaCore
ClimaComms.@import_required_backends
using ClimaLand.Vegetation
using ClimaLand.Domains: Plane, Point
import ClimaTimeSteppers as CTS

include("../../testbed_validation/model_architecture.jl")

const CASA = Vegetation.CASA
const FORWARD_EULER = CTS.ExplicitAlgorithm(
    CTS.ExplicitTableau(;
        a = zeros(Int, 1, 1),
        b = ones(Int, 1),
        c = zeros(Int, 1),
    ),
)

function plant_parameters(
    ::Type{FT};
    nonwoody = false,
    root_exudate_fraction = zero(FT),
    plant_nitrogen_ratio = ntuple(_ -> zero(FT), 3),
    turnover_rates = nothing,
) where {FT}
    day = FT(86400)
    year = FT(365) * day
    turnover_rates =
        isnothing(turnover_rates) ?
        (inv(year), inv(FT(40) * year), inv(FT(5) * year)) : turnover_rates
    return CASA.CASAPlantModelParameters{FT}(;
        allocation = (FT(0.4), FT(0.15), FT(0.45)),
        turnover_rates,
        maintenance_rates = (FT(0.1) / year, FT(6) / year, FT(6) / year),
        plant_nitrogen = (FT(2.2e-3), FT(2.5e-3), FT(19e-3)),
        plant_nitrogen_ratio,
        leaf_phosphorus_to_nitrogen = inv(FT(15)),
        labile_loss_rate = inv(FT(0.2) * year),
        specific_leaf_area = FT(9.92),
        minimum_leaf_area_index = FT(0.1),
        maximum_leaf_area_index = FT(3),
        shedding_temperature = FT(277.15),
        cold_turnover_maximum = inv(year),
        cold_turnover_exponent = FT(3),
        drought_turnover_maximum = FT(0.1) / year,
        drought_turnover_exponent = FT(3),
        freezing_temperature = FT(273.15),
        root_exudate_fraction,
        nonwoody,
    )
end

@testset "CASA plant temporal modes" begin
    FT = Float64
    day = FT(86400)
    parameters =
        plant_parameters(FT; turnover_rates = ntuple(_ -> FT(2) / day, 3))
    nitrogen_parameters = CASA.CASAPlantNitrogenParameters{FT}(;
        nitrogen_ratio_minimum = (FT(0.02), FT(0.006666667), FT(0.024390244)),
        nitrogen_ratio_maximum = (FT(0.03), FT(0.008), FT(0.029268293)),
        nitrogen_fraction_to_litter = (FT(0.5), FT(0.95), FT(0.9)),
        lignin_fraction = (FT(0.2), FT(0.4), FT(0.2)),
        structural_litter_nitrogen_ratio = inv(FT(150)),
        limitation_minimum = FT(0.5e-3),
        limitation_maximum = FT(2e-3),
        mineral_half_saturation = FT(2e-3),
    )
    drivers = CASA.PrescribedDrivers(
        t -> zero(FT),
        t -> FT(240),
        t -> FT(240),
        t -> one(FT),
        t -> FT(2),
        t -> one(FT),
        t -> zero(FT),
    )
    nitrogen_drivers = CASA.NitrogenPrescribedDrivers(
        t -> zero(FT),
        t -> zero(FT),
        t -> zero(FT),
    )
    domain = Point(; z_sfc = zero(FT), context = ClimaComms.context())
    legacy = CASA.CASAPlantModel{FT}(;
        configuration = CASA.CarbonNitrogen(),
        parameters,
        nitrogen_parameters,
        drivers,
        nitrogen_drivers,
        domain,
    )
    continuous = CASA.CASAPlantModel{FT}(;
        configuration = CASA.CarbonNitrogen(),
        parameters,
        nitrogen_parameters,
        drivers,
        nitrogen_drivers,
        domain,
        temporal_mode = CASA.ContinuousRate(),
    )
    @test legacy.temporal_mode isa CASA.LegacyDaily
    @test continuous.temporal_mode isa CASA.ContinuousRate
    @test ClimaLand.prognostic_vars(continuous) ==
          ClimaLand.prognostic_vars(legacy)
    @test ClimaLand.auxiliary_vars(continuous) ==
          ClimaLand.auxiliary_vars(legacy)

    initial = FT.((0.09, 0.37, 0.14, 0.01, 0.002, 0.003, 0.004))
    function cached_fluxes(model)
        Y, p, _ = ClimaLand.initialize(model)
        for (name, value) in zip(ClimaLand.prognostic_vars(model), initial)
            getproperty(Y.casa_plant, name) .= value
        end
        ClimaLand.make_set_initial_cache(model)(p, Y, zero(FT))
        return p.casa_plant.carbon_fluxes[], p.casa_plant.nitrogen_fluxes[]
    end
    legacy_carbon, legacy_nitrogen = cached_fluxes(legacy)
    continuous_carbon, continuous_nitrogen = cached_fluxes(continuous)

    @test Tuple(legacy_carbon[1:3]) ==
          Tuple(-initial[index] / day for index in 1:3)
    @test Tuple(continuous_carbon[1:3]) ==
          Tuple(-continuous_carbon[index] for index in 8:10)
    @test Tuple(legacy_carbon[8:10]) == Tuple(continuous_carbon[8:10])
    @test all(iszero, legacy_nitrogen[1:3])
    @test any(!iszero, continuous_nitrogen[1:3])
    legacy_carbon_kernel = @inferred CASA.packed_carbon_fluxes(
        CASA.LegacyDaily(),
        parameters,
        initial[1:4]...,
        zero(FT),
        FT(240),
        FT(240),
        one(FT),
        FT(2),
        one(FT),
        zero(FT),
        initial[5:7]...,
    )
    @test legacy_carbon_kernel == legacy_carbon
    @test @allocated(
        CASA.packed_carbon_fluxes(
            CASA.LegacyDaily(),
            parameters,
            initial[1:4]...,
            zero(FT),
            FT(240),
            FT(240),
            one(FT),
            FT(2),
            one(FT),
            zero(FT),
            initial[5:7]...,
        )
    ) == 0
    legacy_nitrogen_kernel = @inferred CASA.packed_nitrogen_fluxes(
        CASA.LegacyDaily(),
        nitrogen_parameters,
        initial[1:3]...,
        initial[5:7]...,
        zero(FT),
        zero(FT),
        zero(FT),
        legacy_carbon,
    )
    @test legacy_nitrogen_kernel == legacy_nitrogen
    @test @allocated(
        CASA.packed_nitrogen_fluxes(
            CASA.LegacyDaily(),
            nitrogen_parameters,
            initial[1:3]...,
            initial[5:7]...,
            zero(FT),
            zero(FT),
            zero(FT),
            legacy_carbon,
        )
    ) == 0
    continuous_nitrogen_kernel = @inferred CASA.packed_nitrogen_fluxes(
        CASA.ContinuousRate(),
        nitrogen_parameters,
        initial[1:3]...,
        initial[5:7]...,
        zero(FT),
        zero(FT),
        zero(FT),
        continuous_carbon,
    )
    @test continuous_nitrogen_kernel == continuous_nitrogen
    @test @allocated(
        CASA.packed_nitrogen_fluxes(
            CASA.ContinuousRate(),
            nitrogen_parameters,
            initial[1:3]...,
            initial[5:7]...,
            zero(FT),
            zero(FT),
            zero(FT),
            continuous_carbon,
        )
    ) == 0

    edge_leaf_carbon = FT(0.003)
    edge_carbon_fluxes =
        Base.setindex(legacy_carbon, -edge_leaf_carbon / day, 1)
    edge_nitrogen = CASA.packed_nitrogen_fluxes(
        CASA.LegacyDaily(),
        nitrogen_parameters,
        edge_leaf_carbon,
        initial[2:3]...,
        initial[5:7]...,
        zero(FT),
        zero(FT),
        zero(FT),
        edge_carbon_fluxes,
    )
    @test all(iszero, edge_nitrogen[1:3])
end

function integrate_plant(model, initial, stop_time, timestep)
    Y, p, _ = ClimaLand.initialize(model)
    for (name, value) in zip(ClimaLand.prognostic_vars(model), initial)
        getproperty(Y.casa_plant, name) .= value
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
        getproperty(integrator.u.casa_plant, name)[]
    end
end

@testset "CASA ContinuousRate timestep refinement" begin
    FT = Float64
    day = FT(86400)
    parameters = plant_parameters(FT)
    drivers = CASA.PrescribedDrivers(
        t -> FT(2e-7),
        t -> FT(283.15),
        t -> FT(278.15),
        t -> FT(0.7),
        t -> FT(2),
        t -> one(FT),
        t -> zero(FT),
    )
    domain = Point(; z_sfc = zero(FT), context = ClimaComms.context())
    continuous = CASA.CASAPlantModel{FT}(;
        parameters,
        drivers,
        domain,
        temporal_mode = CASA.ContinuousRate(),
    )
    legacy = CASA.CASAPlantModel{FT}(; parameters, drivers, domain)
    initial = FT.((0.09, 0.37, 0.14, 0.01))
    stop_time = FT(30) * day
    refinements = (1, 2, 4, 8, 16, 32)
    solutions = map(refinements) do refinement
        integrate_plant(continuous, initial, stop_time, day / FT(refinement))
    end
    reference = solutions[end]
    errors = map(solutions[1:(end - 1)]) do solution
        sum(abs.(solution .- reference))
    end
    @test all(
        errors[index] > errors[index + 1] for index in 1:(length(errors) - 1)
    )

    legacy_solution = integrate_plant(legacy, initial, stop_time, day)
    @test legacy_solution == solutions[1]
    relative_legacy_distance =
        sum(abs.(legacy_solution .- reference)) / sum(abs, reference)
    @test relative_legacy_distance ≈ FT(2.508246047039484e-4) rtol = FT(1e-6)
end

@testset "CASA carbon-only dummy plant nitrogen" begin
    FT = Float64
    ratios = FT.((1 / 50, 1 / 150, 1 / 40))
    parameters = plant_parameters(FT; plant_nitrogen_ratio = ratios)
    drivers = CASA.PrescribedDrivers(
        t -> FT(2e-7),
        t -> FT(283.15),
        t -> FT(278.15),
        t -> FT(0.7),
        t -> FT(2),
        t -> one(FT),
        t -> zero(FT),
    )
    model = CASA.CASAPlantModel{FT}(;
        parameters,
        drivers,
        domain = Point(; z_sfc = zero(FT), context = ClimaComms.context()),
    )
    Y, p, _ = ClimaLand.initialize(model)
    Y.casa_plant.c_leaf .= FT(0.1)
    Y.casa_plant.c_wood .= FT(0.3)
    Y.casa_plant.c_fine_root .= FT(0.2)
    Y.casa_plant.c_labile .= zero(FT)
    update! = ClimaLand.make_set_initial_cache(model)
    update!(p, Y, zero(FT))
    first_maintenance = p.casa_plant.carbon_fluxes[][17]

    Y.casa_plant.c_wood .*= FT(2)
    update!(p, Y, zero(FT))
    @test p.casa_plant.carbon_fluxes[][17] > first_maintenance
end

function packed_flux_allocations(
    parameters,
    carbon,
    gpp,
    air_temperature,
    soil_temperature,
    water_stress,
    phase,
    npp_scalar,
    labile_fraction,
)
    CASA.packed_carbon_fluxes(
        parameters,
        carbon...,
        gpp,
        air_temperature,
        soil_temperature,
        water_stress,
        phase,
        npp_scalar,
        labile_fraction,
    )
    return @allocated CASA.packed_carbon_fluxes(
        parameters,
        carbon...,
        gpp,
        air_temperature,
        soil_temperature,
        water_stress,
        phase,
        npp_scalar,
        labile_fraction,
    )
end

function nitrogen_flux_allocations(arguments...)
    CASA.nitrogen_fluxes(arguments...)
    return @allocated CASA.nitrogen_fluxes(arguments...)
end

for FT in (Float32, Float64)
    @testset "CASA plant kernels, FT = $FT" begin
        parameters = plant_parameters(FT)
        @test isbits(parameters)
        @test CASA.temperature_response(FT(283.15), FT(273.15)) ≈ one(FT)

        base = @inferred CASA.allocation_fractions(
            parameters,
            FT(2),
            FT(1),
            one(FT),
            (zero(FT), FT(2), FT(6)),
        )
        @test all(base .≈ (FT(0.4), FT(0.15), FT(0.45)))
        @test all(
            CASA.allocation_fractions(
                parameters,
                zero(FT),
                FT(1),
                one(FT),
                (zero(FT), FT(2), FT(6)),
            ) .≈ (zero(FT), FT(0.25), FT(0.75)),
        )
        @test all(
            CASA.allocation_fractions(
                parameters,
                one(FT),
                FT(1),
                one(FT),
                (zero(FT), FT(2), FT(6)),
            ) .≈ (FT(0.8), FT(0.1), FT(0.1)),
        )
        @test all(
            CASA.allocation_fractions(
                parameters,
                FT(3),
                FT(1),
                one(FT),
                (zero(FT), FT(2), FT(6)),
            ) .≈ (zero(FT), FT(0.15), FT(0.85)),
        )
        @test all(
            CASA.allocation_fractions(
                parameters,
                FT(2),
                parameters.maximum_leaf_area_index,
                one(FT),
                (zero(FT), FT(2), FT(6)),
            ) .≈ (zero(FT), FT(0.25), FT(0.75)),
        )
        @test all(
            CASA.allocation_fractions(
                parameters,
                FT(2),
                FT(1),
                -one(FT),
                (zero(FT), FT(2), FT(6)),
            ) .≈ (zero(FT), FT(0.25), FT(0.75)),
        )

        rates = @inferred CASA.senescence_rates(
            parameters,
            FT(2),
            FT(1),
            FT(283.15),
            one(FT),
        )
        @test rates == parameters.turnover_rates
        flushing_rates = CASA.senescence_rates(
            parameters,
            one(FT),
            FT(1),
            FT(283.15),
            one(FT),
        )
        @test flushing_rates[1] == zero(FT)
        @test CASA.senescence_rates(
            parameters,
            FT(2),
            parameters.minimum_leaf_area_index,
            FT(270),
            zero(FT),
        )[1] == zero(FT)

        carbon = (FT(0.09), FT(0.37), FT(0.14), FT(0.01))
        args = (
            parameters,
            carbon,
            FT(2e-7),
            FT(283.15),
            FT(278.15),
            FT(0.7),
            FT(2),
            one(FT),
            zero(FT),
        )
        fluxes = @inferred CASA.carbon_fluxes(args...)
        packed_fluxes = @inferred CASA.packed_carbon_fluxes(
            CASA.ContinuousRate(),
            parameters,
            carbon...,
            args[3:end]...,
        )
        @test packed_fluxes ==
              CASA.packed_carbon_fluxes(parameters, carbon..., args[3:end]...)
        @test packed_flux_allocations(args...) == 0
        @test @allocated(
            CASA.packed_carbon_fluxes(
                CASA.ContinuousRate(),
                parameters,
                carbon...,
                args[3:end]...,
            )
        ) == 0
        @test sum(fluxes.allocation) ≈ one(FT) atol = 4eps(FT)
        @test sum(fluxes.tendencies[1:3]) ≈ fluxes.npp - sum(fluxes.turnover) atol =
            8eps(FT)
        @test fluxes.tendencies[4] == -fluxes.labile_loss
        @test fluxes.autotrophic_respiration ==
              fluxes.maintenance_respiration + fluxes.growth_respiration

        nitrogen_parameters = CASA.CASAPlantNitrogenParameters{FT}(;
            nitrogen_ratio_minimum = (
                FT(0.02),
                FT(0.006666667),
                FT(0.024390244),
            ),
            nitrogen_ratio_maximum = (FT(0.03), FT(0.008), FT(0.029268293)),
            nitrogen_fraction_to_litter = (FT(0.5), FT(0.95), FT(0.9)),
            lignin_fraction = (FT(0.2), FT(0.4), FT(0.2)),
            structural_litter_nitrogen_ratio = inv(FT(150)),
            limitation_minimum = FT(0.5e-3),
            limitation_maximum = FT(2e-3),
            mineral_half_saturation = FT(2e-3),
        )
        plant_nitrogen = (FT(0.002), FT(0.003), FT(0.004))
        plant_rates = fluxes.rates
        limitation = FT(1 / 3)
        nitrogen = @inferred CASA.nitrogen_fluxes(
            nitrogen_parameters,
            carbon[1:3],
            plant_nitrogen,
            fluxes.npp,
            fluxes.allocation,
            plant_rates,
            FT(1e-3),
            limitation,
            limitation,
        )
        @test nitrogen_flux_allocations(
            nitrogen_parameters,
            carbon[1:3],
            plant_nitrogen,
            fluxes.npp,
            fluxes.allocation,
            plant_rates,
            FT(1e-3),
            limitation,
            limitation,
        ) == 0
        @test sum(nitrogen.tendencies) + sum(nitrogen.litter) ≈ nitrogen.uptake atol =
            16eps(FT)
    end
end

@testset "CASA productive-cell plant nitrogen transitions" begin
    fixture_dir = normpath(
        joinpath(
            @__DIR__,
            "../../testbed_validation/fixtures/casa_cn_cell_11060",
        ),
    )
    output_path = joinpath(fixture_dir, "casa_1901_1905_cell_11060.nc")
    parameters = CASA.CASAPlantNitrogenParameters{Float64}(;
        nitrogen_ratio_minimum = (0.02, 0.006666667, 0.024390244),
        nitrogen_ratio_maximum = (0.03, 0.008, 0.029268293),
        nitrogen_fraction_to_litter = (0.5, 0.95, 0.9),
        lignin_fraction = (0.2, 0.4, 0.2),
        structural_litter_nitrogen_ratio = 1 / 150,
        limitation_minimum = 0.5,
        limitation_maximum = 2.0,
        mineral_half_saturation = 2.0,
    )
    carbon_names = ("cleaf", "cwood", "cfroot")
    nitrogen_names = ("nleaf", "nwood", "nfroot")
    base_rates = (NaN, 1 / (40 * 365), 1 / (5 * 365))

    NCDataset(output_path) do output
        value(name, day) = Float64(output[name][1, 1, day])
        tested_transitions = 0
        for day in 2:365
            npp = value("cnpp", day)
            npp > 1e-8 || continue
            carbon = ntuple(index -> value(carbon_names[index], day - 1), 3)
            next_carbon = ntuple(index -> value(carbon_names[index], day), 3)
            nitrogen = ntuple(index -> value(nitrogen_names[index], day - 1), 3)
            next_nitrogen =
                ntuple(index -> value(nitrogen_names[index], day), 3)
            wood_allocation =
                (next_carbon[2] - carbon[2] + base_rates[2] * carbon[2]) / npp
            root_allocation =
                (next_carbon[3] - carbon[3] + base_rates[3] * carbon[3]) / npp
            allocation = (
                1 - wood_allocation - root_allocation,
                wood_allocation,
                root_allocation,
            )
            leaf_rate =
                (npp * allocation[1] - (next_carbon[1] - carbon[1])) / carbon[1]
            rates = (leaf_rate, base_rates[2], base_rates[3])
            mineral_nitrogen = value("nMineral", day - 1)
            demand_fraction = clamp(
                (mineral_nitrogen - parameters.limitation_minimum) / (
                    parameters.limitation_maximum -
                    parameters.limitation_minimum
                ),
                0.0,
                1.0,
            )
            litter_carbon = sum(
                value(name, day - 1) for
                name in ("clitmetb", "clitstr", "clitcwd")
            )
            limitation = ifelse(litter_carbon > 157 + 107, 1.0, demand_fraction)
            fluxes = CASA.nitrogen_fluxes(
                parameters,
                carbon,
                nitrogen,
                npp,
                allocation,
                rates,
                mineral_nitrogen,
                demand_fraction,
                limitation,
            )
            predicted = nitrogen .+ fluxes.tendencies
            @test all(isapprox.(predicted, next_nitrogen; rtol = 5e-4))
            @test fluxes.uptake ≈ value("nMinUptake", day) rtol = 5e-4 atol =
                3e-6
            @test fluxes.litter[1] ≈ value("nLitInptMet", day) rtol = 5e-4 atol =
                3e-6
            tested_transitions += 1
        end
        @test tested_transitions > 280
    end
end

@testset "CASA standalone plant carbon-nitrogen model" begin
    for FT in (Float32, Float64)
        parameters = plant_parameters(FT)
        nitrogen_parameters = CASA.CASAPlantNitrogenParameters{FT}(;
            nitrogen_ratio_minimum = (
                FT(0.02),
                FT(0.006666667),
                FT(0.024390244),
            ),
            nitrogen_ratio_maximum = (FT(0.03), FT(0.008), FT(0.029268293)),
            nitrogen_fraction_to_litter = (FT(0.5), FT(0.95), FT(0.9)),
            lignin_fraction = (FT(0.2), FT(0.4), FT(0.2)),
            structural_litter_nitrogen_ratio = inv(FT(150)),
            limitation_minimum = FT(0.5e-3),
            limitation_maximum = FT(2e-3),
            mineral_half_saturation = FT(2e-3),
        )
        drivers = CASA.PrescribedDrivers(
            t -> FT(2e-7),
            t -> FT(283.15),
            t -> FT(278.15),
            t -> FT(0.7),
            t -> FT(2),
            t -> one(FT),
            t -> zero(FT),
        )
        nitrogen_drivers = CASA.NitrogenPrescribedDrivers(
            t -> FT(1e-3),
            t -> FT(1 / 3),
            t -> FT(1 / 3),
        )
        domain = Point(; z_sfc = zero(FT), context = ClimaComms.context())
        model = CASA.CASAPlantModel{FT}(;
            configuration = CASA.CarbonNitrogen(),
            parameters,
            nitrogen_parameters,
            drivers,
            nitrogen_drivers,
            domain,
        )
        @test length(ClimaLand.prognostic_vars(model)) == 7
        Y, p, _ = ClimaLand.initialize(model)
        initial = (
            FT(0.09),
            FT(0.37),
            FT(0.14),
            FT(0.01),
            FT(0.002),
            FT(0.003),
            FT(0.004),
        )
        for (name, value) in zip(ClimaLand.prognostic_vars(model), initial)
            getproperty(Y.casa_plant, name) .= value
        end
        ClimaLand.make_set_initial_cache(model)(p, Y, zero(FT))
        FT == Float32 && test_model_diagnostics(model, Y, p, zero(FT))
        dY = similar(Y)
        tendency! = ClimaLand.make_exp_tendency(model)
        tendency!(dY, Y, p, zero(FT))
        point_tendencies = map(ClimaLand.prognostic_vars(model)) do name
            getproperty(dY.casa_plant, name)[]
        end
        fluxes = p.casa_plant.nitrogen_fluxes[]
        plant_tendency = sum(
            Array(parent(getproperty(dY.casa_plant, name)))[1] for
            name in (:n_leaf, :n_wood, :n_fine_root)
        )
        @test plant_tendency + sum(fluxes[4:6]) ≈ fluxes[7] atol =
            32eps(FT) * max(fluxes[7], eps(FT))

        day = FT(86400)
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
        @test all(
            isfinite(
                Array(parent(getproperty(integrator.u.casa_plant, name)))[1],
            ) for name in ClimaLand.prognostic_vars(model)
        )
        if FT == Float32
            test_checkpoint_roundtrip(model, integrator.u, Float64(day))
            plane = Plane(;
                xlim = FT.((0, 2)),
                ylim = FT.((0, 2)),
                nelements = (2, 2),
                context = ClimaComms.context(),
            )
            grid_model = CASA.CASAPlantModel{FT}(;
                configuration = CASA.CarbonNitrogen(),
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
        end
    end
end

@testset "CASA standalone plant model" begin
    for FT in (Float32, Float64)
        parameters = plant_parameters(FT)
        drivers = CASA.PrescribedDrivers(
            t -> FT(2e-7),
            t -> FT(283.15),
            t -> FT(278.15),
            t -> FT(0.7),
            t -> FT(2),
            t -> one(FT),
            t -> zero(FT),
        )
        domain = Point(; z_sfc = zero(FT), context = ClimaComms.context())
        model = CASA.CASAPlantModel{FT}(; parameters, drivers, domain)
        @test model isa ClimaLand.AbstractExpModel{FT}
        @test ClimaComms.context(model) == ClimaComms.context()
        @test ClimaLand.name(model) == :casa_plant
        Y, p, _ = ClimaLand.initialize(model)
        initial = (FT(0.09), FT(0.37), FT(0.14), FT(0.01))
        for (name, value) in zip(ClimaLand.prognostic_vars(model), initial)
            getproperty(Y.casa_plant, name) .= value
        end

        exp_tendency! = ClimaLand.make_exp_tendency(model)
        set_initial_cache! = ClimaLand.make_set_initial_cache(model)
        set_initial_cache!(p, Y, zero(FT))
        FT == Float32 && test_model_diagnostics(model, Y, p, zero(FT))
        dY = similar(Y)
        exp_tendency!(dY, Y, p, zero(FT))
        packed_fluxes = p.casa_plant.carbon_fluxes[]
        tendencies = map(ClimaLand.prognostic_vars(model)) do name
            Array(parent(getproperty(dY.casa_plant, name)))[1]
        end
        @test tendencies == Tuple(packed_fluxes[1:4])

        day = FT(86400)
        expected = initial .+ day .* tendencies
        problem = CTS.ODEProblem(
            CTS.ClimaODEFunction((T_exp!) = exp_tendency!),
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
            Array(parent(getproperty(integrator.u.casa_plant, name)))[1]
        end
        @test all(isapprox.(actual, expected; rtol = 16eps(FT)))
        if FT == Float32
            test_checkpoint_roundtrip(model, integrator.u, Float64(day))
            continuous_model = CASA.CASAPlantModel{FT}(;
                parameters,
                drivers,
                domain,
                temporal_mode = CASA.ContinuousRate(),
            )
            test_checkpoint_roundtrip(
                continuous_model,
                integrator.u,
                Float64(day),
            )
            plane = Plane(;
                xlim = FT.((0, 2)),
                ylim = FT.((0, 2)),
                nelements = (2, 2),
                context = ClimaComms.context(),
            )
            grid_model =
                CASA.CASAPlantModel{FT}(; parameters, drivers, domain = plane)
            test_gridded_tendency(
                grid_model,
                initial,
                tendencies,
                zero(FT),
                16eps(FT),
            )

            spatial_variant = plant_parameters(FT; nonwoody = true)
            x = ClimaCore.Fields.coordinate_field(plane.space.surface).x
            spatial_parameters =
                @. ifelse(x < FT(1), parameters, spatial_variant)
            @test axes(spatial_parameters) == plane.space.surface
            @test eltype(spatial_parameters) == typeof(parameters)
            @test !ClimaLand.has_root_exudation(spatial_parameters)
            exudating = plant_parameters(FT; root_exudate_fraction = FT(0.02))
            exudating_parameters = @. ifelse(x < FT(1), parameters, exudating)
            @test ClimaLand.has_root_exudation(exudating_parameters)

            spatial_model = CASA.CASAPlantModel{FT}(;
                parameters = spatial_parameters,
                drivers,
                domain = plane,
                temporal_mode = CASA.ContinuousRate(),
            )
            spatial_Y, spatial_p, _ = ClimaLand.initialize(spatial_model)
            for (name, value) in
                zip(ClimaLand.prognostic_vars(spatial_model), initial)
                getproperty(spatial_Y.casa_plant, name) .= value
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

            right_fluxes = CASA.packed_carbon_fluxes(
                spatial_variant,
                initial...,
                FT(2e-7),
                FT(283.15),
                FT(278.15),
                FT(0.7),
                FT(2),
                one(FT),
                zero(FT),
            )
            x_values = Array(parent(x))
            left = x_values .< FT(1)
            right = .!left
            spatial_tendency = Array(parent(spatial_dY.casa_plant.c_wood))
            @test all(spatial_tendency[left] .≈ tendencies[2])
            @test all(spatial_tendency[right] .≈ right_fluxes[2])
        end
    end
end
