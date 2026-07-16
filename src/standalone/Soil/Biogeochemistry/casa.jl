module CASA

import StaticArrays
import ClimaCore

import ..Biogeochemistry
import ....ClimaLand

export CarbonNitrogen,
    CarbonOnly,
    CarbonTransferParameters,
    CASANitrogenParameters,
    CASASoilModel,
    CASASoilModelParameters,
    NitrogenPrescribedDrivers,
    PrescribedDrivers

const CarbonOnly = Biogeochemistry.CarbonOnly
const CarbonNitrogen = Biogeochemistry.CarbonNitrogen

"""
    CarbonTransferParameters{FT}

Carbon-use efficiencies and litter lignin fractions controlling transfers
among CASA litter and soil pools.
"""
Base.@kwdef struct CarbonTransferParameters{FT}
    lignin_leaf::FT
    lignin_wood::FT
    cue_metabolic_to_microbial::FT
    cue_structural_to_microbial::FT
    cue_structural_to_slow::FT
    cue_cwd_to_microbial::FT
    cue_cwd_to_slow::FT
    cue_microbial_to_slow::FT
    cue_microbial_to_passive::FT
    cue_slow_to_passive::FT
end

"""
    CASASoilModelParameters{FT}

Point parameters for the standalone CASA carbon soil model. Turnover rates use
inverse seconds; carbon pools and fluxes use kg C m⁻² and kg C m⁻² s⁻¹. A
`CASASoilModel` accepts either one parameter instance or a surface
`ClimaCore.Fields.Field` of instances for spatially varying soil and PFT
properties.
"""
Base.@kwdef struct CASASoilModelParameters{
    FT <: AbstractFloat,
    TP <: CarbonTransferParameters{FT},
}
    q10::FT
    litter_optimum::FT
    soil_optimum::FT
    porosity::FT
    clay::FT
    silt::FT
    freezing_temperature::FT
    litter_base_rates::NTuple{3, FT}
    soil_base_rates::NTuple{3, FT}
    transfers::TP
    is_cropland::Bool = false
    constant_moisture::Bool = is_cropland
end

Base.broadcastable(parameters::CASASoilModelParameters) = tuple(parameters)

"""
    CASANitrogenParameters{FT}

CASA nitrogen-cycling parameters. Mineral-N thresholds and litter maxima use
kg N m⁻² and kg C m⁻²; `leach_rate` uses s⁻¹.
"""
Base.@kwdef struct CASANitrogenParameters{FT <: AbstractFloat}
    limitation_minimum::FT
    limitation_maximum::FT
    maximum_fine_litter::FT
    maximum_cwd::FT
    soil_nitrogen_ratio_minimum::NTuple{3, FT}
    soil_nitrogen_ratio_maximum::NTuple{3, FT}
    loss_threshold::FT
    loss_fraction::FT
    leach_rate::FT
end

Base.broadcastable(parameters::CASANitrogenParameters) = tuple(parameters)

"""
    PrescribedDrivers

Time-dependent standalone drivers. Temperature is in K, liquid water is a
volumetric fraction, and litter inputs are in kg C m⁻² s⁻¹.
"""
struct PrescribedDrivers{T, W, M, S, C}
    soil_temperature::T
    liquid_water::W
    litter_metabolic::M
    litter_structural::S
    litter_cwd::C
end

"""
    NitrogenPrescribedDrivers

Time-dependent CASA nitrogen boundary drivers in kg N m⁻² s⁻¹. Plant
uptake is supplied by the plant component and is removed from mineral N.
"""
struct NitrogenPrescribedDrivers{M, S, C, D, F, U}
    litter_metabolic::M
    litter_structural::S
    litter_cwd::C
    deposition::D
    fixation::F
    plant_uptake::U
end

"""
    CASASoilModel{FT}(; parameters, drivers, domain)

Standalone CASA litter and soil carbon model using surface-integrated pools.
"""
struct CASASoilModel{FT, C, PS, NP, D, DR, NR} <:
       Biogeochemistry.AbstractSoilBiogeochemistryModel{FT}
    configuration::C
    parameters::PS
    nitrogen_parameters::NP
    domain::D
    drivers::DR
    nitrogen_drivers::NR
end

function CASASoilModel{FT}(;
    configuration = CarbonOnly(),
    parameters,
    nitrogen_parameters = nothing,
    drivers,
    nitrogen_drivers = nothing,
    domain::ClimaLand.Domains.AbstractDomain{FT} = ClimaLand.Domains.Point(;
        z_sfc = zero(FT),
    ),
) where {FT}
    @assert parameters isa CASASoilModelParameters{FT} || (
        parameters isa ClimaCore.Fields.Field &&
        eltype(parameters) <: CASASoilModelParameters{FT}
    ) "parameters must be CASA point parameters or a Field of CASA point parameters"
    @assert !(parameters isa ClimaCore.Fields.Field) ||
            axes(parameters) == domain.space.surface "spatial CASA parameters must use the model surface space"
    @assert configuration isa Biogeochemistry.AbstractNutrientMode
    if configuration isa CarbonNitrogen
        @assert nitrogen_parameters isa CASANitrogenParameters{FT} || (
            nitrogen_parameters isa ClimaCore.Fields.Field &&
            eltype(nitrogen_parameters) <: CASANitrogenParameters{FT}
        ) "nitrogen_parameters must be CASA nitrogen point parameters or a Field"
        @assert nitrogen_drivers isa NitrogenPrescribedDrivers
        @assert !(nitrogen_parameters isa ClimaCore.Fields.Field) ||
                axes(nitrogen_parameters) == domain.space.surface "spatial CASA nitrogen parameters must use the model surface space"
    else
        @assert isnothing(nitrogen_parameters)
        @assert isnothing(nitrogen_drivers)
    end
    args = (
        configuration,
        parameters,
        nitrogen_parameters,
        domain,
        drivers,
        nitrogen_drivers,
    )
    return CASASoilModel{FT, typeof.(args)...}(args...)
end

ClimaLand.name(::CASASoilModel) = :casa_soil

ClimaLand.prognostic_vars(::CASASoilModel{FT, CarbonOnly}) where {FT} = (
    :c_litter_metabolic,
    :c_litter_structural,
    :c_litter_cwd,
    :c_soil_microbial,
    :c_soil_slow,
    :c_soil_passive,
)
ClimaLand.prognostic_vars(::CASASoilModel{FT, CarbonNitrogen}) where {FT} = (
    :c_litter_metabolic,
    :c_litter_structural,
    :c_litter_cwd,
    :c_soil_microbial,
    :c_soil_slow,
    :c_soil_passive,
    :n_litter_metabolic,
    :n_litter_structural,
    :n_litter_cwd,
    :n_soil_microbial,
    :n_soil_slow,
    :n_soil_passive,
    :n_mineral,
)
ClimaLand.prognostic_types(::CASASoilModel{FT, CarbonOnly}) where {FT} =
    (FT, FT, FT, FT, FT, FT)
ClimaLand.prognostic_types(::CASASoilModel{FT, CarbonNitrogen}) where {FT} =
    ntuple(_ -> FT, 13)
ClimaLand.prognostic_domain_names(::CASASoilModel{FT, CarbonOnly}) where {FT} =
    (:surface, :surface, :surface, :surface, :surface, :surface)
ClimaLand.prognostic_domain_names(
    ::CASASoilModel{FT, CarbonNitrogen},
) where {FT} = ntuple(_ -> :surface, 13)

ClimaLand.auxiliary_vars(::CASASoilModel{FT, CarbonOnly}) where {FT} = (
    :soil_temperature,
    :relative_saturation,
    :temperature_factor,
    :moisture_factor,
    :litter_metabolic_input,
    :litter_structural_input,
    :litter_cwd_input,
    :carbon_fluxes,
)
ClimaLand.auxiliary_vars(::CASASoilModel{FT, CarbonNitrogen}) where {FT} = (
    :soil_temperature,
    :relative_saturation,
    :temperature_factor,
    :moisture_factor,
    :litter_metabolic_input,
    :litter_structural_input,
    :litter_cwd_input,
    :carbon_fluxes,
    :nitrogen_limitation,
    :nitrogen_litter_metabolic_input,
    :nitrogen_litter_structural_input,
    :nitrogen_litter_cwd_input,
    :nitrogen_deposition,
    :nitrogen_fixation,
    :nitrogen_plant_uptake,
    :nitrogen_fluxes,
)
ClimaLand.auxiliary_types(::CASASoilModel{FT, CarbonOnly}) where {FT} =
    (FT, FT, FT, FT, FT, FT, FT, StaticArrays.SVector{8, FT})
ClimaLand.auxiliary_types(::CASASoilModel{FT, CarbonNitrogen}) where {FT} = (
    FT,
    FT,
    FT,
    FT,
    FT,
    FT,
    FT,
    StaticArrays.SVector{8, FT},
    FT,
    FT,
    FT,
    FT,
    FT,
    FT,
    FT,
    StaticArrays.SVector{13, FT},
)
ClimaLand.auxiliary_domain_names(::CASASoilModel{FT, CarbonOnly}) where {FT} = (
    :surface,
    :surface,
    :surface,
    :surface,
    :surface,
    :surface,
    :surface,
    :surface,
)
ClimaLand.auxiliary_domain_names(
    ::CASASoilModel{FT, CarbonNitrogen},
) where {FT} = ntuple(_ -> :surface, 16)

"""
    legacy_root_fractions(root_decay, root_depth, layer_thicknesses)

Return the six CASA testbed root fractions. The legacy testbed treats each
layer thickness as a lower depth and the preceding thickness as its upper
depth, rather than accumulating layer thicknesses. This behavior is retained
for `LegacyDaily` parity.
"""
function legacy_root_fractions(
    root_decay,
    root_depth,
    layer_thicknesses::NTuple{N},
) where {N}
    total_root = one(root_decay) - exp(-root_decay * root_depth)
    return ntuple(N) do index
        layer_top = index == 1 ? zero(root_depth) : layer_thicknesses[index - 1]
        layer_bottom = layer_thicknesses[index]
        (
            exp(-root_decay * min(root_depth, layer_top)) -
            exp(-root_decay * min(root_depth, layer_bottom))
        ) / total_root
    end
end

"""
    root_weighted_mean(values, root_fractions)

Compute the CASA root-weighted mean of a fixed-size tuple of layer values.
"""
@inline function root_weighted_mean(
    values::NTuple{N},
    root_fractions::NTuple{N},
) where {N}
    return sum(map(*, values, root_fractions))
end

"""
    temperature_factor(q10, soil_temperature, freezing_temperature)

Return the CASA soil-temperature multiplier, normalized to one at 35 °C.
"""
@inline function temperature_factor(q10, soil_temperature, freezing_temperature)
    tenth = oftype(soil_temperature, 0.1)
    reference_temperature = oftype(soil_temperature, 35)
    return q10^(
        tenth *
        (soil_temperature - freezing_temperature - reference_temperature)
    )
end

"""
    moisture_factor(relative_saturation, is_cropland)

Return the CASA soil-moisture multiplier from water-filled pore space.
Cropland and cropland-mosaic points use the legacy constant value of one.
"""
@inline function moisture_factor(relative_saturation, is_cropland)
    optimum = oftype(relative_saturation, 0.55)
    wet_intercept = oftype(relative_saturation, 1.70)
    dry_intercept = oftype(relative_saturation, -0.007)
    dry_exponent = oftype(relative_saturation, 3.22)
    wet_exponent = oftype(relative_saturation, 6.6481)
    value =
        (
            (relative_saturation - wet_intercept) / (optimum - wet_intercept)
        )^wet_exponent *
        (
            (relative_saturation - dry_intercept) / (optimum - dry_intercept)
        )^dry_exponent
    return ifelse(is_cropland, one(relative_saturation), value)
end

"""
    environmental_factors(
        q10,
        litter_optimum,
        soil_optimum,
        soil_temperature,
        liquid_water,
        porosity,
        freezing_temperature,
        is_cropland,
    )

Compute the CASA temperature, moisture, litter, and soil decomposition
multipliers for one surface point.
"""
@inline function environmental_factors(
    q10,
    litter_optimum,
    soil_optimum,
    soil_temperature,
    liquid_water,
    porosity,
    freezing_temperature,
    is_cropland,
)
    relative_saturation = min(one(liquid_water), liquid_water / porosity)
    temperature =
        temperature_factor(q10, soil_temperature, freezing_temperature)
    moisture = moisture_factor(relative_saturation, is_cropland)
    return (;
        relative_saturation,
        temperature,
        moisture,
        litter = litter_optimum * temperature * moisture,
        soil = soil_optimum * temperature * moisture,
    )
end

"""
    decomposition_rates(
        litter_factor,
        soil_factor,
        litter_base_rates,
        soil_base_rates,
        lignin_leaf,
        clay,
        silt,
        is_cropland,
    )

Return daily decomposition fractions for the three CASA litter and soil pools.
Pool order is metabolic, structural, CWD and microbial, slow, passive.
"""
@inline function decomposition_rates(
    litter_factor,
    soil_factor,
    litter_base_rates,
    soil_base_rates,
    lignin_leaf,
    clay,
    silt,
    is_cropland,
)
    structural_lignin_factor = exp(-oftype(lignin_leaf, 3) * lignin_leaf)
    texture_factor = one(clay) - oftype(clay, 0.75) * (clay + silt)
    cropland_microbial =
        ifelse(is_cropland, oftype(soil_factor, 1.25), one(soil_factor))
    cropland_other =
        ifelse(is_cropland, oftype(soil_factor, 1.5), one(soil_factor))
    return (
        litter = (
            litter_factor * litter_base_rates[1],
            litter_factor * litter_base_rates[2] * structural_lignin_factor,
            litter_factor * litter_base_rates[3],
        ),
        soil = (
            soil_factor *
            soil_base_rates[1] *
            texture_factor *
            cropland_microbial,
            soil_factor * soil_base_rates[2] * cropland_other,
            soil_factor * soil_base_rates[3] * cropland_other,
        ),
    )
end

"""
    transfer_fractions(parameters, clay, silt)

Return the CASA fractions of decomposed carbon transferred among litter and
soil pools. Remainders are emitted as heterotrophic respiration.
"""
@inline function transfer_fractions(parameters, clay, silt)
    texture = clay + silt
    microbial_available = oftype(clay, 0.85) - oftype(clay, 0.68) * texture
    microbial_to_slow =
        parameters.cue_microbial_to_slow *
        microbial_available *
        (oftype(clay, 0.997) - oftype(clay, 0.032) * clay)
    microbial_to_passive =
        parameters.cue_microbial_to_passive *
        microbial_available *
        (oftype(clay, 0.003) + oftype(clay, 0.032) * clay)
    slow_to_passive =
        parameters.cue_slow_to_passive *
        (oftype(clay, 0.003) + oftype(clay, 0.009) * clay)
    return (
        metabolic_to_microbial = parameters.cue_metabolic_to_microbial,
        structural_to_microbial = parameters.cue_structural_to_microbial * (
            one(parameters.lignin_leaf) - parameters.lignin_leaf
        ),
        structural_to_slow = parameters.cue_structural_to_slow *
                             parameters.lignin_leaf,
        cwd_to_microbial = parameters.cue_cwd_to_microbial * (
            one(parameters.lignin_wood) - parameters.lignin_wood
        ),
        cwd_to_slow = parameters.cue_cwd_to_slow * parameters.lignin_wood,
        microbial_to_slow,
        microbial_to_passive,
        slow_to_passive,
    )
end

"""
    carbon_tendencies(
        litter,
        soil,
        litter_inputs,
        litter_rates,
        soil_rates,
        transfers,
    )

Compute the ordered one-day CASA litter and soil carbon changes and
heterotrophic respiration for one surface point.
"""
@inline function carbon_tendencies(
    litter,
    soil,
    litter_inputs,
    litter_rates,
    soil_rates,
    transfers,
)
    metabolic_loss = litter_rates[1] * litter[1]
    structural_loss = litter_rates[2] * litter[2]
    cwd_loss = litter_rates[3] * litter[3]
    microbial_loss = soil_rates[1] * soil[1]
    slow_loss = soil_rates[2] * soil[2]
    passive_loss = soil_rates[3] * soil[3]

    microbial_input =
        transfers.metabolic_to_microbial * metabolic_loss +
        transfers.structural_to_microbial * structural_loss +
        transfers.cwd_to_microbial * cwd_loss
    slow_input =
        transfers.structural_to_slow * structural_loss +
        transfers.cwd_to_slow * cwd_loss +
        transfers.microbial_to_slow * microbial_loss
    passive_input =
        transfers.microbial_to_passive * microbial_loss +
        transfers.slow_to_passive * slow_loss

    litter_respiration =
        (one(metabolic_loss) - transfers.metabolic_to_microbial) *
        metabolic_loss +
        (
            one(structural_loss) - transfers.structural_to_microbial -
            transfers.structural_to_slow
        ) * structural_loss +
        (one(cwd_loss) - transfers.cwd_to_microbial - transfers.cwd_to_slow) *
        cwd_loss
    soil_respiration =
        (
            one(microbial_loss) - transfers.microbial_to_slow -
            transfers.microbial_to_passive
        ) * microbial_loss +
        (one(slow_loss) - transfers.slow_to_passive) * slow_loss +
        passive_loss

    return (
        litter = (
            litter_inputs[1] - metabolic_loss,
            litter_inputs[2] - structural_loss,
            litter_inputs[3] - cwd_loss,
        ),
        soil = (
            microbial_input - microbial_loss,
            slow_input - slow_loss,
            passive_input - passive_loss,
        ),
        heterotrophic_respiration = litter_respiration + soil_respiration,
        passive_input,
    )
end

"""
    nitrogen_demand_fraction(mineral_nitrogen, minimum, maximum)

Return the unmodified linear mineral-N ramp used for plant N:C demand.
"""
@inline function nitrogen_demand_fraction(mineral_nitrogen, minimum, maximum)
    return clamp(
        (mineral_nitrogen - minimum) / (maximum - minimum),
        zero(mineral_nitrogen),
        one(mineral_nitrogen),
    )
end

"""
    nitrogen_limitation(
        mineral_nitrogen,
        minimum,
        maximum,
        litter_carbon,
        maximum_fine_litter,
        maximum_cwd,
    )

Return the legacy CASA linear mineral-N limitation multiplier. Excess litter
removes the limitation, matching `casa_xkN2`.
"""
@inline function nitrogen_limitation(
    mineral_nitrogen,
    minimum,
    maximum,
    litter_carbon,
    maximum_fine_litter,
    maximum_cwd,
)
    value = nitrogen_demand_fraction(mineral_nitrogen, minimum, maximum)
    excess_litter = sum(litter_carbon) > maximum_fine_litter + maximum_cwd
    return ifelse(excess_litter, one(value), value)
end

"""
    new_soil_nitrogen_ratios(
        mineral_nitrogen,
        minimum_ratios,
        maximum_ratios,
        limitation_maximum,
    )

Return destination-pool N:C ratios for newly formed CASA soil organic matter.
"""
@inline function new_soil_nitrogen_ratios(
    mineral_nitrogen,
    minimum_ratios,
    maximum_ratios,
    limitation_maximum,
)
    fraction =
        max(zero(mineral_nitrogen), mineral_nitrogen) / limitation_maximum
    return if mineral_nitrogen < limitation_maximum
        minimum_ratios .+ (maximum_ratios .- minimum_ratios) .* fraction
    else
        maximum_ratios
    end
end

"""
    nitrogen_tendencies(
        litter_carbon,
        soil_carbon,
        litter_nitrogen,
        soil_nitrogen,
        litter_nitrogen_inputs,
        litter_rates,
        soil_rates,
        transfers,
        soil_nitrogen_ratios,
        mineral_nitrogen,
        deposition,
        fixation,
        uptake,
        loss_fraction,
        leach_fraction,
        soil_temperature,
        loss_threshold_nitrogen = 2,
    )

Compute CASA organic- and mineral-N changes for one point and one rate period.
Plant uptake is a boundary flux supplied by the plant component.
"""
@inline function nitrogen_tendencies(
    litter_carbon,
    soil_carbon,
    litter_nitrogen,
    soil_nitrogen,
    litter_nitrogen_inputs,
    litter_rates,
    soil_rates,
    transfers,
    soil_nitrogen_ratios,
    mineral_nitrogen,
    deposition,
    fixation,
    uptake,
    loss_fraction,
    leach_fraction,
    soil_temperature,
    loss_threshold_nitrogen = oftype(mineral_nitrogen, 2),
)
    litter_carbon_losses = (
        litter_rates[1] * litter_carbon[1],
        litter_rates[2] * litter_carbon[2],
        litter_rates[3] * litter_carbon[3],
    )
    soil_carbon_losses = (
        soil_rates[1] * soil_carbon[1],
        soil_rates[2] * soil_carbon[2],
        soil_rates[3] * soil_carbon[3],
    )
    soil_nitrogen_inputs = (
        soil_nitrogen_ratios[1] * (
            transfers.metabolic_to_microbial * litter_carbon_losses[1] +
            transfers.structural_to_microbial * litter_carbon_losses[2] +
            transfers.cwd_to_microbial * litter_carbon_losses[3]
        ),
        soil_nitrogen_ratios[2] * (
            transfers.structural_to_slow * litter_carbon_losses[2] +
            transfers.cwd_to_slow * litter_carbon_losses[3] +
            transfers.microbial_to_slow * soil_carbon_losses[1]
        ),
        soil_nitrogen_ratios[3] * (
            transfers.microbial_to_passive * soil_carbon_losses[1] +
            transfers.slow_to_passive * soil_carbon_losses[2]
        ),
    )
    litter_nitrogen_losses = (
        litter_rates[1] * litter_nitrogen[1],
        litter_rates[2] * litter_nitrogen[2],
        litter_rates[3] * litter_nitrogen[3],
    )
    soil_nitrogen_losses = (
        soil_rates[1] * soil_nitrogen[1],
        soil_rates[2] * soil_nitrogen[2],
        soil_rates[3] * soil_nitrogen[3],
    )
    litter_mineralization = sum(litter_nitrogen_losses)
    soil_mineralization = sum(soil_nitrogen_losses)
    soil_immobilization = -sum(soil_nitrogen_inputs)
    net_mineralization =
        litter_mineralization + soil_mineralization + soil_immobilization

    threshold_temperature = oftype(soil_temperature, 273.12)
    limited = !(
        mineral_nitrogen > loss_threshold_nitrogen &&
        soil_temperature > threshold_temperature
    )
    mineral_scale = ifelse(
        limited,
        max(zero(mineral_nitrogen), mineral_nitrogen / loss_threshold_nitrogen),
        one(mineral_nitrogen),
    )
    gaseous_loss =
        loss_fraction *
        max(zero(net_mineralization), net_mineralization) *
        mineral_scale
    leaching =
        leach_fraction *
        max(zero(mineral_nitrogen), mineral_nitrogen) *
        mineral_scale

    return (
        litter = (
            litter_nitrogen_inputs[1] - litter_nitrogen_losses[1],
            litter_nitrogen_inputs[2] - litter_nitrogen_losses[2],
            litter_nitrogen_inputs[3] - litter_nitrogen_losses[3],
        ),
        soil = (
            soil_nitrogen_inputs[1] - soil_nitrogen_losses[1],
            soil_nitrogen_inputs[2] - soil_nitrogen_losses[2],
            soil_nitrogen_inputs[3] - soil_nitrogen_losses[3],
        ),
        mineral = net_mineralization + deposition + fixation - gaseous_loss -
                  leaching - uptake,
        litter_mineralization,
        soil_mineralization,
        soil_immobilization,
        net_mineralization,
        gaseous_loss,
        leaching,
    )
end

@inline function carbon_fluxes(
    parameters,
    c_litter_metabolic,
    c_litter_structural,
    c_litter_cwd,
    c_soil_microbial,
    c_soil_slow,
    c_soil_passive,
    litter_metabolic_input,
    litter_structural_input,
    litter_cwd_input,
    temperature,
    moisture,
    nitrogen_scalar = one(temperature),
)
    litter_factor =
        parameters.litter_optimum * temperature * moisture * nitrogen_scalar
    soil_factor = parameters.soil_optimum * temperature * moisture
    rates = decomposition_rates(
        litter_factor,
        soil_factor,
        parameters.litter_base_rates,
        parameters.soil_base_rates,
        parameters.transfers.lignin_leaf,
        parameters.clay,
        parameters.silt,
        parameters.is_cropland,
    )
    transfers = transfer_fractions(
        parameters.transfers,
        parameters.clay,
        parameters.silt,
    )
    tendencies = carbon_tendencies(
        (c_litter_metabolic, c_litter_structural, c_litter_cwd),
        (c_soil_microbial, c_soil_slow, c_soil_passive),
        (litter_metabolic_input, litter_structural_input, litter_cwd_input),
        rates.litter,
        rates.soil,
        transfers,
    )
    return StaticArrays.SVector(
        tendencies.litter...,
        tendencies.soil...,
        tendencies.heterotrophic_respiration,
        tendencies.passive_input,
    )
end

@inline function nitrogen_fluxes(
    parameters,
    nitrogen_parameters,
    litter_carbon,
    soil_carbon,
    litter_nitrogen,
    soil_nitrogen,
    mineral_nitrogen,
    litter_nitrogen_inputs,
    deposition,
    fixation,
    uptake,
    temperature,
    moisture,
    nitrogen_scalar,
    soil_temperature,
)
    rates = decomposition_rates(
        parameters.litter_optimum * temperature * moisture * nitrogen_scalar,
        parameters.soil_optimum * temperature * moisture,
        parameters.litter_base_rates,
        parameters.soil_base_rates,
        parameters.transfers.lignin_leaf,
        parameters.clay,
        parameters.silt,
        parameters.is_cropland,
    )
    transfers = transfer_fractions(
        parameters.transfers,
        parameters.clay,
        parameters.silt,
    )
    ratios = new_soil_nitrogen_ratios(
        mineral_nitrogen,
        nitrogen_parameters.soil_nitrogen_ratio_minimum,
        nitrogen_parameters.soil_nitrogen_ratio_maximum,
        nitrogen_parameters.limitation_maximum,
    )
    tendencies = nitrogen_tendencies(
        litter_carbon,
        soil_carbon,
        litter_nitrogen,
        soil_nitrogen,
        litter_nitrogen_inputs,
        rates.litter,
        rates.soil,
        transfers,
        ratios,
        mineral_nitrogen,
        deposition,
        fixation,
        uptake,
        nitrogen_parameters.loss_fraction,
        nitrogen_parameters.leach_rate,
        soil_temperature,
        nitrogen_parameters.loss_threshold,
    )
    return StaticArrays.SVector(
        tendencies.litter...,
        tendencies.soil...,
        tendencies.mineral,
        tendencies.litter_mineralization,
        tendencies.soil_mineralization,
        tendencies.soil_immobilization,
        tendencies.net_mineralization,
        tendencies.gaseous_loss,
        tendencies.leaching,
    )
end

@inline parameter_relative_saturation(parameters, liquid_water) =
    min(one(liquid_water), liquid_water / parameters.porosity)

@inline parameter_temperature_factor(parameters, soil_temperature) =
    temperature_factor(
        parameters.q10,
        soil_temperature,
        parameters.freezing_temperature,
    )

@inline parameter_moisture_factor(parameters, relative_saturation) =
    moisture_factor(relative_saturation, parameters.constant_moisture)

@inline parameter_nitrogen_limitation(
    parameters,
    mineral_nitrogen,
    litter_metabolic,
    litter_structural,
    litter_cwd,
) = nitrogen_limitation(
    mineral_nitrogen,
    parameters.limitation_minimum,
    parameters.limitation_maximum,
    (litter_metabolic, litter_structural, litter_cwd),
    parameters.maximum_fine_litter,
    parameters.maximum_cwd,
)

@inline function point_nitrogen_fluxes(
    parameters,
    nitrogen_parameters,
    c_litter_metabolic,
    c_litter_structural,
    c_litter_cwd,
    c_soil_microbial,
    c_soil_slow,
    c_soil_passive,
    n_litter_metabolic,
    n_litter_structural,
    n_litter_cwd,
    n_soil_microbial,
    n_soil_slow,
    n_soil_passive,
    n_mineral,
    n_litter_metabolic_input,
    n_litter_structural_input,
    n_litter_cwd_input,
    deposition,
    fixation,
    uptake,
    temperature,
    moisture,
    nitrogen_scalar,
    soil_temperature,
)
    return nitrogen_fluxes(
        parameters,
        nitrogen_parameters,
        (c_litter_metabolic, c_litter_structural, c_litter_cwd),
        (c_soil_microbial, c_soil_slow, c_soil_passive),
        (n_litter_metabolic, n_litter_structural, n_litter_cwd),
        (n_soil_microbial, n_soil_slow, n_soil_passive),
        n_mineral,
        (
            n_litter_metabolic_input,
            n_litter_structural_input,
            n_litter_cwd_input,
        ),
        deposition,
        fixation,
        uptake,
        temperature,
        moisture,
        nitrogen_scalar,
        soil_temperature,
    )
end

function ClimaLand.make_update_aux(
    model::CASASoilModel{FT, CarbonOnly},
) where {FT}
    function update_aux!(p, Y, t)
        parameters = model.parameters
        soil_temperature = model.drivers.soil_temperature(t)
        liquid_water = model.drivers.liquid_water(t)
        litter_metabolic = model.drivers.litter_metabolic(t)
        litter_structural = model.drivers.litter_structural(t)
        litter_cwd = model.drivers.litter_cwd(t)

        @. p.casa_soil.soil_temperature = soil_temperature
        @. p.casa_soil.relative_saturation =
            parameter_relative_saturation(parameters, liquid_water)
        @. p.casa_soil.temperature_factor =
            parameter_temperature_factor(parameters, soil_temperature)
        @. p.casa_soil.moisture_factor = parameter_moisture_factor(
            parameters,
            p.casa_soil.relative_saturation,
        )
        update_carbon_fluxes!(
            p,
            Y,
            parameters,
            litter_metabolic,
            litter_structural,
            litter_cwd,
        )
    end
    return update_aux!
end


function ClimaLand.make_update_aux(
    model::CASASoilModel{FT, CarbonNitrogen},
) where {FT}
    function update_aux!(p, Y, t)
        parameters = model.parameters
        nitrogen_parameters = model.nitrogen_parameters
        soil_temperature = model.drivers.soil_temperature(t)
        liquid_water = model.drivers.liquid_water(t)
        litter_metabolic = model.drivers.litter_metabolic(t)
        litter_structural = model.drivers.litter_structural(t)
        litter_cwd = model.drivers.litter_cwd(t)
        nitrogen_litter_metabolic = model.nitrogen_drivers.litter_metabolic(t)
        nitrogen_litter_structural = model.nitrogen_drivers.litter_structural(t)
        nitrogen_litter_cwd = model.nitrogen_drivers.litter_cwd(t)
        nitrogen_deposition = model.nitrogen_drivers.deposition(t)
        nitrogen_fixation = model.nitrogen_drivers.fixation(t)
        nitrogen_plant_uptake = model.nitrogen_drivers.plant_uptake(t)

        @. p.casa_soil.soil_temperature = soil_temperature
        @. p.casa_soil.relative_saturation =
            parameter_relative_saturation(parameters, liquid_water)
        @. p.casa_soil.temperature_factor =
            parameter_temperature_factor(parameters, soil_temperature)
        @. p.casa_soil.moisture_factor = parameter_moisture_factor(
            parameters,
            p.casa_soil.relative_saturation,
        )
        @. p.casa_soil.nitrogen_limitation = parameter_nitrogen_limitation(
            nitrogen_parameters,
            Y.casa_soil.n_mineral,
            Y.casa_soil.c_litter_metabolic,
            Y.casa_soil.c_litter_structural,
            Y.casa_soil.c_litter_cwd,
        )
        update_carbon_fluxes!(
            p,
            Y,
            parameters,
            litter_metabolic,
            litter_structural,
            litter_cwd,
            p.casa_soil.nitrogen_limitation,
        )
        update_nitrogen_fluxes!(
            p,
            Y,
            parameters,
            nitrogen_parameters,
            nitrogen_litter_metabolic,
            nitrogen_litter_structural,
            nitrogen_litter_cwd,
            nitrogen_deposition,
            nitrogen_fixation,
            nitrogen_plant_uptake,
        )
    end
    return update_aux!
end

function update_carbon_fluxes!(
    p,
    Y,
    parameters,
    litter_metabolic,
    litter_structural,
    litter_cwd,
    nitrogen_scalar = one(eltype(litter_metabolic)),
)
    @. p.casa_soil.litter_metabolic_input = litter_metabolic
    @. p.casa_soil.litter_structural_input = litter_structural
    @. p.casa_soil.litter_cwd_input = litter_cwd
    @. p.casa_soil.carbon_fluxes = carbon_fluxes(
        parameters,
        Y.casa_soil.c_litter_metabolic,
        Y.casa_soil.c_litter_structural,
        Y.casa_soil.c_litter_cwd,
        Y.casa_soil.c_soil_microbial,
        Y.casa_soil.c_soil_slow,
        Y.casa_soil.c_soil_passive,
        p.casa_soil.litter_metabolic_input,
        p.casa_soil.litter_structural_input,
        p.casa_soil.litter_cwd_input,
        p.casa_soil.temperature_factor,
        p.casa_soil.moisture_factor,
        nitrogen_scalar,
    )
    return nothing
end

function update_nitrogen_fluxes!(
    p,
    Y,
    parameters,
    nitrogen_parameters,
    litter_metabolic,
    litter_structural,
    litter_cwd,
    deposition,
    fixation,
    uptake,
)
    @. p.casa_soil.nitrogen_litter_metabolic_input = litter_metabolic
    @. p.casa_soil.nitrogen_litter_structural_input = litter_structural
    @. p.casa_soil.nitrogen_litter_cwd_input = litter_cwd
    @. p.casa_soil.nitrogen_deposition = deposition
    @. p.casa_soil.nitrogen_fixation = fixation
    @. p.casa_soil.nitrogen_plant_uptake = uptake
    @. p.casa_soil.nitrogen_fluxes = point_nitrogen_fluxes(
        parameters,
        nitrogen_parameters,
        Y.casa_soil.c_litter_metabolic,
        Y.casa_soil.c_litter_structural,
        Y.casa_soil.c_litter_cwd,
        Y.casa_soil.c_soil_microbial,
        Y.casa_soil.c_soil_slow,
        Y.casa_soil.c_soil_passive,
        Y.casa_soil.n_litter_metabolic,
        Y.casa_soil.n_litter_structural,
        Y.casa_soil.n_litter_cwd,
        Y.casa_soil.n_soil_microbial,
        Y.casa_soil.n_soil_slow,
        Y.casa_soil.n_soil_passive,
        Y.casa_soil.n_mineral,
        p.casa_soil.nitrogen_litter_metabolic_input,
        p.casa_soil.nitrogen_litter_structural_input,
        p.casa_soil.nitrogen_litter_cwd_input,
        p.casa_soil.nitrogen_deposition,
        p.casa_soil.nitrogen_fixation,
        p.casa_soil.nitrogen_plant_uptake,
        p.casa_soil.temperature_factor,
        p.casa_soil.moisture_factor,
        p.casa_soil.nitrogen_limitation,
        p.casa_soil.soil_temperature,
    )
    return nothing
end

function ClimaLand.make_compute_exp_tendency(
    ::CASASoilModel{FT, CarbonOnly},
) where {FT}
    function compute_exp_tendency!(dY, Y, p, t)
        fluxes = p.casa_soil.carbon_fluxes
        @. dY.casa_soil.c_litter_metabolic = getindex(fluxes, 1)
        @. dY.casa_soil.c_litter_structural = getindex(fluxes, 2)
        @. dY.casa_soil.c_litter_cwd = getindex(fluxes, 3)
        @. dY.casa_soil.c_soil_microbial = getindex(fluxes, 4)
        @. dY.casa_soil.c_soil_slow = getindex(fluxes, 5)
        @. dY.casa_soil.c_soil_passive = getindex(fluxes, 6)
    end
    return compute_exp_tendency!
end


function ClimaLand.make_compute_exp_tendency(
    ::CASASoilModel{FT, CarbonNitrogen},
) where {FT}
    function compute_exp_tendency!(dY, Y, p, t)
        carbon = p.casa_soil.carbon_fluxes
        nitrogen = p.casa_soil.nitrogen_fluxes
        @. dY.casa_soil.c_litter_metabolic = getindex(carbon, 1)
        @. dY.casa_soil.c_litter_structural = getindex(carbon, 2)
        @. dY.casa_soil.c_litter_cwd = getindex(carbon, 3)
        @. dY.casa_soil.c_soil_microbial = getindex(carbon, 4)
        @. dY.casa_soil.c_soil_slow = getindex(carbon, 5)
        @. dY.casa_soil.c_soil_passive = getindex(carbon, 6)
        @. dY.casa_soil.n_litter_metabolic = getindex(nitrogen, 1)
        @. dY.casa_soil.n_litter_structural = getindex(nitrogen, 2)
        @. dY.casa_soil.n_litter_cwd = getindex(nitrogen, 3)
        @. dY.casa_soil.n_soil_microbial = getindex(nitrogen, 4)
        @. dY.casa_soil.n_soil_slow = getindex(nitrogen, 5)
        @. dY.casa_soil.n_soil_passive = getindex(nitrogen, 6)
        @. dY.casa_soil.n_mineral = getindex(nitrogen, 7)
    end
    return compute_exp_tendency!
end

end
