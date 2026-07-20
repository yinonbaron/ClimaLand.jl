module CASA

import StaticArrays
import ClimaCore

import ...ClimaLand
import ...Soil.Biogeochemistry: CarbonNitrogen, CarbonOnly

export CarbonNitrogen,
    CarbonOnly,
    AbstractTemporalMode,
    CASAPlantModel,
    CASAPlantNitrogenParameters,
    CASAPlantModelParameters,
    ContinuousRate,
    LegacyDaily,
    NitrogenPrescribedDrivers,
    PrescribedDrivers,
    allocation_fractions,
    carbon_fluxes,
    leaf_area_index,
    mimics_litter_quality,
    mimics_plant_litter_fractions,
    nitrogen_fluxes,
    nitrogen_supply,
    nitrogen_uptake,
    plant_litter_fractions,
    respiration_fluxes,
    senescence_rates,
    temperature_response

"Compile-time temporal formulation for the CASA plant model."
abstract type AbstractTemporalMode end

"Exact ordered one-day map used by the reference Fortran testbed."
struct LegacyDaily <: AbstractTemporalMode end

"Timestep-independent, simultaneous CASA plant ordinary differential equation."
struct ContinuousRate <: AbstractTemporalMode end

Base.broadcastable(mode::AbstractTemporalMode) = tuple(mode)

"""
    CASAPlantModelParameters{FT}

Carbon-only CASA plant point parameters. Rates use inverse seconds, carbon
stocks use kg C m⁻², and nitrogen stocks use kg N m⁻². The fixed plant
nitrogen stocks preserve the testbed's carbon-only respiration semantics. A
`CASAPlantModel` accepts either one parameter instance or a surface
`ClimaCore.Fields.Field` of instances.
"""
Base.@kwdef struct CASAPlantModelParameters{FT <: AbstractFloat}
    allocation::NTuple{3, FT}
    turnover_rates::NTuple{3, FT}
    maintenance_rates::NTuple{3, FT}
    plant_nitrogen::NTuple{3, FT}
    plant_nitrogen_ratio::NTuple{3, FT} = ntuple(_ -> zero(FT), 3)
    leaf_phosphorus_to_nitrogen::FT
    labile_loss_rate::FT
    specific_leaf_area::FT
    minimum_leaf_area_index::FT
    maximum_leaf_area_index::FT
    shedding_temperature::FT
    cold_turnover_maximum::FT
    cold_turnover_exponent::FT
    drought_turnover_maximum::FT
    drought_turnover_exponent::FT
    freezing_temperature::FT
    root_exudate_fraction::FT = zero(FT)
    nonwoody::Bool = false
end

@inline function carbon_only_plant_nitrogen(
    parameters,
    c_leaf,
    c_wood,
    c_fine_root,
)
    carbon = (c_leaf, c_wood, c_fine_root)
    return ntuple(Val(3)) do index
        ratio = parameters.plant_nitrogen_ratio[index]
        ifelse(
            iszero(ratio),
            parameters.plant_nitrogen[index],
            carbon[index] * ratio,
        )
    end
end

@inline function mimics_lignin_nitrogen_ratios(parameters, carbon, nitrogen)
    small = oftype(carbon[1], 1e-10)
    return ntuple(Val(3)) do index
        if index == 2
            inv(parameters.nitrogen_ratio_minimum[index]) *
            parameters.lignin_fraction[index]
        else
            carbon_nitrogen = min(
                carbon[index] / max(small, nitrogen[index]),
                inv(parameters.nitrogen_ratio_minimum[index]),
            )
            carbon_nitrogen / parameters.nitrogen_fraction_to_litter[index] *
            parameters.lignin_fraction[index]
        end
    end
end


"""
    mimics_plant_litter_fractions(parameters, carbon, nitrogen)

Return the MIMICS-CN leaf and fine-root metabolic fractions. This variant
caps plant C:N at the configured maximum before calculating lignin:N, matching
`mimics_coeffplant`.
"""
@inline function mimics_plant_litter_fractions(parameters, carbon, nitrogen)
    lignin_to_nitrogen =
        mimics_lignin_nitrogen_ratios(parameters, carbon, nitrogen)
    metabolic(value) = max(
        oftype(value, 0.001),
        oftype(value, 0.75) *
        (oftype(value, 0.85) - oftype(value, 0.013) * value),
    )
    return (metabolic(lignin_to_nitrogen[1]), metabolic(lignin_to_nitrogen[3]))
end


"""
    mimics_litter_quality(
        parameters,
        carbon,
        nitrogen,
        leaf_turnover,
        root_turnover,
        cwd_to_structural,
    )

Return the input-weighted MIMICS metabolic-litter quality used by its kinetic
and microbial C:N modifiers.
"""
@inline function mimics_litter_quality(
    parameters,
    carbon,
    nitrogen,
    leaf_turnover,
    root_turnover,
    cwd_to_structural,
)
    ratios = mimics_lignin_nitrogen_ratios(parameters, carbon, nitrogen)
    total = leaf_turnover + root_turnover + cwd_to_structural
    average = min(
        oftype(total, 40),
        (
            ratios[1] * leaf_turnover +
            ratios[3] * root_turnover +
            ratios[2] * cwd_to_structural
        ) / max(oftype(total, 0.001 / 1000 / 86400), total),
    )
    return oftype(total, 0.75) *
           (oftype(total, 0.85) - oftype(total, 0.013) * average)
end

Base.broadcastable(parameters::CASAPlantModelParameters) = tuple(parameters)

"""
    CASAPlantNitrogenParameters{FT}

CASA plant nitrogen parameters. Ratios are N:C, mineral thresholds use
kg N m⁻², and `mineral_half_saturation` uses kg N m⁻².
"""
Base.@kwdef struct CASAPlantNitrogenParameters{FT <: AbstractFloat}
    nitrogen_ratio_minimum::NTuple{3, FT}
    nitrogen_ratio_maximum::NTuple{3, FT}
    nitrogen_fraction_to_litter::NTuple{3, FT}
    lignin_fraction::NTuple{3, FT}
    structural_litter_nitrogen_ratio::FT
    limitation_minimum::FT
    limitation_maximum::FT
    mineral_half_saturation::FT
end

Base.broadcastable(parameters::CASAPlantNitrogenParameters) = tuple(parameters)

@inline root_exudate_fraction(parameters) = parameters.root_exudate_fraction

"""
    PrescribedDrivers

Time-dependent carbon-only drivers. GPP uses kg C m⁻² s⁻¹,
temperatures use K, water stress lies in `[0, 1]`, and phenology phase follows
the testbed values 0--3. `npp_scalar` and `labile_fraction` are dimensionless.
"""
struct PrescribedDrivers{G, A, S, W, P, N, L}
    gross_primary_production::G
    air_temperature::A
    soil_temperature::S
    water_stress::W
    phenology_phase::P
    npp_scalar::N
    labile_fraction::L
end

"""
    NitrogenPrescribedDrivers

Time-dependent standalone nitrogen boundary values. Mineral N uses kg N m⁻²;
the demand fraction is the raw mineral-N ramp and the limitation is the
possibly litter-cap-overridden CASA multiplier.
"""
struct NitrogenPrescribedDrivers{M, D, L}
    mineral_nitrogen::M
    demand_fraction::D
    limitation::L
end

"""
    CASAPlantModel{FT}(; parameters, drivers, domain, temporal_mode)

Standalone CASA plant-carbon model with leaf, wood, fine-root, and labile
surface pools. `temporal_mode = LegacyDaily()` preserves the ordered reference
map; `ContinuousRate()` selects a simultaneous, timestep-independent ODE.
"""
struct CASAPlantModel{FT, C, PS, NP, D, DR, NR, TM} <:
       ClimaLand.AbstractExpModel{FT}
    configuration::C
    parameters::PS
    nitrogen_parameters::NP
    domain::D
    drivers::DR
    nitrogen_drivers::NR
    temporal_mode::TM
end

function CASAPlantModel{FT}(;
    configuration = CarbonOnly(),
    parameters,
    nitrogen_parameters = nothing,
    drivers,
    nitrogen_drivers = nothing,
    domain::ClimaLand.Domains.AbstractDomain{FT} = ClimaLand.Domains.Point(;
        z_sfc = zero(FT),
    ),
    temporal_mode::AbstractTemporalMode = LegacyDaily(),
) where {FT}
    @assert parameters isa CASAPlantModelParameters{FT} || (
        parameters isa ClimaCore.Fields.Field &&
        eltype(parameters) <: CASAPlantModelParameters{FT}
    ) "parameters must be CASA plant point parameters or a Field of CASA plant point parameters"
    @assert !(parameters isa ClimaCore.Fields.Field) ||
            axes(parameters) == domain.space.surface "spatial CASA plant parameters must use the model surface space"
    if configuration isa CarbonNitrogen
        @assert nitrogen_parameters isa CASAPlantNitrogenParameters{FT} || (
            nitrogen_parameters isa ClimaCore.Fields.Field &&
            eltype(nitrogen_parameters) <: CASAPlantNitrogenParameters{FT}
        ) "nitrogen_parameters must be CASA plant nitrogen point parameters or a Field"
        @assert nitrogen_drivers isa NitrogenPrescribedDrivers
        @assert !(nitrogen_parameters isa ClimaCore.Fields.Field) ||
                axes(nitrogen_parameters) == domain.space.surface "spatial CASA plant nitrogen parameters must use the model surface space"
    else
        @assert configuration isa CarbonOnly
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
        temporal_mode,
    )
    return CASAPlantModel{FT, typeof.(args)...}(args...)
end

@inline function legacy_bounded_tendency(state, tendency)
    seconds_per_day = oftype(state, 86400)
    next_state = max(zero(state), state + seconds_per_day * tendency)
    return (next_state - state) / seconds_per_day
end

ClimaLand.name(::CASAPlantModel) = :casa_plant

ClimaLand.prognostic_vars(::CASAPlantModel{FT, CarbonOnly}) where {FT} =
    (:c_leaf, :c_wood, :c_fine_root, :c_labile)
ClimaLand.prognostic_vars(::CASAPlantModel{FT, CarbonNitrogen}) where {FT} =
    (:c_leaf, :c_wood, :c_fine_root, :c_labile, :n_leaf, :n_wood, :n_fine_root)
ClimaLand.prognostic_types(::CASAPlantModel{FT, CarbonOnly}) where {FT} =
    (FT, FT, FT, FT)
ClimaLand.prognostic_types(::CASAPlantModel{FT, CarbonNitrogen}) where {FT} =
    ntuple(_ -> FT, 7)
ClimaLand.prognostic_domain_names(::CASAPlantModel{FT, CarbonOnly}) where {FT} =
    (:surface, :surface, :surface, :surface)
ClimaLand.prognostic_domain_names(
    ::CASAPlantModel{FT, CarbonNitrogen},
) where {FT} = ntuple(_ -> :surface, 7)

ClimaLand.auxiliary_vars(::CASAPlantModel{FT, CarbonOnly}) where {FT} = (
    :gross_primary_production,
    :air_temperature,
    :soil_temperature,
    :water_stress,
    :phenology_phase,
    :carbon_fluxes,
)
ClimaLand.auxiliary_vars(::CASAPlantModel{FT, CarbonNitrogen}) where {FT} = (
    :gross_primary_production,
    :air_temperature,
    :soil_temperature,
    :water_stress,
    :phenology_phase,
    :carbon_fluxes,
    :mineral_nitrogen,
    :nitrogen_demand_fraction,
    :nitrogen_limitation,
    :nitrogen_fluxes,
)
ClimaLand.auxiliary_types(::CASAPlantModel{FT, CarbonOnly}) where {FT} =
    (FT, FT, FT, FT, FT, StaticArrays.SVector{21, FT})
ClimaLand.auxiliary_types(::CASAPlantModel{FT, CarbonNitrogen}) where {FT} = (
    FT,
    FT,
    FT,
    FT,
    FT,
    StaticArrays.SVector{21, FT},
    FT,
    FT,
    FT,
    StaticArrays.SVector{12, FT},
)
ClimaLand.auxiliary_domain_names(::CASAPlantModel{FT, CarbonOnly}) where {FT} =
    (:surface, :surface, :surface, :surface, :surface, :surface)
ClimaLand.auxiliary_domain_names(
    ::CASAPlantModel{FT, CarbonNitrogen},
) where {FT} = ntuple(_ -> :surface, 10)

"""
    temperature_response(temperature, freezing_temperature)

Return the testbed's Arrhenius-like plant respiration multiplier.
"""
@inline function temperature_response(temperature, freezing_temperature)
    coefficient = oftype(temperature, 308.56)
    reference = oftype(temperature, 56.02)
    offset = oftype(temperature, 46.02)
    return exp(
        coefficient *
        (inv(reference) - inv(temperature + offset - freezing_temperature)),
    )
end

"""
    respiration_fluxes(parameters, gpp, air_temperature, soil_temperature,
                       c_wood, c_fine_root)

Compute CASA wood and fine-root maintenance respiration, growth respiration,
and NPP. Leaf maintenance respiration is zero in the pinned testbed routine.
"""
@inline function respiration_fluxes(
    parameters,
    gpp,
    air_temperature,
    soil_temperature,
    c_wood,
    c_fine_root,
    plant_nitrogen = parameters.plant_nitrogen,
)
    threshold_temperature = oftype(air_temperature, 250)
    pool_threshold = oftype(c_wood, 1e-9)
    air_factor =
        temperature_response(air_temperature, parameters.freezing_temperature)
    soil_factor =
        temperature_response(soil_temperature, parameters.freezing_temperature)
    wood = parameters.maintenance_rates[2] * plant_nitrogen[2] * air_factor
    root = parameters.maintenance_rates[3] * plant_nitrogen[3] * soil_factor
    wood = ifelse(
        air_temperature > threshold_temperature && c_wood > pool_threshold,
        wood,
        zero(wood),
    )
    root = ifelse(
        soil_temperature > threshold_temperature &&
        c_fine_root > pool_threshold,
        root,
        zero(root),
    )
    maintenance = wood + root
    p_to_n = parameters.leaf_phosphorus_to_nitrogen
    growth_efficiency =
        oftype(gpp, 0.65) +
        oftype(gpp, 0.2) * p_to_n / (p_to_n + inv(oftype(gpp, 15)))
    growth = (one(gpp) - growth_efficiency) * max(zero(gpp), gpp - maintenance)
    return (
        wood = wood,
        fine_root = root,
        maintenance = maintenance,
        growth = growth,
        npp = gpp - maintenance - growth,
    )
end

"""
    leaf_area_index(parameters, leaf_carbon)

Convert leaf carbon to the prognostic CASA LAI and apply the PFT bounds.
"""
@inline function leaf_area_index(parameters, leaf_carbon)
    return clamp(
        parameters.specific_leaf_area * leaf_carbon,
        parameters.minimum_leaf_area_index,
        parameters.maximum_leaf_area_index,
    )
end

@inline function normalize_fractions(fractions)
    total = sum(fractions)
    if total > zero(total)
        return (
            fractions[1] / total,
            fractions[2] / total,
            fractions[3] / total,
        )
    else
        return (one(total), zero(total), zero(total))
    end
end

"""
    plant_litter_fractions(parameters, carbon, nitrogen)

Return metabolic litter fractions for leaf and fine-root turnover using the
legacy lignin-to-nitrogen relationship. Wood turnover is routed to CWD.
"""
@inline function plant_litter_fractions(parameters, carbon, nitrogen)
    floor = oftype(carbon[1], 1e-10)
    leaf_lignin_to_nitrogen =
        carbon[1] /
        (max(floor, nitrogen[1]) * parameters.nitrogen_fraction_to_litter[1]) *
        parameters.lignin_fraction[1]
    root_lignin_to_nitrogen =
        carbon[3] /
        (max(floor, nitrogen[3]) * parameters.nitrogen_fraction_to_litter[3]) *
        parameters.lignin_fraction[3]
    metabolic(lignin_to_nitrogen) = max(
        oftype(lignin_to_nitrogen, 0.001),
        oftype(lignin_to_nitrogen, 0.75) * (
            oftype(lignin_to_nitrogen, 0.85) -
            oftype(lignin_to_nitrogen, 0.013) * lignin_to_nitrogen
        ),
    )
    return (
        metabolic(leaf_lignin_to_nitrogen),
        metabolic(root_lignin_to_nitrogen),
    )
end

"""
    nitrogen_supply(
        temporal_mode,
        parameters,
        carbon,
        nitrogen,
        npp,
        allocation,
        turnover_rates,
        mineral_nitrogen,
        available_gpp,
    )

Return the legacy CASA mineral-N supply multiplier and labile-carbon fraction.

# Arguments

- `temporal_mode`: `LegacyDaily` applies the gate; `ContinuousRate` is neutral.
- `parameters`: plant nitrogen stoichiometry and retranslocation parameters.
- `carbon`, `nitrogen`: leaf, wood, and fine-root stocks [kg m⁻²].
- `npp`, `available_gpp`: carbon fluxes [kg C m⁻² s⁻¹]; the latter is
  gross production after root exudation.
- `allocation`: leaf, wood, and fine-root NPP fractions [-].
- `turnover_rates`: plant-pool turnover rates [s⁻¹].
- `mineral_nitrogen`: available mineral-N stock [kg N m⁻²].

# Returns

A named tuple `(npp_scalar, labile_fraction)` [-]. The scalar multiplies NPP
and the fraction diverts post-exudation GPP to labile carbon.

# Examples

```julia
supply_parameters = (
    nitrogen_ratio_minimum = (0.01, 0.01, 0.01),
    nitrogen_ratio_maximum = (0.02, 0.02, 0.02),
    nitrogen_fraction_to_litter = (1.0, 1.0, 1.0),
    mineral_half_saturation = 0.002,
)
supply = nitrogen_supply(
    LegacyDaily(), supply_parameters, (1.0, 1.0, 1.0), (0.0, 0.0, 0.0),
    1e-6, (0.4, 0.15, 0.45), (0.0, 0.0, 0.0), 0.000432, 2e-6,
)
limited_npp = supply.npp_scalar * 1e-6
```

See also [`nitrogen_uptake`](@ref) and [`carbon_fluxes`](@ref).
"""
@inline function nitrogen_supply(
    ::LegacyDaily,
    parameters,
    carbon,
    nitrogen,
    npp,
    allocation,
    turnover_rates,
    mineral_nitrogen,
    available_gpp,
)
    zero_mineral = zero(mineral_nitrogen)
    minimum_demand =
        nitrogen_uptake(
            parameters,
            carbon,
            nitrogen,
            npp,
            allocation,
            turnover_rates,
            zero_mineral,
            zero_mineral,
            zero_mineral,
        ).minimum_demand
    seconds_per_day = oftype(mineral_nitrogen, 86400)
    nitrogen_epsilon = oftype(mineral_nitrogen, 1e-13)
    available_fraction = clamp(
        mineral_nitrogen /
        (seconds_per_day * sum(minimum_demand) + nitrogen_epsilon),
        zero_mineral,
        one(mineral_nitrogen),
    )
    limited = (npp > zero(npp)) & (available_fraction < one(available_fraction))
    gpp_epsilon = oftype(available_gpp, 1e-10 / 1000 / 86400)
    labile_fraction = ifelse(
        limited,
        (one(available_fraction) - available_fraction) * max(zero(npp), npp) / (available_gpp + gpp_epsilon),
        zero(available_gpp),
    )
    safe_npp = ifelse(limited, npp, one(npp))
    npp_scalar = ifelse(
        limited,
        (npp - labile_fraction * available_gpp) / safe_npp,
        one(npp),
    )
    return (; npp_scalar, labile_fraction)
end

@inline function nitrogen_supply(
    ::ContinuousRate,
    parameters,
    carbon,
    nitrogen,
    npp,
    allocation,
    turnover_rates,
    mineral_nitrogen,
    available_gpp,
)
    return (;
        npp_scalar = one(available_gpp),
        labile_fraction = zero(available_gpp),
    )
end

"""
    nitrogen_uptake(
        parameters,
        carbon,
        nitrogen,
        npp,
        allocation,
        turnover_rates,
        mineral_nitrogen,
        demand_fraction,
        limitation,
    )

Compute CASA mineral-N demand, uptake, and allocation among leaf, wood, and
fine-root pools in the order used by `casa_Nrequire` and `casa_nuptake`.
"""
@inline function nitrogen_uptake(
    parameters,
    carbon,
    nitrogen,
    npp,
    allocation,
    turnover_rates,
    mineral_nitrogen,
    demand_fraction,
    limitation,
)
    available_ratio = ntuple(Val(3)) do index
        parameters.nitrogen_ratio_minimum[index] +
        demand_fraction * (
            parameters.nitrogen_ratio_maximum[index] -
            parameters.nitrogen_ratio_minimum[index]
        )
    end
    retranslocation = ntuple(Val(3)) do index
        turnover_rates[index] *
        nitrogen[index] *
        (one(nitrogen[index]) - parameters.nitrogen_fraction_to_litter[index])
    end
    raw_minimum_demand = ntuple(Val(3)) do index
        max(
            zero(npp),
            max(zero(npp), npp) *
            allocation[index] *
            parameters.nitrogen_ratio_minimum[index] -
            retranslocation[index],
        )
    end
    raw_maximum_demand = ntuple(Val(3)) do index
        max(
            zero(npp),
            max(zero(npp), npp) * allocation[index] * available_ratio[index] - retranslocation[index],
        )
    end
    minimum_demand = ntuple(Val(3)) do index
        excessive =
            nitrogen[index] / (carbon[index] + oftype(carbon[index], 1e-10)) >
            parameters.nitrogen_ratio_maximum[index]
        ifelse(
            excessive,
            zero(raw_minimum_demand[index]),
            raw_minimum_demand[index],
        )
    end
    maximum_demand = ntuple(Val(3)) do index
        excessive =
            nitrogen[index] / (carbon[index] + oftype(carbon[index], 1e-10)) >
            parameters.nitrogen_ratio_maximum[index]
        ifelse(
            excessive,
            zero(raw_maximum_demand[index]),
            raw_maximum_demand[index],
        )
    end
    mineral_response =
        mineral_nitrogen /
        (mineral_nitrogen + parameters.mineral_half_saturation)
    by_pool = ntuple(Val(3)) do index
        minimum_demand[index] +
        limitation *
        (maximum_demand[index] - minimum_demand[index]) *
        mineral_response
    end
    total = sum(by_pool)
    fractions = if total > zero(total)
        ntuple(index -> by_pool[index] / total, Val(3))
    else
        (zero(total), zero(total), zero(total))
    end
    return (
        by_pool = by_pool,
        total = total,
        fractions = fractions,
        minimum_demand = minimum_demand,
        maximum_demand = maximum_demand,
        retranslocation = retranslocation,
    )
end

"""
    nitrogen_fluxes(
        parameters,
        carbon,
        nitrogen,
        npp,
        allocation,
        turnover_rates,
        mineral_nitrogen,
        demand_fraction,
        limitation,
    )

Compute plant-N tendencies, mineral uptake, and litter-N boundary fluxes for
one CASA point.
"""
@inline function nitrogen_fluxes(
    parameters,
    carbon,
    nitrogen,
    npp,
    allocation,
    turnover_rates,
    mineral_nitrogen,
    demand_fraction,
    limitation,
    metabolic_fractions = plant_litter_fractions(parameters, carbon, nitrogen),
)
    uptake = nitrogen_uptake(
        parameters,
        carbon,
        nitrogen,
        npp,
        allocation,
        turnover_rates,
        mineral_nitrogen,
        demand_fraction,
        limitation,
    )
    fractions_to_litter = (
        ifelse(
            iszero(uptake.fractions[1]),
            one(nitrogen[1]),
            parameters.nitrogen_fraction_to_litter[1],
        ),
        parameters.nitrogen_fraction_to_litter[2],
        parameters.nitrogen_fraction_to_litter[3],
    )
    nitrogen_turnover = ntuple(
        index ->
            turnover_rates[index] *
            nitrogen[index] *
            fractions_to_litter[index],
        Val(3),
    )
    carbon_turnover =
        ntuple(index -> turnover_rates[index] * carbon[index], Val(3))
    structural =
        parameters.structural_litter_nitrogen_ratio * (
            (one(metabolic_fractions[1]) - metabolic_fractions[1]) *
            carbon_turnover[1] +
            (one(metabolic_fractions[2]) - metabolic_fractions[2]) *
            carbon_turnover[3]
        )
    metabolic = nitrogen_turnover[1] + nitrogen_turnover[3] - structural
    litter = (metabolic, structural, nitrogen_turnover[2])
    tendencies = ntuple(
        index -> uptake.by_pool[index] - nitrogen_turnover[index],
        Val(3),
    )
    return (
        tendencies = tendencies,
        litter = litter,
        uptake = uptake.total,
        uptake_by_pool = uptake.by_pool,
        uptake_allocation = uptake.fractions,
        nitrogen_turnover = nitrogen_turnover,
        metabolic_fractions = metabolic_fractions,
    )
end

"""
    allocation_fractions(parameters, phase, lai, npp, maintenance)

Apply the fixed-allocation, phenology, LAI-bound, and negative-NPP rules in
the same order as `casa_allocation` in the pinned Fortran source.
"""
@inline function allocation_fractions(parameters, phase, lai, npp, maintenance)
    base = normalize_fractions(parameters.allocation)
    remaining = base[2] + base[3]
    dormant = (zero(base[1]), base[2] / remaining, base[3] / remaining)
    flushing = ifelse(
        parameters.nonwoody,
        (oftype(base[1], 0.8), zero(base[2]), oftype(base[3], 0.2)),
        (oftype(base[1], 0.8), oftype(base[2], 0.1), oftype(base[3], 0.1)),
    )
    senescing = (zero(base[1]), base[2], one(base[3]) - base[2])
    fractions = ifelse(
        phase == zero(phase),
        dormant,
        ifelse(
            phase == one(phase),
            flushing,
            ifelse(phase == oftype(phase, 3), senescing, base),
        ),
    )
    no_leaf = normalize_fractions((zero(base[1]), fractions[2], fractions[3]))
    fractions =
        ifelse(lai >= parameters.maximum_leaf_area_index, no_leaf, fractions)
    fractions =
        ifelse(lai < parameters.minimum_leaf_area_index, flushing, fractions)
    respiration_allocation = normalize_fractions(maintenance)
    fractions = ifelse(npp < zero(npp), respiration_allocation, fractions)
    return normalize_fractions(fractions)
end

"""
    senescence_rates(parameters, phase, lai, air_temperature, water_stress)

Return leaf, wood, and fine-root turnover rates in inverse seconds.
"""
@inline function senescence_rates(
    parameters,
    phase,
    lai,
    air_temperature,
    water_stress,
)
    five = oftype(air_temperature, 5)
    cold_state = clamp(
        (air_temperature - (parameters.shedding_temperature - five)) / five,
        zero(air_temperature),
        one(air_temperature),
    )
    cold =
        parameters.cold_turnover_maximum *
        (one(cold_state) - cold_state)^parameters.cold_turnover_exponent
    dry =
        parameters.drought_turnover_maximum *
        (
            one(water_stress) - water_stress
        )^(parameters.drought_turnover_exponent)
    leaf_switch = ifelse(phase == one(phase), zero(phase), one(phase))
    leaf = parameters.turnover_rates[1] * leaf_switch + cold + dry
    leaf = ifelse(lai <= parameters.minimum_leaf_area_index, zero(leaf), leaf)
    return (leaf, parameters.turnover_rates[2], parameters.turnover_rates[3])
end

"""
    carbon_fluxes(parameters, carbon, gpp, air_temperature,
                  soil_temperature, water_stress, phase,
                  npp_scalar, labile_fraction)

Return the carbon-only CASA plant fluxes for one surface point.
"""
@inline function carbon_fluxes(
    parameters,
    carbon,
    gpp,
    air_temperature,
    soil_temperature,
    water_stress,
    phase,
    npp_scalar,
    labile_fraction,
    plant_nitrogen = parameters.plant_nitrogen,
)
    respiration = respiration_fluxes(
        parameters,
        gpp,
        air_temperature,
        soil_temperature,
        carbon[2],
        carbon[3],
        plant_nitrogen,
    )
    npp = respiration.npp * npp_scalar
    lai = leaf_area_index(parameters, carbon[1])
    allocation = allocation_fractions(
        parameters,
        phase,
        lai,
        npp,
        (zero(respiration.wood), respiration.wood, respiration.fine_root),
    )
    rates =
        senescence_rates(parameters, phase, lai, air_temperature, water_stress)
    turnover =
        (rates[1] * carbon[1], rates[2] * carbon[2], rates[3] * carbon[3])
    exudate = max(zero(gpp), parameters.root_exudate_fraction * gpp)
    labile_factor = ifelse(
        air_temperature > oftype(air_temperature, 250),
        temperature_response(air_temperature, parameters.freezing_temperature),
        zero(air_temperature),
    )
    labile_loss =
        parameters.labile_loss_rate *
        max(zero(carbon[4]), carbon[4]) *
        labile_factor
    tendencies = (
        npp * allocation[1] - turnover[1],
        npp * allocation[2] - turnover[2],
        npp * allocation[3] - turnover[3],
        (gpp - exudate) * labile_fraction - labile_loss,
    )
    return (
        tendencies = tendencies,
        allocation = allocation,
        turnover = turnover,
        rates = rates,
        gpp = gpp,
        npp = npp,
        autotrophic_respiration = respiration.maintenance + respiration.growth,
        maintenance_respiration = respiration.maintenance,
        growth_respiration = respiration.growth,
        leaf_area_index = lai,
        root_exudate = exudate,
        labile_loss = labile_loss,
    )
end

@inline function packed_carbon_fluxes(
    parameters,
    c_leaf,
    c_wood,
    c_fine_root,
    c_labile,
    gpp,
    air_temperature,
    soil_temperature,
    water_stress,
    phase,
    npp_scalar,
    labile_fraction,
    n_leaf = carbon_only_plant_nitrogen(
        parameters,
        c_leaf,
        c_wood,
        c_fine_root,
    )[1],
    n_wood = carbon_only_plant_nitrogen(
        parameters,
        c_leaf,
        c_wood,
        c_fine_root,
    )[2],
    n_fine_root = carbon_only_plant_nitrogen(
        parameters,
        c_leaf,
        c_wood,
        c_fine_root,
    )[3],
)
    carbon = (c_leaf, c_wood, c_fine_root, c_labile)
    fluxes = carbon_fluxes(
        parameters,
        carbon,
        gpp,
        air_temperature,
        soil_temperature,
        water_stress,
        phase,
        npp_scalar,
        labile_fraction,
        (n_leaf, n_wood, n_fine_root),
    )
    return StaticArrays.SVector{21}(
        fluxes.tendencies[1],
        fluxes.tendencies[2],
        fluxes.tendencies[3],
        fluxes.tendencies[4],
        fluxes.allocation[1],
        fluxes.allocation[2],
        fluxes.allocation[3],
        fluxes.turnover[1],
        fluxes.turnover[2],
        fluxes.turnover[3],
        fluxes.rates[1],
        fluxes.rates[2],
        fluxes.rates[3],
        fluxes.gpp,
        fluxes.npp,
        fluxes.autotrophic_respiration,
        fluxes.maintenance_respiration,
        fluxes.growth_respiration,
        fluxes.leaf_area_index,
        fluxes.root_exudate,
        fluxes.labile_loss,
    )
end

"""
    packed_carbon_nitrogen_fluxes(temporal_mode, parameters,
        nitrogen_parameters, ...)

Compute the 21-entry packed plant-C flux vector, applying the legacy mineral-N
supply gate between the unrestricted and final carbon calculations. Called by
the standalone and coupled CN cache updates.
"""
@inline function packed_carbon_nitrogen_fluxes(
    temporal_mode,
    parameters,
    nitrogen_parameters,
    c_leaf,
    c_wood,
    c_fine_root,
    c_labile,
    n_leaf,
    n_wood,
    n_fine_root,
    mineral_nitrogen,
    gpp,
    air_temperature,
    soil_temperature,
    water_stress,
    phase,
    npp_scalar,
    labile_fraction,
)
    unrestricted = packed_carbon_fluxes(
        temporal_mode,
        parameters,
        c_leaf,
        c_wood,
        c_fine_root,
        c_labile,
        gpp,
        air_temperature,
        soil_temperature,
        water_stress,
        phase,
        npp_scalar,
        labile_fraction,
        n_leaf,
        n_wood,
        n_fine_root,
    )
    supply = nitrogen_supply(
        temporal_mode,
        nitrogen_parameters,
        (c_leaf, c_wood, c_fine_root),
        (n_leaf, n_wood, n_fine_root),
        unrestricted[15],
        (unrestricted[5], unrestricted[6], unrestricted[7]),
        (unrestricted[11], unrestricted[12], unrestricted[13]),
        mineral_nitrogen,
        gpp - unrestricted[20],
    )
    return packed_carbon_fluxes(
        temporal_mode,
        parameters,
        c_leaf,
        c_wood,
        c_fine_root,
        c_labile,
        gpp,
        air_temperature,
        soil_temperature,
        water_stress,
        phase,
        npp_scalar * supply.npp_scalar,
        labile_fraction + supply.labile_fraction,
        n_leaf,
        n_wood,
        n_fine_root,
    )
end

@inline packed_carbon_fluxes(::ContinuousRate, args...) =
    packed_carbon_fluxes(args...)

@inline function packed_carbon_fluxes(
    ::LegacyDaily,
    parameters,
    c_leaf,
    c_wood,
    c_fine_root,
    c_labile,
    gpp,
    air_temperature,
    soil_temperature,
    water_stress,
    phase,
    npp_scalar,
    labile_fraction,
    n_leaf = carbon_only_plant_nitrogen(
        parameters,
        c_leaf,
        c_wood,
        c_fine_root,
    )[1],
    n_wood = carbon_only_plant_nitrogen(
        parameters,
        c_leaf,
        c_wood,
        c_fine_root,
    )[2],
    n_fine_root = carbon_only_plant_nitrogen(
        parameters,
        c_leaf,
        c_wood,
        c_fine_root,
    )[3],
)
    fluxes = packed_carbon_fluxes(
        parameters,
        c_leaf,
        c_wood,
        c_fine_root,
        c_labile,
        gpp,
        air_temperature,
        soil_temperature,
        water_stress,
        phase,
        npp_scalar,
        labile_fraction,
        n_leaf,
        n_wood,
        n_fine_root,
    )
    fluxes =
        Base.setindex(fluxes, legacy_bounded_tendency(c_leaf, fluxes[1]), 1)
    fluxes =
        Base.setindex(fluxes, legacy_bounded_tendency(c_wood, fluxes[2]), 2)
    return Base.setindex(
        fluxes,
        legacy_bounded_tendency(c_fine_root, fluxes[3]),
        3,
    )
end

@inline function packed_nitrogen_fluxes(
    parameters,
    c_leaf,
    c_wood,
    c_fine_root,
    n_leaf,
    n_wood,
    n_fine_root,
    mineral_nitrogen,
    demand_fraction,
    limitation,
    carbon_fluxes,
    metabolic_fractions = plant_litter_fractions(
        parameters,
        (c_leaf, c_wood, c_fine_root),
        (n_leaf, n_wood, n_fine_root),
    ),
)
    fluxes = nitrogen_fluxes(
        parameters,
        (c_leaf, c_wood, c_fine_root),
        (n_leaf, n_wood, n_fine_root),
        carbon_fluxes[15],
        (carbon_fluxes[5], carbon_fluxes[6], carbon_fluxes[7]),
        (carbon_fluxes[11], carbon_fluxes[12], carbon_fluxes[13]),
        mineral_nitrogen,
        demand_fraction,
        limitation,
        metabolic_fractions,
    )
    return StaticArrays.SVector{12}(
        fluxes.tendencies...,
        fluxes.litter...,
        fluxes.uptake,
        fluxes.uptake_allocation...,
        fluxes.metabolic_fractions...,
    )
end

@inline packed_nitrogen_fluxes(::ContinuousRate, args...) =
    packed_nitrogen_fluxes(args...)

@inline function packed_nitrogen_fluxes(
    ::LegacyDaily,
    parameters,
    c_leaf,
    c_wood,
    c_fine_root,
    n_leaf,
    n_wood,
    n_fine_root,
    mineral_nitrogen,
    demand_fraction,
    limitation,
    carbon_fluxes,
    metabolic_fractions = plant_litter_fractions(
        parameters,
        (c_leaf, c_wood, c_fine_root),
        (n_leaf, n_wood, n_fine_root),
    ),
)
    fluxes = packed_nitrogen_fluxes(
        parameters,
        c_leaf,
        c_wood,
        c_fine_root,
        n_leaf,
        n_wood,
        n_fine_root,
        mineral_nitrogen,
        demand_fraction,
        limitation,
        carbon_fluxes,
        metabolic_fractions,
    )
    seconds_per_day = oftype(c_leaf, 86400)
    update_nitrogen = carbon_fluxes[1] > -c_leaf / seconds_per_day
    nitrogen = (n_leaf, n_wood, n_fine_root)
    for index in 1:3
        tendency = ifelse(update_nitrogen, fluxes[index], zero(fluxes[index]))
        fluxes = Base.setindex(
            fluxes,
            legacy_bounded_tendency(nitrogen[index], tendency),
            index,
        )
    end
    return fluxes
end

@inline function packed_mimics_nitrogen_fluxes(
    temporal_mode,
    parameters,
    c_leaf,
    c_wood,
    c_fine_root,
    n_leaf,
    n_wood,
    n_fine_root,
    mineral_nitrogen,
    demand_fraction,
    limitation,
    carbon_fluxes,
)
    metabolic_fractions = mimics_plant_litter_fractions(
        parameters,
        (c_leaf, c_wood, c_fine_root),
        (n_leaf, n_wood, n_fine_root),
    )
    return packed_nitrogen_fluxes(
        temporal_mode,
        parameters,
        c_leaf,
        c_wood,
        c_fine_root,
        n_leaf,
        n_wood,
        n_fine_root,
        mineral_nitrogen,
        demand_fraction,
        limitation,
        carbon_fluxes,
        metabolic_fractions,
    )
end

function ClimaLand.make_update_aux(
    model::CASAPlantModel{FT, CarbonOnly},
) where {FT}
    function update_aux!(p, Y, t)
        gpp = model.drivers.gross_primary_production(t)
        air_temperature = model.drivers.air_temperature(t)
        soil_temperature = model.drivers.soil_temperature(t)
        water_stress = model.drivers.water_stress(t)
        phase = model.drivers.phenology_phase(t)
        npp_scalar = model.drivers.npp_scalar(t)
        labile_fraction = model.drivers.labile_fraction(t)
        parameters = model.parameters
        temporal_mode = model.temporal_mode

        @. p.casa_plant.gross_primary_production = gpp
        @. p.casa_plant.air_temperature = air_temperature
        @. p.casa_plant.soil_temperature = soil_temperature
        @. p.casa_plant.water_stress = water_stress
        @. p.casa_plant.phenology_phase = phase
        @. p.casa_plant.carbon_fluxes = packed_carbon_fluxes(
            temporal_mode,
            parameters,
            Y.casa_plant.c_leaf,
            Y.casa_plant.c_wood,
            Y.casa_plant.c_fine_root,
            Y.casa_plant.c_labile,
            gpp,
            air_temperature,
            soil_temperature,
            water_stress,
            phase,
            npp_scalar,
            labile_fraction,
        )
    end
    return update_aux!
end


function ClimaLand.make_update_aux(
    model::CASAPlantModel{FT, CarbonNitrogen},
) where {FT}
    function update_aux!(p, Y, t)
        gpp = model.drivers.gross_primary_production(t)
        air_temperature = model.drivers.air_temperature(t)
        soil_temperature = model.drivers.soil_temperature(t)
        water_stress = model.drivers.water_stress(t)
        phase = model.drivers.phenology_phase(t)
        mineral_nitrogen = model.nitrogen_drivers.mineral_nitrogen(t)
        demand_fraction = model.nitrogen_drivers.demand_fraction(t)
        limitation = model.nitrogen_drivers.limitation(t)

        @. p.casa_plant.gross_primary_production = gpp
        @. p.casa_plant.air_temperature = air_temperature
        @. p.casa_plant.soil_temperature = soil_temperature
        @. p.casa_plant.water_stress = water_stress
        @. p.casa_plant.phenology_phase = phase
        update_nitrogen_limited_carbon_fluxes!(p, Y, model, t, mineral_nitrogen)
        update_nitrogen_fluxes!(
            p,
            Y,
            model.temporal_mode,
            model.nitrogen_parameters,
            mineral_nitrogen,
            demand_fraction,
            limitation,
        )
    end
    return update_aux!
end

"""
    update_nitrogen_limited_carbon_fluxes!(p, Y, model, t, mineral_nitrogen)

Recompute `p.casa_plant.carbon_fluxes` from cached environmental drivers and
the supplied mineral-N stock. Reads plant C/N state from `Y` and returns
`nothing`. Called by standalone and coupled CN updates.
"""
function update_nitrogen_limited_carbon_fluxes!(
    p,
    Y,
    model,
    t,
    mineral_nitrogen,
)
    npp_scalar = model.drivers.npp_scalar(t)
    labile_fraction = model.drivers.labile_fraction(t)
    parameters = model.parameters
    nitrogen_parameters = model.nitrogen_parameters
    temporal_mode = model.temporal_mode

    @. p.casa_plant.carbon_fluxes = packed_carbon_nitrogen_fluxes(
        temporal_mode,
        parameters,
        nitrogen_parameters,
        Y.casa_plant.c_leaf,
        Y.casa_plant.c_wood,
        Y.casa_plant.c_fine_root,
        Y.casa_plant.c_labile,
        Y.casa_plant.n_leaf,
        Y.casa_plant.n_wood,
        Y.casa_plant.n_fine_root,
        mineral_nitrogen,
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

function update_nitrogen_fluxes!(
    p,
    Y,
    temporal_mode,
    parameters,
    mineral_nitrogen,
    demand_fraction,
    limitation,
    metabolic_fractions = nothing,
)
    @. p.casa_plant.mineral_nitrogen = mineral_nitrogen
    @. p.casa_plant.nitrogen_demand_fraction = demand_fraction
    @. p.casa_plant.nitrogen_limitation = limitation
    if isnothing(metabolic_fractions)
        @. p.casa_plant.nitrogen_fluxes = packed_nitrogen_fluxes(
            temporal_mode,
            parameters,
            Y.casa_plant.c_leaf,
            Y.casa_plant.c_wood,
            Y.casa_plant.c_fine_root,
            Y.casa_plant.n_leaf,
            Y.casa_plant.n_wood,
            Y.casa_plant.n_fine_root,
            p.casa_plant.mineral_nitrogen,
            p.casa_plant.nitrogen_demand_fraction,
            p.casa_plant.nitrogen_limitation,
            p.casa_plant.carbon_fluxes,
        )
    else
        @. p.casa_plant.nitrogen_fluxes = packed_nitrogen_fluxes(
            temporal_mode,
            parameters,
            Y.casa_plant.c_leaf,
            Y.casa_plant.c_wood,
            Y.casa_plant.c_fine_root,
            Y.casa_plant.n_leaf,
            Y.casa_plant.n_wood,
            Y.casa_plant.n_fine_root,
            p.casa_plant.mineral_nitrogen,
            p.casa_plant.nitrogen_demand_fraction,
            p.casa_plant.nitrogen_limitation,
            p.casa_plant.carbon_fluxes,
            metabolic_fractions,
        )
    end
    return nothing
end


function update_mimics_nitrogen_fluxes!(
    p,
    Y,
    temporal_mode,
    parameters,
    mineral_nitrogen,
    demand_fraction,
    limitation,
)
    @. p.casa_plant.mineral_nitrogen = mineral_nitrogen
    @. p.casa_plant.nitrogen_demand_fraction = demand_fraction
    @. p.casa_plant.nitrogen_limitation = limitation
    @. p.casa_plant.nitrogen_fluxes = packed_mimics_nitrogen_fluxes(
        temporal_mode,
        parameters,
        Y.casa_plant.c_leaf,
        Y.casa_plant.c_wood,
        Y.casa_plant.c_fine_root,
        Y.casa_plant.n_leaf,
        Y.casa_plant.n_wood,
        Y.casa_plant.n_fine_root,
        p.casa_plant.mineral_nitrogen,
        p.casa_plant.nitrogen_demand_fraction,
        p.casa_plant.nitrogen_limitation,
        p.casa_plant.carbon_fluxes,
    )
    return nothing
end

function ClimaLand.make_compute_exp_tendency(
    ::CASAPlantModel{FT, CarbonOnly},
) where {FT}
    function compute_exp_tendency!(dY, Y, p, t)
        fluxes = p.casa_plant.carbon_fluxes
        @. dY.casa_plant.c_leaf = getindex(fluxes, 1)
        @. dY.casa_plant.c_wood = getindex(fluxes, 2)
        @. dY.casa_plant.c_fine_root = getindex(fluxes, 3)
        @. dY.casa_plant.c_labile = getindex(fluxes, 4)
    end
    return compute_exp_tendency!
end


function ClimaLand.make_compute_exp_tendency(
    ::CASAPlantModel{FT, CarbonNitrogen},
) where {FT}
    function compute_exp_tendency!(dY, Y, p, t)
        carbon = p.casa_plant.carbon_fluxes
        nitrogen = p.casa_plant.nitrogen_fluxes
        @. dY.casa_plant.c_leaf = getindex(carbon, 1)
        @. dY.casa_plant.c_wood = getindex(carbon, 2)
        @. dY.casa_plant.c_fine_root = getindex(carbon, 3)
        @. dY.casa_plant.c_labile = getindex(carbon, 4)
        @. dY.casa_plant.n_leaf = getindex(nitrogen, 1)
        @. dY.casa_plant.n_wood = getindex(nitrogen, 2)
        @. dY.casa_plant.n_fine_root = getindex(nitrogen, 3)
    end
    return compute_exp_tendency!
end

end
