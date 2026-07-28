export CASAPlantSoilModel,
    CASAPlantEnergyHydrologyModel,
    CASAPlantCASASoilModel,
    CASAPlantMIMICSSoilModel,
    CASAPlantCORPSESoilModel,
    LitterCouplingParameters

import ClimaComms

"""
    LitterCouplingParameters{FT}

Point fractions of leaf and fine-root turnover routed to metabolic/labile
litter. The complementary fractions are routed to structural/recalcitrant
litter. Coupled models accept either one value or a surface
`ClimaCore.Fields.Field` of values.
"""
Base.@kwdef struct LitterCouplingParameters{FT <: AbstractFloat}
    leaf_metabolic_fraction::FT
    root_metabolic_fraction::FT
end

Base.broadcastable(parameters::LitterCouplingParameters) = tuple(parameters)

@inline leaf_metabolic_fraction(parameters) = parameters.leaf_metabolic_fraction
@inline root_metabolic_fraction(parameters) = parameters.root_metabolic_fraction

function validate_litter_coupling(coupling, domain, ::Type{FT}) where {FT}
    @assert coupling isa LitterCouplingParameters{FT} || (
        coupling isa Fields.Field &&
        eltype(coupling) <: LitterCouplingParameters{FT}
    ) "coupling must be point parameters or a Field of point parameters"
    @assert (
        !(coupling isa Fields.Field) || axes(coupling) == domain.space.surface
    ) "spatial coupling must use the model surface space"
    return nothing
end

has_root_exudation(parameters::Vegetation.CASA.CASAPlantModelParameters) =
    !iszero(parameters.root_exudate_fraction)

function has_root_exudation(parameters::Fields.Field)
    fractions = Vegetation.CASA.root_exudate_fraction.(parameters)
    local_maximum = maximum(abs, parent(fractions))
    context = ClimaComms.context(axes(parameters))
    return !iszero(ClimaComms.allreduce(context, local_maximum, max))
end

"""
    CASAPlantSoilModel{FT}(plant, soil, coupling)

An integrated CASA plant-carbon model coupled by litterfall to one selectable
CASA, MIMICS, or CORPSE standalone soil biogeochemistry model.
"""
abstract type CASAPlantSoilModel{FT} <: AbstractLandModel{FT} end

struct CASAPlantCASASoilModel{FT, P, S, C} <: CASAPlantSoilModel{FT}
    casa_plant::P
    casa_soil::S
    coupling::C
end

struct CASAPlantMIMICSSoilModel{FT, P, S, C} <: CASAPlantSoilModel{FT}
    casa_plant::P
    mimics_soil::S
    coupling::C
end

struct CASAPlantCORPSESoilModel{FT, P, S, C} <: CASAPlantSoilModel{FT}
    casa_plant::P
    corpse_soil::S
    coupling::C
end

"""
    CASAPlantEnergyHydrologyModel{FT}(soil, biogeochemistry; rooting_depth)

Couple a CASA plant/biogeochemistry model to prognostic ClimaLand soil energy
and hydrology. Root-normalized column means replace the prescribed soil
temperature and moisture drivers while the existing litter and nitrogen
coupling remains unchanged.
"""
abstract type CASAPlantEnergyHydrologyModel{FT} <: AbstractLandModel{FT} end

struct CASAPlantEnergyHydrologyCASASoilModel{FT, H, P, S, C, R} <:
       CASAPlantEnergyHydrologyModel{FT}
    soil::H
    casa_plant::P
    casa_soil::S
    coupling::C
    rooting_depth::R
end

struct CASAPlantEnergyHydrologyMIMICSSoilModel{FT, H, P, S, C, R} <:
       CASAPlantEnergyHydrologyModel{FT}
    soil::H
    casa_plant::P
    mimics_soil::S
    coupling::C
    rooting_depth::R
end

struct CASAPlantEnergyHydrologyCORPSESoilModel{FT, H, P, S, C, R} <:
       CASAPlantEnergyHydrologyModel{FT}
    soil::H
    casa_plant::P
    corpse_soil::S
    coupling::C
    rooting_depth::R
end

function validate_rooting_depth(rooting_depth, domain, ::Type{FT}) where {FT}
    @assert rooting_depth isa FT ||
            (rooting_depth isa Fields.Field && eltype(rooting_depth) == FT) "rooting_depth must be a scalar or surface Field"
    @assert (
        !(rooting_depth isa Fields.Field) ||
        axes(rooting_depth) == domain.space.surface
    ) "spatial rooting_depth must use the model surface space"
    if rooting_depth isa Fields.Field
        local_minimum = minimum(parent(rooting_depth))
        context = ClimaComms.context(axes(rooting_depth))
        @assert ClimaComms.allreduce(context, local_minimum, min) > zero(FT)
    else
        @assert rooting_depth > zero(FT)
    end
    return nothing
end

function CASAPlantEnergyHydrologyModel{FT}(
    soil::Soil.EnergyHydrology{FT},
    model::CASAPlantCASASoilModel{FT};
    rooting_depth,
) where {FT}
    soil.domain == model.casa_plant.domain ||
        error("EnergyHydrology and biogeochemistry domains must match")
    validate_rooting_depth(rooting_depth, soil.domain, FT)
    return CASAPlantEnergyHydrologyCASASoilModel{
        FT,
        typeof(soil),
        typeof(model.casa_plant),
        typeof(model.casa_soil),
        typeof(model.coupling),
        typeof(rooting_depth),
    }(
        soil,
        model.casa_plant,
        model.casa_soil,
        model.coupling,
        rooting_depth,
    )
end

function CASAPlantEnergyHydrologyModel{FT}(
    soil::Soil.EnergyHydrology{FT},
    model::CASAPlantMIMICSSoilModel{FT};
    rooting_depth,
) where {FT}
    soil.domain == model.casa_plant.domain ||
        error("EnergyHydrology and biogeochemistry domains must match")
    validate_rooting_depth(rooting_depth, soil.domain, FT)
    return CASAPlantEnergyHydrologyMIMICSSoilModel{
        FT,
        typeof(soil),
        typeof(model.casa_plant),
        typeof(model.mimics_soil),
        typeof(model.coupling),
        typeof(rooting_depth),
    }(
        soil,
        model.casa_plant,
        model.mimics_soil,
        model.coupling,
        rooting_depth,
    )
end

function CASAPlantEnergyHydrologyModel{FT}(
    soil::Soil.EnergyHydrology{FT},
    model::CASAPlantCORPSESoilModel{FT};
    rooting_depth,
) where {FT}
    soil.domain == model.casa_plant.domain ||
        error("EnergyHydrology and biogeochemistry domains must match")
    validate_rooting_depth(rooting_depth, soil.domain, FT)
    return CASAPlantEnergyHydrologyCORPSESoilModel{
        FT,
        typeof(soil),
        typeof(model.casa_plant),
        typeof(model.corpse_soil),
        typeof(model.coupling),
        typeof(rooting_depth),
    }(
        soil,
        model.casa_plant,
        model.corpse_soil,
        model.coupling,
        rooting_depth,
    )
end

function CASAPlantSoilModel{FT}(
    plant::Vegetation.CASA.CASAPlantModel{FT},
    soil::Soil.Biogeochemistry.CASA.CASASoilModel{FT},
    coupling,
) where {FT}
    plant.domain == soil.domain || error("Plant and soil domains must match")
    typeof(plant.configuration) == typeof(soil.configuration) ||
        error("CASA plant and soil nutrient configurations must match")
    validate_litter_coupling(coupling, plant.domain, FT)
    !has_root_exudation(plant.parameters) ||
        error("CASA soil does not accept root exudate in carbon-only mode")
    model_type = CASAPlantCASASoilModel{
        FT,
        typeof(plant),
        typeof(soil),
        typeof(coupling),
    }
    return model_type(plant, soil, coupling)
end

function CASAPlantSoilModel{FT}(
    plant::Vegetation.CASA.CASAPlantModel{FT},
    soil::Soil.Biogeochemistry.MIMICS.MIMICSSoilModel{FT},
    coupling,
) where {FT}
    plant.domain == soil.domain || error("Plant and soil domains must match")
    typeof(plant.configuration) == typeof(soil.configuration) ||
        error("CASA plant and MIMICS nutrient configurations must match")
    validate_litter_coupling(coupling, plant.domain, FT)
    !has_root_exudation(plant.parameters) ||
        error("MIMICS does not accept root exudate in carbon-only mode")
    return CASAPlantMIMICSSoilModel{
        FT,
        typeof(plant),
        typeof(soil),
        typeof(coupling),
    }(
        plant,
        soil,
        coupling,
    )
end

@inline function mimics_litter_quality(
    plant_parameters,
    soil_parameters,
    c_leaf,
    c_wood,
    c_fine_root,
    n_leaf,
    n_wood,
    n_fine_root,
    leaf_turnover,
    root_turnover,
    c_litter_cwd,
    soil_temperature,
    liquid_saturation,
)
    cwd_to_structural = Soil.Biogeochemistry.MIMICS.cwd_to_structural_flux(
        soil_parameters,
        c_litter_cwd,
        soil_temperature,
        liquid_saturation,
    )
    return Vegetation.CASA.mimics_litter_quality(
        plant_parameters,
        (c_leaf, c_wood, c_fine_root),
        (n_leaf, n_wood, n_fine_root),
        leaf_turnover,
        root_turnover,
        cwd_to_structural,
    )
end

@inline mimics_nitrogen_limitation(plant_parameters, mineral_nitrogen) =
    Soil.Biogeochemistry.CASA.nitrogen_demand_fraction(
        mineral_nitrogen,
        plant_parameters.limitation_minimum,
        plant_parameters.limitation_maximum,
    )

function CASAPlantSoilModel{FT}(
    plant::Vegetation.CASA.CASAPlantModel{FT},
    soil::Soil.Biogeochemistry.CORPSE.CORPSESoilModel{FT},
    coupling,
) where {FT}
    plant.domain == soil.domain || error("Plant and soil domains must match")
    validate_litter_coupling(coupling, plant.domain, FT)
    return CASAPlantCORPSESoilModel{
        FT,
        typeof(plant),
        typeof(soil),
        typeof(coupling),
    }(
        plant,
        soil,
        coupling,
    )
end

land_components(::CASAPlantCASASoilModel) = (:casa_plant, :casa_soil)
land_components(::CASAPlantMIMICSSoilModel) = (:casa_plant, :mimics_soil)
land_components(::CASAPlantCORPSESoilModel) = (:casa_plant, :corpse_soil)
land_components(::CASAPlantEnergyHydrologyCASASoilModel) =
    (:soil, :casa_plant, :casa_soil)
land_components(::CASAPlantEnergyHydrologyMIMICSSoilModel) =
    (:soil, :casa_plant, :mimics_soil)
land_components(::CASAPlantEnergyHydrologyCORPSESoilModel) =
    (:soil, :casa_plant, :corpse_soil)

get_domain(model::CASAPlantSoilModel) = model.casa_plant.domain

const COUPLED_LITTER_VARS = (
    :leaf_labile_input,
    :leaf_recalcitrant_input,
    :root_labile_input,
    :root_recalcitrant_input,
    :litter_metabolic_input,
    :litter_structural_input,
    :litter_cwd_input,
    :exudate_labile_input,
)

const COUPLED_NITROGEN_VARS = (
    :nitrogen_litter_metabolic_input,
    :nitrogen_litter_structural_input,
    :nitrogen_litter_cwd_input,
    :nitrogen_plant_uptake,
)

const ROOT_WEIGHTED_SOIL_VARS = (
    :root_normalization,
    :root_weighted_soil_temperature,
    :root_weighted_liquid_water,
    :root_weighted_liquid_saturation,
    :root_weighted_frozen_saturation,
)

function coupling_aux_vars(model)
    if model.casa_plant.configuration isa Soil.Biogeochemistry.CarbonNitrogen
        return (COUPLED_LITTER_VARS..., COUPLED_NITROGEN_VARS...)
    end
    return COUPLED_LITTER_VARS
end

lsm_aux_vars(model::CASAPlantSoilModel) = coupling_aux_vars(model)
lsm_aux_types(model::CASAPlantSoilModel{FT}) where {FT} =
    ntuple(_ -> FT, length(lsm_aux_vars(model)))
lsm_aux_domain_names(model::CASAPlantSoilModel) =
    ntuple(_ -> :surface, length(lsm_aux_vars(model)))

lsm_aux_vars(model::CASAPlantEnergyHydrologyModel) =
    (ROOT_WEIGHTED_SOIL_VARS..., coupling_aux_vars(model)...)
lsm_aux_types(model::CASAPlantEnergyHydrologyModel{FT}) where {FT} =
    ntuple(_ -> FT, length(lsm_aux_vars(model)))
lsm_aux_domain_names(model::CASAPlantEnergyHydrologyModel) =
    ntuple(_ -> :surface, length(lsm_aux_vars(model)))

function update_litter_coupling!(p, coupling)
    plant_fluxes = p.casa_plant.carbon_fluxes
    @. p.leaf_labile_input =
        getindex(plant_fluxes, 8) * leaf_metabolic_fraction(coupling)
    @. p.leaf_recalcitrant_input =
        getindex(plant_fluxes, 8) * (
            one(leaf_metabolic_fraction(coupling)) -
            leaf_metabolic_fraction(coupling)
        )
    @. p.root_labile_input =
        getindex(plant_fluxes, 10) * root_metabolic_fraction(coupling)
    @. p.root_recalcitrant_input =
        getindex(plant_fluxes, 10) * (
            one(root_metabolic_fraction(coupling)) -
            root_metabolic_fraction(coupling)
        )
    @. p.litter_metabolic_input = p.leaf_labile_input + p.root_labile_input
    @. p.litter_structural_input =
        p.leaf_recalcitrant_input + p.root_recalcitrant_input
    @. p.litter_cwd_input = getindex(plant_fluxes, 9)
    @. p.exudate_labile_input = getindex(plant_fluxes, 20)
    return nothing
end

function update_litter_coupling!(p, coupling, ::Soil.Biogeochemistry.CarbonOnly)
    return update_litter_coupling!(p, coupling)
end

function update_litter_coupling!(
    p,
    coupling,
    ::Soil.Biogeochemistry.CarbonNitrogen,
)
    carbon_fluxes = p.casa_plant.carbon_fluxes
    nitrogen_fluxes = p.casa_plant.nitrogen_fluxes
    @. p.leaf_labile_input =
        getindex(carbon_fluxes, 8) * getindex(nitrogen_fluxes, 11)
    @. p.leaf_recalcitrant_input =
        getindex(carbon_fluxes, 8) *
        (one(getindex(nitrogen_fluxes, 11)) - getindex(nitrogen_fluxes, 11))
    @. p.root_labile_input =
        getindex(carbon_fluxes, 10) * getindex(nitrogen_fluxes, 12)
    @. p.root_recalcitrant_input =
        getindex(carbon_fluxes, 10) *
        (one(getindex(nitrogen_fluxes, 12)) - getindex(nitrogen_fluxes, 12))
    @. p.litter_metabolic_input = p.leaf_labile_input + p.root_labile_input
    @. p.litter_structural_input =
        p.leaf_recalcitrant_input + p.root_recalcitrant_input
    @. p.litter_cwd_input = getindex(carbon_fluxes, 9)
    @. p.exudate_labile_input = getindex(carbon_fluxes, 20)
    return nothing
end

function update_nitrogen_coupling!(p)
    plant_fluxes = p.casa_plant.nitrogen_fluxes
    @. p.nitrogen_litter_metabolic_input = getindex(plant_fluxes, 4)
    @. p.nitrogen_litter_structural_input = getindex(plant_fluxes, 5)
    @. p.nitrogen_litter_cwd_input = getindex(plant_fluxes, 6)
    @. p.nitrogen_plant_uptake = getindex(plant_fluxes, 7)
    return nothing
end

soil_biogeochemistry(model::CASAPlantEnergyHydrologyCASASoilModel) =
    model.casa_soil
soil_biogeochemistry(model::CASAPlantEnergyHydrologyMIMICSSoilModel) =
    model.mimics_soil
soil_biogeochemistry(model::CASAPlantEnergyHydrologyCORPSESoilModel) =
    model.corpse_soil

coupled_biogeochemistry(
    model::CASAPlantEnergyHydrologyCASASoilModel{FT},
) where {FT} =
    CASAPlantSoilModel{FT}(model.casa_plant, model.casa_soil, model.coupling)
coupled_biogeochemistry(
    model::CASAPlantEnergyHydrologyMIMICSSoilModel{FT},
) where {FT} =
    CASAPlantSoilModel{FT}(model.casa_plant, model.mimics_soil, model.coupling)
coupled_biogeochemistry(
    model::CASAPlantEnergyHydrologyCORPSESoilModel{FT},
) where {FT} =
    CASAPlantSoilModel{FT}(model.casa_plant, model.corpse_soil, model.coupling)

get_drivers(model::CASAPlantEnergyHydrologyModel) = get_drivers(model.soil)

function update_root_weighted_soil_drivers!(p, Y, model)
    z = ClimaCore.Fields.coordinate_field(axes(p.soil.T)).z
    rooting_depth = model.rooting_depth
    porosity = model.soil.parameters.ν
    root_density = @. lazy(Canopy.root_distribution(z, rooting_depth))
    ClimaCore.Operators.column_integral_definite!(
        p.root_normalization,
        root_density,
    )
    root_weight = @. lazy(root_density / p.root_normalization)
    liquid_saturation =
        @. lazy(clamp(p.soil.θ_l / porosity, zero(p.soil.θ_l), one(p.soil.θ_l)))
    frozen_saturation = @. lazy(
        clamp(
            Y.soil.θ_i / porosity,
            zero(Y.soil.θ_i),
            one(Y.soil.θ_i) - liquid_saturation,
        ),
    )
    weighted_temperature = @. lazy(p.soil.T * root_weight)
    weighted_liquid_water = @. lazy(p.soil.θ_l * root_weight)
    weighted_liquid_saturation = @. lazy(liquid_saturation * root_weight)
    weighted_frozen_saturation = @. lazy(frozen_saturation * root_weight)
    ClimaCore.Operators.column_integral_definite!(
        p.root_weighted_soil_temperature,
        weighted_temperature,
    )
    ClimaCore.Operators.column_integral_definite!(
        p.root_weighted_liquid_water,
        weighted_liquid_water,
    )
    ClimaCore.Operators.column_integral_definite!(
        p.root_weighted_liquid_saturation,
        weighted_liquid_saturation,
    )
    ClimaCore.Operators.column_integral_definite!(
        p.root_weighted_frozen_saturation,
        weighted_frozen_saturation,
    )
    return nothing
end

function update_native_plant_drivers!(
    p,
    Y,
    plant,
    t,
    ::Soil.Biogeochemistry.CarbonOnly,
)
    npp_scalar = plant.drivers.npp_scalar(t)
    labile_fraction = plant.drivers.labile_fraction(t)
    @. p.casa_plant.soil_temperature = p.root_weighted_soil_temperature
    @. p.casa_plant.water_stress = p.root_weighted_liquid_saturation
    @. p.casa_plant.carbon_fluxes = Vegetation.CASA.packed_carbon_fluxes(
        plant.temporal_mode,
        plant.parameters,
        Y.casa_plant.c_leaf,
        Y.casa_plant.c_wood,
        Y.casa_plant.c_fine_root,
        Y.casa_plant.c_labile,
        p.casa_plant.gross_primary_production,
        p.casa_plant.air_temperature,
        p.casa_plant.soil_temperature,
        p.casa_plant.water_stress,
        p.casa_plant.phenology_phase,
        npp_scalar,
        labile_fraction,
    )
    return nothing
end

function update_native_plant_drivers!(
    p,
    Y,
    plant,
    t,
    ::Soil.Biogeochemistry.CarbonNitrogen,
)
    npp_scalar = plant.drivers.npp_scalar(t)
    labile_fraction = plant.drivers.labile_fraction(t)
    @. p.casa_plant.soil_temperature = p.root_weighted_soil_temperature
    @. p.casa_plant.water_stress = p.root_weighted_liquid_saturation
    @. p.casa_plant.carbon_fluxes = Vegetation.CASA.packed_carbon_fluxes(
        plant.temporal_mode,
        plant.parameters,
        Y.casa_plant.c_leaf,
        Y.casa_plant.c_wood,
        Y.casa_plant.c_fine_root,
        Y.casa_plant.c_labile,
        p.casa_plant.gross_primary_production,
        p.casa_plant.air_temperature,
        p.casa_plant.soil_temperature,
        p.casa_plant.water_stress,
        p.casa_plant.phenology_phase,
        npp_scalar,
        labile_fraction,
        Y.casa_plant.n_leaf,
        Y.casa_plant.n_wood,
        Y.casa_plant.n_fine_root,
    )
    return nothing
end

function update_native_biogeochemistry_drivers!(
    p,
    model::CASAPlantEnergyHydrologyCASASoilModel,
)
    parameters = model.casa_soil.parameters
    @. p.casa_soil.soil_temperature = p.root_weighted_soil_temperature
    @. p.casa_soil.relative_saturation =
        Soil.Biogeochemistry.CASA.parameter_relative_saturation(
            parameters,
            p.root_weighted_liquid_water,
        )
    @. p.casa_soil.temperature_factor =
        Soil.Biogeochemistry.CASA.parameter_temperature_factor(
            parameters,
            p.casa_soil.soil_temperature,
        )
    @. p.casa_soil.moisture_factor =
        Soil.Biogeochemistry.CASA.parameter_moisture_factor(
            parameters,
            p.casa_soil.relative_saturation,
        )
    return nothing
end

function update_native_biogeochemistry_drivers!(
    p,
    ::CASAPlantEnergyHydrologyMIMICSSoilModel,
)
    @. p.mimics_soil.soil_temperature = p.root_weighted_soil_temperature
    @. p.mimics_soil.liquid_saturation = p.root_weighted_liquid_saturation
    @. p.mimics_soil.frozen_saturation = p.root_weighted_frozen_saturation
    return nothing
end

function update_native_biogeochemistry_drivers!(
    p,
    ::CASAPlantEnergyHydrologyCORPSESoilModel,
)
    @. p.corpse_soil.soil_temperature = p.root_weighted_soil_temperature
    @. p.corpse_soil.liquid_saturation = p.root_weighted_liquid_saturation
    @. p.corpse_soil.frozen_saturation = p.root_weighted_frozen_saturation
    return nothing
end

function make_update_aux(model::CASAPlantEnergyHydrologyModel)
    soil_aux! = make_update_aux(model.soil)
    plant_aux! = make_update_aux(model.casa_plant)
    biogeochemistry_aux! = make_update_aux(soil_biogeochemistry(model))
    function update_aux!(p, Y, t)
        soil_aux!(p, Y, t)
        plant_aux!(p, Y, t)
        biogeochemistry_aux!(p, Y, t)
        update_root_weighted_soil_drivers!(p, Y, model)
        update_native_plant_drivers!(
            p,
            Y,
            model.casa_plant,
            t,
            model.casa_plant.configuration,
        )
        update_native_biogeochemistry_drivers!(p, model)
        return nothing
    end
    return update_aux!
end

function make_update_boundary_fluxes(model::CASAPlantEnergyHydrologyModel)
    soil_boundary! = make_update_boundary_fluxes(model.soil)
    biogeochemistry_boundary! =
        make_update_boundary_fluxes(coupled_biogeochemistry(model))
    function update_boundary_fluxes!(p, Y, t)
        soil_boundary!(p, Y, t)
        biogeochemistry_boundary!(p, Y, t)
        return nothing
    end
    return update_boundary_fluxes!
end

function make_update_boundary_fluxes(model::CASAPlantCASASoilModel)
    plant_boundary! = make_update_boundary_fluxes(model.casa_plant)
    soil_boundary! = make_update_boundary_fluxes(model.casa_soil)
    function update_boundary_fluxes!(p, Y, t)
        plant_boundary!(p, Y, t)
        soil_boundary!(p, Y, t)
        if model.casa_plant.configuration isa
           Soil.Biogeochemistry.CarbonNitrogen
            soil_nitrogen_parameters = model.casa_soil.nitrogen_parameters
            @. p.casa_plant.nitrogen_demand_fraction =
                Soil.Biogeochemistry.CASA.nitrogen_demand_fraction(
                    Y.casa_soil.n_mineral,
                    soil_nitrogen_parameters.limitation_minimum,
                    soil_nitrogen_parameters.limitation_maximum,
                )
            Vegetation.CASA.update_nitrogen_limited_carbon_fluxes!(
                p,
                Y,
                model.casa_plant,
                t,
                Y.casa_soil.n_mineral,
            )
            Vegetation.CASA.update_nitrogen_fluxes!(
                p,
                Y,
                model.casa_plant.temporal_mode,
                model.casa_plant.nitrogen_parameters,
                Y.casa_soil.n_mineral,
                p.casa_plant.nitrogen_demand_fraction,
                p.casa_soil.nitrogen_limitation,
            )
        end
        update_litter_coupling!(
            p,
            model.coupling,
            model.casa_plant.configuration,
        )
        if model.casa_plant.configuration isa
           Soil.Biogeochemistry.CarbonNitrogen
            update_nitrogen_coupling!(p)
            Soil.Biogeochemistry.CASA.update_carbon_fluxes!(
                p,
                Y,
                model.casa_soil.parameters,
                p.litter_metabolic_input,
                p.litter_structural_input,
                p.litter_cwd_input,
                p.casa_soil.nitrogen_limitation,
            )
            Soil.Biogeochemistry.CASA.update_nitrogen_fluxes!(
                p,
                Y,
                model.casa_soil.parameters,
                soil_nitrogen_parameters,
                p.nitrogen_litter_metabolic_input,
                p.nitrogen_litter_structural_input,
                p.nitrogen_litter_cwd_input,
                p.casa_soil.nitrogen_deposition,
                p.casa_soil.nitrogen_fixation,
                p.nitrogen_plant_uptake,
            )
        else
            Soil.Biogeochemistry.CASA.update_carbon_fluxes!(
                p,
                Y,
                model.casa_soil.parameters,
                p.litter_metabolic_input,
                p.litter_structural_input,
                p.litter_cwd_input,
            )
        end
    end
    return update_boundary_fluxes!
end

function make_update_boundary_fluxes(model::CASAPlantMIMICSSoilModel)
    plant_boundary! = make_update_boundary_fluxes(model.casa_plant)
    soil_boundary! = make_update_boundary_fluxes(model.mimics_soil)
    function update_boundary_fluxes!(p, Y, t)
        plant_boundary!(p, Y, t)
        soil_boundary!(p, Y, t)
        if model.casa_plant.configuration isa
           Soil.Biogeochemistry.CarbonNitrogen
            plant_nitrogen_parameters = model.casa_plant.nitrogen_parameters
            soil_nitrogen_parameters = model.mimics_soil.nitrogen_parameters
            @. p.casa_plant.nitrogen_demand_fraction =
                Soil.Biogeochemistry.CASA.nitrogen_demand_fraction(
                    Y.mimics_soil.n_mineral,
                    plant_nitrogen_parameters.limitation_minimum,
                    plant_nitrogen_parameters.limitation_maximum,
                )
            @. p.casa_plant.nitrogen_limitation = mimics_nitrogen_limitation(
                plant_nitrogen_parameters,
                Y.mimics_soil.n_mineral,
            )
            Vegetation.CASA.update_nitrogen_limited_carbon_fluxes!(
                p,
                Y,
                model.casa_plant,
                t,
                Y.mimics_soil.n_mineral,
            )
            Vegetation.CASA.update_mimics_nitrogen_fluxes!(
                p,
                Y,
                model.casa_plant.temporal_mode,
                plant_nitrogen_parameters,
                Y.mimics_soil.n_mineral,
                p.casa_plant.nitrogen_demand_fraction,
                p.casa_plant.nitrogen_limitation,
            )
            update_litter_coupling!(
                p,
                model.coupling,
                model.casa_plant.configuration,
            )
            update_nitrogen_coupling!(p)
            plant_carbon_fluxes = p.casa_plant.carbon_fluxes
            @. p.mimics_soil.litter_metabolic_fraction = mimics_litter_quality(
                plant_nitrogen_parameters,
                model.mimics_soil.parameters,
                Y.casa_plant.c_leaf,
                Y.casa_plant.c_wood,
                Y.casa_plant.c_fine_root,
                Y.casa_plant.n_leaf,
                Y.casa_plant.n_wood,
                Y.casa_plant.n_fine_root,
                getindex(plant_carbon_fluxes, 8),
                getindex(plant_carbon_fluxes, 10),
                Y.mimics_soil.c_litter_cwd,
                p.mimics_soil.soil_temperature,
                p.mimics_soil.liquid_saturation,
            )
            Soil.Biogeochemistry.MIMICS.update_carbon_nitrogen_fluxes!(
                p,
                Y,
                model.mimics_soil.parameters,
                soil_nitrogen_parameters,
                p.mimics_soil.soil_temperature,
                p.mimics_soil.liquid_saturation,
                p.mimics_soil.frozen_saturation,
                p.litter_metabolic_input,
                p.litter_structural_input,
                p.litter_cwd_input,
                p.nitrogen_litter_metabolic_input,
                p.nitrogen_litter_structural_input,
                p.nitrogen_litter_cwd_input,
                p.mimics_soil.nitrogen_deposition,
                p.mimics_soil.nitrogen_fixation,
                p.nitrogen_plant_uptake,
                p.mimics_soil.litter_metabolic_fraction,
                p.mimics_soil.annual_npp,
            )
        else
            update_litter_coupling!(p, model.coupling)
            Soil.Biogeochemistry.MIMICS.update_carbon_fluxes!(
                p,
                Y,
                model.mimics_soil.temporal_mode,
                model.mimics_soil.parameters,
                p.mimics_soil.soil_temperature,
                p.mimics_soil.liquid_saturation,
                p.mimics_soil.frozen_saturation,
                p.litter_metabolic_input,
                p.litter_structural_input,
                p.litter_cwd_input,
                p.mimics_soil.litter_metabolic_fraction,
                p.mimics_soil.annual_npp,
            )
        end
    end
    return update_boundary_fluxes!
end

function make_update_boundary_fluxes(model::CASAPlantCORPSESoilModel)
    plant_boundary! = make_update_boundary_fluxes(model.casa_plant)
    soil_boundary! = make_update_boundary_fluxes(model.corpse_soil)
    function update_boundary_fluxes!(p, Y, t)
        plant_boundary!(p, Y, t)
        soil_boundary!(p, Y, t)
        update_litter_coupling!(p, model.coupling)
        @. p.exudate_labile_input += p.corpse_soil.exudate_labile_input
        Soil.Biogeochemistry.CORPSE.update_carbon_fluxes!(
            p,
            Y,
            model.corpse_soil.temporal_mode,
            model.corpse_soil.parameters,
            p.leaf_labile_input,
            p.leaf_recalcitrant_input,
            p.root_labile_input,
            p.root_recalcitrant_input,
            p.exudate_labile_input,
            p.litter_cwd_input,
        )
    end
    return update_boundary_fluxes!
end
