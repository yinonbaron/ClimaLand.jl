using Test

import ClimaComms
ClimaComms.@import_required_backends
import ClimaCore
import NCDatasets
import StaticArrays
import TOML

using ClimaLand

include(joinpath(@__DIR__, "..", "testbed_validation", "native_workflow.jl"))

const PlantCASA = ClimaLand.Vegetation.CASA
const Soil = ClimaLand.Soil
const SoilCASA = ClimaLand.Soil.Biogeochemistry.CASA
const MIMICS = ClimaLand.Soil.Biogeochemistry.MIMICS
const CORPSE = ClimaLand.Soil.Biogeochemistry.CORPSE

const NativeWorkflow = TestbedNativeWorkflow

function coupling_cache(::Type{FT}) where {FT}
    plant_fluxes = StaticArrays.SVector{21}(
        ntuple(21) do index
            index in (8, 9, 10, 20) ? FT(index) : zero(FT)
        end,
    )
    field() = zeros(FT, 1)
    return (;
        casa_plant = (; carbon_fluxes = fill(plant_fluxes, 1)),
        leaf_labile_input = field(),
        leaf_recalcitrant_input = field(),
        root_labile_input = field(),
        root_recalcitrant_input = field(),
        litter_metabolic_input = field(),
        litter_structural_input = field(),
        litter_cwd_input = field(),
        exudate_labile_input = field(),
    )
end

function nitrogen_coupling_cache(::Type{FT}) where {FT}
    nitrogen_fluxes =
        StaticArrays.SVector{12}(ntuple(index -> FT(index), Val(12)))
    field() = zeros(FT, 1)
    return (;
        casa_plant = (; nitrogen_fluxes = fill(nitrogen_fluxes, 1)),
        nitrogen_litter_metabolic_input = field(),
        nitrogen_litter_structural_input = field(),
        nitrogen_litter_cwd_input = field(),
        nitrogen_plant_uptake = field(),
    )
end

function test_integrated_diagnostics(model, Y, p, time)
    diagnostics = ClimaLand.Diagnostics
    possible = diagnostics.get_possible_diagnostics(model)
    @test !isempty(possible)
    diagnostics.define_diagnostics!(model, possible)
    for short_name in possible
        @testset "$short_name" begin
            diagnostic = diagnostics.get_diagnostic_variable(short_name)
            values = diagnostic.compute!(nothing, Y, p, time)
            @test all(isfinite, vec(Array(parent(values))))
        end
    end
    return nothing
end

function integrated_casa_cn_model(
    ::Type{FT};
    domain = ClimaLand.Domains.Point(;
        z_sfc = zero(FT),
        context = ClimaComms.context(),
    ),
) where {FT}
    day = FT(86400)
    year = FT(365) * day
    plant_parameters = PlantCASA.CASAPlantModelParameters{FT}(;
        allocation = (FT(0.4), FT(0.15), FT(0.45)),
        turnover_rates = (inv(year), inv(FT(40) * year), inv(FT(5) * year)),
        maintenance_rates = (FT(0.1) / year, FT(6) / year, FT(6) / year),
        plant_nitrogen = (FT(2.2e-3), FT(2.5e-3), FT(19e-3)),
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
    )
    plant_nitrogen_parameters = PlantCASA.CASAPlantNitrogenParameters{FT}(;
        nitrogen_ratio_minimum = (FT(0.02), FT(0.006666667), FT(0.024390244)),
        nitrogen_ratio_maximum = (FT(0.03), FT(0.008), FT(0.029268293)),
        nitrogen_fraction_to_litter = (FT(0.5), FT(0.95), FT(0.9)),
        lignin_fraction = (FT(0.2), FT(0.4), FT(0.2)),
        structural_litter_nitrogen_ratio = inv(FT(150)),
        limitation_minimum = FT(0.5e-3),
        limitation_maximum = FT(2e-3),
        mineral_half_saturation = FT(2e-3),
    )
    plant_drivers = PlantCASA.PrescribedDrivers(
        t -> FT(2e-7),
        t -> FT(283.15),
        t -> FT(278.15),
        t -> FT(0.7),
        t -> FT(2),
        t -> one(FT),
        t -> zero(FT),
    )
    plant_nitrogen_drivers = PlantCASA.NitrogenPrescribedDrivers(
        t -> FT(1e-3),
        t -> FT(1 / 3),
        t -> FT(1 / 3),
    )
    plant = PlantCASA.CASAPlantModel{FT}(;
        configuration = PlantCASA.CarbonNitrogen(),
        parameters = plant_parameters,
        nitrogen_parameters = plant_nitrogen_parameters,
        drivers = plant_drivers,
        nitrogen_drivers = plant_nitrogen_drivers,
        domain,
    )

    transfers = SoilCASA.CarbonTransferParameters{FT}(;
        lignin_leaf = FT(0.2),
        lignin_wood = FT(0.4),
        cue_metabolic_to_microbial = FT(0.45),
        cue_structural_to_microbial = FT(0.45),
        cue_structural_to_slow = FT(0.7),
        cue_cwd_to_microbial = FT(0.4),
        cue_cwd_to_slow = FT(0.7),
        cue_microbial_to_slow = one(FT),
        cue_microbial_to_passive = one(FT),
        cue_slow_to_passive = FT(0.45),
    )
    soil_parameters = SoilCASA.CASASoilModelParameters{FT, typeof(transfers)}(;
        q10 = FT(1.72),
        litter_optimum = FT(0.4),
        soil_optimum = FT(0.1034),
        porosity = FT(0.41312),
        clay = FT(0.21805),
        silt = FT(0.13224),
        freezing_temperature = FT(273.15),
        litter_base_rates = (
            inv(FT(365 * 0.04) * day),
            inv(FT(365 * 0.23) * day),
            inv(FT(365 * 0.824) * day),
        ),
        soil_base_rates = (
            inv(FT(365 * 0.137) * day),
            inv(FT(365 * 5) * day),
            inv(FT(365 * 222.22) * day),
        ),
        transfers,
    )
    soil_nitrogen_parameters = SoilCASA.CASANitrogenParameters{FT}(;
        limitation_minimum = FT(0.5e-3),
        limitation_maximum = FT(2e-3),
        maximum_fine_litter = FT(0.157),
        maximum_cwd = FT(0.107),
        soil_nitrogen_ratio_minimum = (inv(FT(8)), inv(FT(20)), inv(FT(20))),
        soil_nitrogen_ratio_maximum = (
            inv(FT(6.17)),
            inv(FT(16.63)),
            inv(FT(16.63)),
        ),
        loss_threshold = FT(2e-3),
        loss_fraction = FT(0.05),
        leach_rate = FT(10 * 0.05 / 365) / day,
    )
    deposition = FT(4e-10)
    fixation = FT(5e-10)
    soil_drivers = SoilCASA.PrescribedDrivers(
        t -> FT(278.15),
        t -> FT(0.2),
        t -> zero(FT),
        t -> zero(FT),
        t -> zero(FT),
    )
    soil_nitrogen_drivers = SoilCASA.NitrogenPrescribedDrivers(
        t -> zero(FT),
        t -> zero(FT),
        t -> zero(FT),
        t -> deposition,
        t -> fixation,
        t -> zero(FT),
    )
    soil = SoilCASA.CASASoilModel{FT}(;
        configuration = SoilCASA.CarbonNitrogen(),
        parameters = soil_parameters,
        nitrogen_parameters = soil_nitrogen_parameters,
        drivers = soil_drivers,
        nitrogen_drivers = soil_nitrogen_drivers,
        domain,
    )
    coupling = LitterCouplingParameters{FT}(;
        leaf_metabolic_fraction = FT(0.4),
        root_metabolic_fraction = FT(0.3),
    )
    model = CASAPlantSoilModel{FT}(plant, soil, coupling)
    return (; model, deposition, fixation)
end

function integrated_mimics_cn_model(::Type{FT}; domain = nothing) where {FT}
    casa_setup =
        isnothing(domain) ? integrated_casa_cn_model(FT) :
        integrated_casa_cn_model(FT; domain)
    plant = casa_setup.model.casa_plant
    domain = plant.domain
    carbon = MIMICS.CarbonParameters{FT}(;
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
    parameter_type = MIMICS.MIMICSSoilModelParameters{FT, typeof(carbon)}
    parameters = parameter_type(;
        carbon,
        clay = FT(0.21805),
        freezing_temperature = FT(273.15),
        cwd_q10 = FT(1.72),
        cwd_litter_optimum = FT(0.4),
        cwd_base_rate = inv(FT(365 * 0.824 * 86400)),
        cwd_respiration_fraction = FT(0.48),
    )
    nitrogen_parameters = MIMICS.NitrogenParameters{FT}(;
        nitrogen_use_efficiency = FT.((0.85, 0.85, 0.85, 0.85)),
        microbial_carbon_nitrogen_ratio = FT.((6, 10)),
        carbon_nitrogen_modifier = FT(0.4),
        mineral_nitrogen_available_fraction = FT(0.5),
        microbial_turnover_density_exponent = one(FT),
    )
    drivers = MIMICS.PrescribedDrivers(
        t -> FT(278.15),
        t -> FT(0.3),
        t -> FT(0.1),
        t -> zero(FT),
        t -> zero(FT),
        t -> zero(FT),
        t -> FT(0.5),
        t -> FT(0.3),
    )
    deposition = FT(4e-11)
    fixation = FT(5e-11)
    nitrogen_drivers = MIMICS.NitrogenPrescribedDrivers(
        t -> zero(FT),
        t -> zero(FT),
        t -> zero(FT),
        t -> deposition,
        t -> fixation,
        t -> zero(FT),
    )
    soil = MIMICS.MIMICSSoilModel{FT}(;
        configuration = MIMICS.CarbonNitrogen(),
        parameters,
        nitrogen_parameters,
        drivers,
        nitrogen_drivers,
        domain,
    )
    coupling = LitterCouplingParameters{FT}(;
        leaf_metabolic_fraction = FT(0.4),
        root_metabolic_fraction = FT(0.3),
    )
    model = CASAPlantSoilModel{FT}(plant, soil, coupling)
    return (; model, deposition, fixation)
end

function integrated_corpse_model(
    ::Type{FT};
    domain,
    temporal_mode = CORPSE.LegacyDaily(),
) where {FT}
    casa = integrated_casa_cn_model(FT; domain).model
    plant = PlantCASA.CASAPlantModel{FT}(;
        parameters = casa.casa_plant.parameters,
        drivers = casa.casa_plant.drivers,
        domain,
    )
    carbon = CORPSE.CarbonParameters{FT}(;
        vmax_reference = FT.((1000, 25, 400)),
        activation_energy = FT.((5000, 30000, 3000)),
        michaelis_constant = FT.((0.01, 0.01, 0.01)),
        minimum_microbe_fraction = FT(0.001),
        microbe_turnover_time = FT(0.25),
        uptake_efficiency = FT.((0.6, 0.05, 0.6)),
        protection_rate = FT(1.5),
        protection_species = FT.((0.11, 0.002, 1)),
        protected_turnover_time = FT(75),
        protected_decomposition_factor = zero(FT),
        turnover_efficiency = FT(0.6),
        enzyme_fraction = one(FT),
        turnover_factor = FT.((1, 1, 1)),
        gas_diffusion_exponent = FT(2.5),
        minimum_anaerobic_factor = FT(0.003),
        minimum_moisture_factor = FT(0.001),
        litter_density = FT(22),
    )
    parameter_type = CORPSE.CORPSESoilModelParameters{FT, typeof(carbon)}
    parameters = parameter_type(;
        carbon,
        mineral_protection_capacity = FT(0.05),
        layer_thickness = FT(0.15),
        rhizosphere_fraction = FT(0.3),
        litter_option = 1,
        freezing_temperature = FT(273.15),
        cwd_q10 = FT(1.72),
        cwd_litter_optimum = FT(0.4),
        cwd_base_rate = inv(FT(365 * 0.824 * 86400)),
        cwd_respiration_fraction = FT(0.48),
    )
    drivers = CORPSE.PrescribedDrivers(
        t -> FT(278.15),
        t -> FT(0.3),
        t -> FT(0.1),
        t -> zero(FT),
        t -> zero(FT),
        t -> zero(FT),
        t -> zero(FT),
        t -> zero(FT),
        t -> zero(FT),
    )
    soil =
        CORPSE.CORPSESoilModel{FT}(; parameters, drivers, domain, temporal_mode)
    coupling = LitterCouplingParameters{FT}(;
        leaf_metabolic_fraction = FT(0.4),
        root_metabolic_fraction = FT(0.3),
    )
    return CASAPlantSoilModel{FT}(plant, soil, coupling)
end

function initialize_native_soil_state!(Y, model, ::Type{FT}) where {FT}
    liquid = FT(0.2)
    ice = FT(0.05)
    temperature = FT(280)
    Y.soil.ϑ_l .= liquid
    Y.soil.θ_i .= ice
    heat_capacity = @. Soil.volumetric_heat_capacity(
        liquid,
        ice,
        model.soil.parameters.ρc_ds,
        model.soil.parameters.earth_param_set,
    )
    Y.soil.ρe_int .=
        Soil.volumetric_internal_energy.(
            ice,
            heat_capacity,
            temperature,
            model.soil.parameters.earth_param_set,
        )
    Y.casa_plant.c_leaf .= FT(0.09)
    Y.casa_plant.c_wood .= FT(0.37)
    Y.casa_plant.c_fine_root .= FT(0.14)
    Y.casa_plant.c_labile .= FT(0.01)
    if hasproperty(Y.casa_plant, :n_leaf)
        Y.casa_plant.n_leaf .= FT(0.002)
        Y.casa_plant.n_wood .= FT(0.003)
        Y.casa_plant.n_fine_root .= FT(0.004)
    end
    return (; liquid, ice, temperature)
end

function integrated_vertical_checkpoint_domain(
    ::Type{FT},
    domain_choice,
) where {FT}
    if domain_choice == :column
        return ClimaLand.Domains.Column(;
            zlim = FT.((-1, 0)),
            nelements = 4,
            longlat = FT.((-118, 45)),
        )
    end
    return ClimaLand.Domains.HybridBox(;
        xlim = FT.((-1000, 1000)),
        ylim = FT.((-1000, 1000)),
        zlim = FT.((-1, 0)),
        nelements = (1, 1, 4),
        npolynomial = 1,
        longlat = FT.((-118, 45)),
    )
end

function integrated_vertical_checkpoint_model(
    ::Type{FT},
    soil_choice,
    domain_choice,
) where {FT}
    domain = integrated_vertical_checkpoint_domain(FT, domain_choice)
    toml_dict = ClimaLand.Parameters.create_toml_dict(FT)
    atmos, radiation = prescribed_analytic_forcing(FT; toml_dict)
    hydrology =
        Soil.EnergyHydrology{FT}(domain, (; atmos, radiation), toml_dict)
    biogeochemistry = if soil_choice == :casa
        integrated_casa_cn_model(FT; domain).model
    elseif soil_choice == :mimics
        integrated_mimics_cn_model(FT; domain).model
    else
        integrated_corpse_model(FT; domain)
    end
    return CASAPlantEnergyHydrologyModel{FT}(
        hydrology,
        biogeochemistry;
        rooting_depth = FT(0.5),
    )
end

@testset "Integrated vertical BGC checkpoint round trips" begin
    FT = Float32
    for (domain_choice, soil_choice) in (
        (:column, :casa),
        (:column, :mimics),
        (:column, :corpse),
        (:hybrid_box, :casa),
    )
        @testset "$domain_choice $soil_choice" begin
            model = integrated_vertical_checkpoint_model(
                FT,
                soil_choice,
                domain_choice,
            )
            Y, _, _ = ClimaLand.initialize(model)
            for (component_index, component_name) in
                enumerate(ClimaLand.land_components(model))
                component = getproperty(model, component_name)
                state = getproperty(Y, component_name)
                for (variable_index, variable) in
                    enumerate(ClimaLand.prognostic_vars(component))
                    getproperty(state, variable) .=
                        FT(component_index + variable_index / 100)
                end
            end

            restored_model = integrated_vertical_checkpoint_model(
                FT,
                soil_choice,
                domain_choice,
            )
            Y_restored, _, _ = ClimaLand.initialize(restored_model)
            time = FT(12345.5)
            mktempdir() do output_dir
                ClimaLand.save_checkpoint(Y, time, output_dir; model)
                checkpoint_file = only(
                    filter(
                        path -> endswith(path, ".hdf5"),
                        readdir(output_dir; join = true),
                    ),
                )
                ClimaLand.set_initial_conditions_from_checkpoint!(
                    Y_restored,
                    checkpoint_file;
                    model,
                )
                @test ClimaLand.initial_time_from_checkpoint(
                    checkpoint_file;
                    model,
                ) == time
                Y_loaded, loaded_time =
                    ClimaLand.read_checkpoint(checkpoint_file; model)
                @test loaded_time == time
                for component_name in ClimaLand.land_components(model)
                    state = getproperty(Y, component_name)
                    loaded_state = getproperty(Y_loaded, component_name)
                    @test propertynames(loaded_state) == propertynames(state)
                    for variable in propertynames(state)
                        @test Array(
                            parent(getproperty(loaded_state, variable)),
                        ) == Array(parent(getproperty(state, variable)))
                    end
                end
            end

            @test propertynames(Y_restored) == propertynames(Y)
            for component_name in ClimaLand.land_components(model)
                state = getproperty(Y, component_name)
                restored_state = getproperty(Y_restored, component_name)
                @test propertynames(restored_state) == propertynames(state)
                for variable in propertynames(state)
                    @test Array(
                        parent(getproperty(restored_state, variable)),
                    ) == Array(parent(getproperty(state, variable)))
                end
            end
        end
    end
end

for FT in (Float32, Float64)
    @testset "Native EnergyHydrology BGC drivers, FT = $FT" begin
        domain = ClimaLand.Domains.Column(;
            zlim = FT.((-1, 0)),
            nelements = 4,
            longlat = FT.((-118, 45)),
        )
        toml_dict = ClimaLand.Parameters.create_toml_dict(FT)
        atmos, radiation = prescribed_analytic_forcing(FT; toml_dict)
        hydrology =
            Soil.EnergyHydrology{FT}(domain, (; atmos, radiation), toml_dict)

        casa = integrated_casa_cn_model(FT; domain).model
        casa_model = CASAPlantEnergyHydrologyModel{FT}(
            hydrology,
            casa;
            rooting_depth = FT(0.5),
        )
        @test ClimaLand.land_components(casa_model) ==
              (:soil, :casa_plant, :casa_soil)
        @test :root_weighted_soil_temperature in
              ClimaLand.lsm_aux_vars(casa_model)
        casa_Y, casa_p, _ = ClimaLand.initialize(casa_model)
        expected = initialize_native_soil_state!(casa_Y, casa_model, FT)
        for name in ClimaLand.prognostic_vars(casa_model.casa_soil)
            getproperty(casa_Y.casa_soil, name) .= FT(0.01)
        end
        ClimaLand.make_set_initial_cache(casa_model)(casa_p, casa_Y, zero(FT))
        liquid_saturation = casa_p.root_weighted_liquid_saturation[]
        frozen_saturation = casa_p.root_weighted_frozen_saturation[]
        @test casa_p.root_weighted_soil_temperature[] ≈ expected.temperature
        @test casa_p.root_weighted_liquid_water[] ≈ expected.liquid
        @test zero(FT) < liquid_saturation < one(FT)
        @test zero(FT) < frozen_saturation < one(FT) - liquid_saturation
        @test casa_p.casa_plant.soil_temperature[] ≈ expected.temperature
        @test casa_p.casa_plant.water_stress[] ≈ liquid_saturation
        @test casa_p.casa_soil.soil_temperature[] ≈ expected.temperature
        @test casa_p.casa_soil.relative_saturation[] ≈
              expected.liquid / casa_model.casa_soil.parameters.porosity
        casa_dY = similar(casa_Y)
        ClimaLand.make_exp_tendency(casa_model)(
            casa_dY,
            casa_Y,
            casa_p,
            zero(FT),
        )
        @test all(isfinite, parent(casa_dY.casa_plant.c_leaf))
        @test all(isfinite, parent(casa_dY.casa_soil.c_soil_microbial))

        mimics = integrated_mimics_cn_model(FT; domain).model
        mimics_model = CASAPlantEnergyHydrologyModel{FT}(
            hydrology,
            mimics;
            rooting_depth = FT(0.5),
        )
        mimics_Y, mimics_p, _ = ClimaLand.initialize(mimics_model)
        initialize_native_soil_state!(mimics_Y, mimics_model, FT)
        for name in ClimaLand.prognostic_vars(mimics_model.mimics_soil)
            getproperty(mimics_Y.mimics_soil, name) .= FT(0.01)
        end
        ClimaLand.make_set_initial_cache(mimics_model)(
            mimics_p,
            mimics_Y,
            zero(FT),
        )
        @test mimics_p.mimics_soil.soil_temperature[] ≈ expected.temperature
        @test mimics_p.mimics_soil.liquid_saturation[] ≈ liquid_saturation
        @test mimics_p.mimics_soil.frozen_saturation[] ≈ frozen_saturation
        mimics_dY = similar(mimics_Y)
        ClimaLand.make_exp_tendency(mimics_model)(
            mimics_dY,
            mimics_Y,
            mimics_p,
            zero(FT),
        )
        @test all(isfinite, parent(mimics_dY.casa_plant.c_leaf))
        @test all(isfinite, parent(mimics_dY.mimics_soil.c_microbe_r))

        corpse = integrated_corpse_model(FT; domain)
        corpse_model = CASAPlantEnergyHydrologyModel{FT}(
            hydrology,
            corpse;
            rooting_depth = FT(0.5),
        )
        @test ClimaLand.land_components(corpse_model) ==
              (:soil, :casa_plant, :corpse_soil)
        corpse_Y, corpse_p, _ = ClimaLand.initialize(corpse_model)
        initialize_native_soil_state!(corpse_Y, corpse_model, FT)
        for name in ClimaLand.prognostic_vars(corpse_model.corpse_soil)
            getproperty(corpse_Y.corpse_soil, name) .= FT(0.01)
        end
        ClimaLand.make_set_initial_cache(corpse_model)(
            corpse_p,
            corpse_Y,
            zero(FT),
        )
        @test corpse_p.corpse_soil.soil_temperature[] ≈ expected.temperature
        @test corpse_p.corpse_soil.liquid_saturation[] ≈ liquid_saturation
        @test corpse_p.corpse_soil.frozen_saturation[] ≈ frozen_saturation

        continuous_corpse = integrated_corpse_model(
            FT;
            domain,
            temporal_mode = CORPSE.ContinuousRate(),
        )
        continuous_corpse_model = CASAPlantEnergyHydrologyModel{FT}(
            hydrology,
            continuous_corpse;
            rooting_depth = FT(0.5),
        )
        @test continuous_corpse_model.corpse_soil.temporal_mode isa
              CORPSE.ContinuousRate
        continuous_corpse_Y, continuous_corpse_p, _ =
            ClimaLand.initialize(continuous_corpse_model)
        initialize_native_soil_state!(
            continuous_corpse_Y,
            continuous_corpse_model,
            FT,
        )
        for name in
            ClimaLand.prognostic_vars(continuous_corpse_model.corpse_soil)
            getproperty(continuous_corpse_Y.corpse_soil, name) .= FT(0.01)
        end
        ClimaLand.make_set_initial_cache(continuous_corpse_model)(
            continuous_corpse_p,
            continuous_corpse_Y,
            zero(FT),
        )
        continuous_corpse_dY = similar(continuous_corpse_Y)
        ClimaLand.make_exp_tendency(continuous_corpse_model)(
            continuous_corpse_dY,
            continuous_corpse_Y,
            continuous_corpse_p,
            zero(FT),
        )
        @test all(
            isfinite,
            parent(continuous_corpse_dY.corpse_soil.soil_rhiz_live_microbe),
        )
    end
end

@testset "Spatial native EnergyHydrology BGC coupling" begin
    FT = Float32
    domain = ClimaLand.Domains.HybridBox(;
        xlim = FT.((-1000, 1000)),
        ylim = FT.((-1000, 1000)),
        zlim = FT.((-1, 0)),
        nelements = (2, 1, 10),
        npolynomial = 1,
        longlat = FT.((-118, 45)),
    )
    toml_dict = ClimaLand.Parameters.create_toml_dict(FT)
    atmos, radiation = prescribed_analytic_forcing(FT; toml_dict)
    hydrology =
        Soil.EnergyHydrology{FT}(domain, (; atmos, radiation), toml_dict)
    casa = integrated_casa_cn_model(FT; domain).model
    longitude = ClimaCore.Fields.coordinate_field(domain.space.surface).long
    longitude_values = parent(longitude)
    threshold = (minimum(longitude_values) + maximum(longitude_values)) / 2
    shallow = FT(0.25)
    deep = FT(0.75)
    rooting_depth = @. ifelse(longitude < threshold, shallow, deep)
    model = CASAPlantEnergyHydrologyModel{FT}(hydrology, casa; rooting_depth)
    @test axes(model.rooting_depth) == domain.space.surface
    @test extrema(Array(parent(model.rooting_depth))) == (shallow, deep)

    Y, p, _ = ClimaLand.initialize(model)
    initial = initialize_native_soil_state!(Y, model, FT)
    for name in ClimaLand.prognostic_vars(model.casa_soil)
        getproperty(Y.casa_soil, name) .= FT(0.01)
    end
    z = model.soil.domain.fields.z
    temperature = @. FT(280) + FT(5) * z
    heat_capacity = @. Soil.volumetric_heat_capacity(
        initial.liquid,
        initial.ice,
        model.soil.parameters.ρc_ds,
        model.soil.parameters.earth_param_set,
    )
    Y.soil.ρe_int .=
        Soil.volumetric_internal_energy.(
            initial.ice,
            heat_capacity,
            temperature,
            model.soil.parameters.earth_param_set,
        )
    ClimaLand.make_set_initial_cache(model)(p, Y, zero(FT))
    root_temperatures = vec(Array(parent(p.root_weighted_soil_temperature)))
    @test length(root_temperatures) > 1
    @test maximum(root_temperatures) > minimum(root_temperatures)
    test_integrated_diagnostics(model, Y, p, zero(FT))
end

@testset "Spatial CASA litter coupling" begin
    FT = Float32
    domain = ClimaLand.Domains.Plane(;
        xlim = FT.((0, 2)),
        ylim = FT.((0, 2)),
        nelements = (2, 2),
        context = ClimaComms.context(),
    )
    surface_space = domain.space.surface
    x = ClimaCore.Fields.coordinate_field(surface_space).x
    forest = LitterCouplingParameters{FT}(;
        leaf_metabolic_fraction = FT(0.4),
        root_metabolic_fraction = FT(0.3),
    )
    grass = LitterCouplingParameters{FT}(;
        leaf_metabolic_fraction = FT(0.7),
        root_metabolic_fraction = FT(0.6),
    )
    coupling = @. ifelse(x < FT(1), forest, grass)
    @test axes(coupling) == surface_space
    @test isnothing(ClimaLand.validate_litter_coupling(coupling, domain, FT))

    plant_fluxes = StaticArrays.SVector{21}(
        ntuple(21) do index
            index in (8, 9, 10, 20) ? FT(index) : zero(FT)
        end,
    )
    field() = ClimaCore.Fields.zeros(surface_space)
    p = (;
        casa_plant = (; carbon_fluxes = fill(plant_fluxes, surface_space)),
        leaf_labile_input = field(),
        leaf_recalcitrant_input = field(),
        root_labile_input = field(),
        root_recalcitrant_input = field(),
        litter_metabolic_input = field(),
        litter_structural_input = field(),
        litter_cwd_input = field(),
        exudate_labile_input = field(),
    )
    ClimaLand.update_litter_coupling!(p, coupling)

    x_values = Array(parent(x))
    left = x_values .< FT(1)
    right = .!left
    leaf_labile = Array(parent(p.leaf_labile_input))
    root_labile = Array(parent(p.root_labile_input))
    @test all(leaf_labile[left] .== FT(8 * 0.4))
    @test all(leaf_labile[right] .== FT(8 * 0.7))
    @test all(root_labile[left] .== FT(10 * 0.3))
    @test all(root_labile[right] .== FT(10 * 0.6))
end

for FT in (Float32, Float64)
    @testset "CASA plant-soil litter coupling, FT = $FT" begin
        parameters = LitterCouplingParameters{FT}(;
            leaf_metabolic_fraction = FT(0.4),
            root_metabolic_fraction = FT(0.3),
        )
        @test isbits(parameters)
        p = coupling_cache(FT)
        ClimaLand.update_litter_coupling!(p, parameters)
        @test p.leaf_labile_input[1] == FT(8 * 0.4)
        @test p.leaf_recalcitrant_input[1] == FT(8 * 0.6)
        @test p.root_labile_input[1] == FT(10 * 0.3)
        @test p.root_recalcitrant_input[1] == FT(10 * 0.7)
        @test p.litter_metabolic_input[1] ==
              p.leaf_labile_input[1] + p.root_labile_input[1]
        @test p.litter_structural_input[1] ==
              p.leaf_recalcitrant_input[1] + p.root_recalcitrant_input[1]
        @test p.litter_cwd_input[1] == FT(9)
        @test p.exudate_labile_input[1] == FT(20)
        @test @allocated(ClimaLand.update_litter_coupling!(p, parameters)) == 0
    end
end


for FT in (Float32, Float64)
    @testset "Integrated MIMICS carbon-nitrogen conservation, FT = $FT" begin
        setup = integrated_mimics_cn_model(FT)
        model = setup.model
        Y, p, _ = ClimaLand.initialize(model)
        plant_initial = FT.((0.09, 0.37, 0.14, 0.01, 0.002, 0.003, 0.004))
        soil_initial =
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
        for (name, value) in
            zip(ClimaLand.prognostic_vars(model.casa_plant), plant_initial)
            getproperty(Y.casa_plant, name) .= value
        end
        for (name, value) in
            zip(ClimaLand.prognostic_vars(model.mimics_soil), soil_initial)
            getproperty(Y.mimics_soil, name) .= value
        end
        ClimaLand.make_set_initial_cache(model)(p, Y, zero(FT))
        plant_nitrogen = p.casa_plant.nitrogen_fluxes[]
        @test p.nitrogen_litter_metabolic_input[] == plant_nitrogen[4]
        @test p.nitrogen_litter_structural_input[] == plant_nitrogen[5]
        @test p.nitrogen_litter_cwd_input[] == plant_nitrogen[6]
        @test p.nitrogen_plant_uptake[] == plant_nitrogen[7]
        @test p.mimics_soil.nitrogen_plant_uptake[] == plant_nitrogen[7]
        @test zero(FT) < p.mimics_soil.litter_metabolic_fraction[] < one(FT)

        dY = similar(Y)
        ClimaLand.make_exp_tendency(model)(dY, Y, p, zero(FT))
        plant_nitrogen_tendency = sum(
            getproperty(dY.casa_plant, name)[] for
            name in (:n_leaf, :n_wood, :n_fine_root)
        )
        soil_nitrogen_tendency = sum(
            getproperty(dY.mimics_soil, name)[] for name in (
                :n_litter_metabolic,
                :n_litter_structural,
                :n_microbe_r,
                :n_microbe_k,
                :n_soil_available,
                :n_soil_chemical,
                :n_soil_physical,
                :n_litter_cwd,
                :n_mineral,
            )
        )
        soil_nitrogen = p.mimics_soil.nitrogen_fluxes[]
        conservation_tolerance =
            FT(512) * eps(FT) * sum(soil_initial[9:17]) / FT(86400)
        @test plant_nitrogen_tendency +
              soil_nitrogen_tendency +
              soil_nitrogen[10] +
              soil_nitrogen[11] ≈ setup.deposition + setup.fixation atol =
            conservation_tolerance
    end
end

for FT in (Float32, Float64)
    @testset "CASA plant-soil nitrogen coupling, FT = $FT" begin
        p = nitrogen_coupling_cache(FT)
        ClimaLand.update_nitrogen_coupling!(p)
        @test p.nitrogen_litter_metabolic_input[1] == FT(4)
        @test p.nitrogen_litter_structural_input[1] == FT(5)
        @test p.nitrogen_litter_cwd_input[1] == FT(6)
        @test p.nitrogen_plant_uptake[1] == FT(7)
        @test @allocated(ClimaLand.update_nitrogen_coupling!(p)) == 0
    end
end

for FT in (Float32, Float64)
    @testset "Integrated CASA carbon-nitrogen conservation, FT = $FT" begin
        setup = integrated_casa_cn_model(FT)
        model = setup.model
        @test length(ClimaLand.lsm_aux_vars(model)) == 12
        Y, p, _ = ClimaLand.initialize(model)
        plant_initial = (
            FT(0.09),
            FT(0.37),
            FT(0.14),
            FT(0.01),
            FT(0.002),
            FT(0.003),
            FT(0.004),
        )
        soil_initial = (
            FT(0.02),
            FT(0.03),
            FT(0.04),
            FT(0.5),
            FT(6),
            FT(7),
            FT(0.002),
            FT(0.003),
            FT(0.004),
            FT(0.05),
            FT(0.3),
            FT(0.35),
            FT(0.001),
        )
        for (name, value) in
            zip(ClimaLand.prognostic_vars(model.casa_plant), plant_initial)
            getproperty(Y.casa_plant, name) .= value
        end
        for (name, value) in
            zip(ClimaLand.prognostic_vars(model.casa_soil), soil_initial)
            getproperty(Y.casa_soil, name) .= value
        end

        ClimaLand.make_set_initial_cache(model)(p, Y, zero(FT))
        plant_carbon = p.casa_plant.carbon_fluxes[]
        plant_nitrogen = p.casa_plant.nitrogen_fluxes[]
        expected_metabolic =
            plant_carbon[8] * plant_nitrogen[11] +
            plant_carbon[10] * plant_nitrogen[12]
        @test p.litter_metabolic_input[] ≈ expected_metabolic
        @test p.nitrogen_litter_metabolic_input[] == plant_nitrogen[4]
        @test p.nitrogen_litter_structural_input[] == plant_nitrogen[5]
        @test p.nitrogen_litter_cwd_input[] == plant_nitrogen[6]
        @test p.nitrogen_plant_uptake[] == plant_nitrogen[7]
        @test p.casa_soil.nitrogen_plant_uptake[] == plant_nitrogen[7]

        dY = similar(Y)
        ClimaLand.make_exp_tendency(model)(dY, Y, p, zero(FT))
        plant_nitrogen_tendency = sum(
            getproperty(dY.casa_plant, name)[] for
            name in (:n_leaf, :n_wood, :n_fine_root)
        )
        soil_nitrogen_tendency = sum(
            getproperty(dY.casa_soil, name)[] for name in (
                :n_litter_metabolic,
                :n_litter_structural,
                :n_litter_cwd,
                :n_soil_microbial,
                :n_soil_slow,
                :n_soil_passive,
                :n_mineral,
            )
        )
        soil_nitrogen = p.casa_soil.nitrogen_fluxes[]
        external_inputs = setup.deposition + setup.fixation
        @test plant_nitrogen_tendency +
              soil_nitrogen_tendency +
              soil_nitrogen[12] +
              soil_nitrogen[13] ≈ external_inputs atol =
            FT(128) * eps(FT) * external_inputs
    end
end

function carbon_only_model(model::CASAPlantCASASoilModel{FT}) where {FT}
    plant = PlantCASA.CASAPlantModel{FT}(;
        parameters = model.casa_plant.parameters,
        drivers = model.casa_plant.drivers,
        domain = model.casa_plant.domain,
    )
    soil = SoilCASA.CASASoilModel{FT}(;
        parameters = model.casa_soil.parameters,
        drivers = model.casa_soil.drivers,
        domain = model.casa_soil.domain,
    )
    return CASAPlantSoilModel{FT}(plant, soil, model.coupling)
end

function carbon_only_model(model::CASAPlantMIMICSSoilModel{FT}) where {FT}
    plant = PlantCASA.CASAPlantModel{FT}(;
        parameters = model.casa_plant.parameters,
        drivers = model.casa_plant.drivers,
        domain = model.casa_plant.domain,
    )
    soil = MIMICS.MIMICSSoilModel{FT}(;
        parameters = model.mimics_soil.parameters,
        drivers = model.mimics_soil.drivers,
        domain = model.mimics_soil.domain,
    )
    return CASAPlantSoilModel{FT}(plant, soil, model.coupling)
end

function tracer_initial_state(model, ::Type{FT}) where {FT}
    components = ClimaLand.land_components(model)
    states = map(enumerate(components)) do (component_index, component_name)
        component = getproperty(model, component_name)
        variables = ClimaLand.prognostic_vars(component)
        return NamedTuple{variables}(
            ntuple(
                index -> FT(0.01 + component_index / 100 + index / 1000),
                length(variables),
            ),
        )
    end
    return NamedTuple{components}(Tuple(states))
end

function tracer_provenance(label, stages)
    return Dict(
        "model" => String(label),
        "configuration" => String(label),
        "pft" => 7,
        "parameter_file" => Dict(
            "source" => "GRID_CN/pftlookup_igbp_updated4_exud0.csv",
            "sha256" => repeat("a", 64),
        ),
        "forcing" => [
            Dict(
                "stage" => String(stage.name),
                "source" => "synthetic-$(stage.forcing_days)-day-period",
                "sha256" => repeat(string(index), 64),
            ) for (index, stage) in enumerate(stages)
        ],
    )
end

@testset "Native prespin-to-history tracer workflow" begin
    FT = Float64
    casa_cn = integrated_casa_cn_model(FT).model
    mimics_cn = integrated_mimics_cn_model(FT).model
    models = (
        casa_c = carbon_only_model(casa_cn),
        casa_cn = casa_cn,
        mimics_c = carbon_only_model(mimics_cn),
        mimics_cn = mimics_cn,
    )
    stages = (
        NativeWorkflow.NativeStage(:prespin, 2, 2),
        NativeWorkflow.NativeStage(:spin, 2, 1),
        NativeWorkflow.NativeStage(:historical, 3, 1),
    )
    expected_forcing = [
        (:prespin, 1),
        (:prespin, 2),
        (:prespin, 1),
        (:prespin, 2),
        (:spin, 1),
        (:spin, 2),
        (:historical, 1),
        (:historical, 2),
        (:historical, 3),
    ]

    mktempdir() do directory
        for (label, model) in pairs(models)
            @testset "$label" begin
                forcing = Tuple{Symbol, Int}[]
                output_dir = joinpath(directory, string(label))
                result = NativeWorkflow.run_workflow(
                    model,
                    tracer_initial_state(model, FT),
                    stages,
                    output_dir;
                    update_forcing! = (stage, index, _) ->
                        push!(forcing, (stage.name, index)),
                    provenance = tracer_provenance(label, stages),
                )
                @test forcing == expected_forcing
                @test result.time == 9 * 86400
                @test length(result.checkpoints) == 3

                manifest = TOML.parsefile(result.manifest)
                @test manifest["temporal_scheme"] == "ForwardEuler"
                @test manifest["recorded_steps"] == 9
                @test manifest["provenance"]["configuration"] == String(label)
                @test getindex.(manifest["stage"], "steps") == [4, 2, 3]

                uninterrupted_stages =
                    (NativeWorkflow.NativeStage(:historical, 9, 1),)
                uninterrupted = NativeWorkflow.run_workflow(
                    model,
                    tracer_initial_state(model, FT),
                    uninterrupted_stages,
                    joinpath(directory, "$(label)_uninterrupted");
                    provenance = tracer_provenance(label, uninterrupted_stages),
                )

                Y_restart, restart_time =
                    ClimaLand.read_checkpoint(last(result.checkpoints); model)
                @test restart_time == result.time
                NCDatasets.NCDataset(result.output) do output
                    @test parent(output["time"])[:] == [1, 2, 3] .* 86400
                    for component_name in ClimaLand.land_components(model)
                        component = getproperty(model, component_name)
                        for variable in ClimaLand.prognostic_vars(component)
                            expected = vec(
                                Array(
                                    parent(
                                        getproperty(
                                            getproperty(
                                                result.state,
                                                component_name,
                                            ),
                                            variable,
                                        ),
                                    ),
                                ),
                            )
                            restarted = vec(
                                Array(
                                    parent(
                                        getproperty(
                                            getproperty(
                                                Y_restart,
                                                component_name,
                                            ),
                                            variable,
                                        ),
                                    ),
                                ),
                            )
                            uninterrupted_state = vec(
                                Array(
                                    parent(
                                        getproperty(
                                            getproperty(
                                                uninterrupted.state,
                                                component_name,
                                            ),
                                            variable,
                                        ),
                                    ),
                                ),
                            )
                            name = "$(component_name)__$(variable)"
                            @test restarted == expected
                            @test uninterrupted_state == expected
                            @test output[name][:, end] == expected
                        end
                    end
                end
            end
        end
    end
end
