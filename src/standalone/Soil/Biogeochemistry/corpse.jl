module CORPSE

import StaticArrays
import ClimaCore

import ..Biogeochemistry
import ..CASA
import ....ClimaLand

export CarbonParameters,
    AbstractTemporalMode,
    ContinuousRate,
    CORPSESoilModel,
    CORPSESoilModelParameters,
    LegacyDaily,
    PrescribedDrivers,
    add_exudate,
    add_litter,
    cohort_carbon,
    continuous_carbon_fluxes,
    continuous_cohort_tendencies,
    daily_carbon_map,
    mineral_protection_capacity,
    moisture_factor,
    update_cohort

const N_COHORT_STATES = 9

"Compile-time temporal formulation for the standalone CORPSE model."
abstract type AbstractTemporalMode end

"Exact ordered one-day map used by the reference Fortran testbed."
struct LegacyDaily <: AbstractTemporalMode end

"Timestep-independent, simultaneous CORPSE ordinary differential equation."
struct ContinuousRate <: AbstractTemporalMode end

Base.broadcastable(mode::AbstractTemporalMode) = tuple(mode)

"""
    CarbonParameters{FT}

Parameters for the fixed-cohort carbon-only CORPSE map. Rates use inverse
years, activation energies use J mol⁻¹, and carbon stocks use kg C m⁻².
"""
Base.@kwdef struct CarbonParameters{FT <: AbstractFloat}
    vmax_reference::NTuple{3, FT}
    activation_energy::NTuple{3, FT}
    michaelis_constant::NTuple{3, FT}
    minimum_microbe_fraction::FT
    microbe_turnover_time::FT
    uptake_efficiency::NTuple{3, FT}
    protection_rate::FT
    protection_species::NTuple{3, FT}
    protected_turnover_time::FT
    protected_decomposition_factor::FT
    turnover_efficiency::FT
    enzyme_fraction::FT
    turnover_factor::NTuple{3, FT}
    gas_diffusion_exponent::FT
    minimum_anaerobic_factor::FT
    minimum_moisture_factor::FT
    litter_density::FT
end

Base.broadcastable(parameters::CarbonParameters) = tuple(parameters)

"""
    mineral_protection_capacity(clay_fraction, porosity)

Compute CORPSE `Qmax` in kg C m⁻³ from clay mass fraction and porosity using
the Mayes et al. relationship in the testbed initialization.
"""
@inline function mineral_protection_capacity(clay_fraction, porosity)
    clay_percent = clay_fraction * oftype(clay_fraction, 100)
    if clay_percent <= zero(clay_percent)
        return zero(clay_percent)
    end
    exponent =
        oftype(clay_percent, 0.4833) * log10(clay_percent) +
        oftype(clay_percent, 2.3282)
    solid_density = oftype(clay_percent, 2650)
    conversion = oftype(clay_percent, 1e-6)
    return max(
        zero(clay_percent),
        10^exponent * (one(porosity) - porosity) * solid_density * conversion,
    )
end

"""
    CORPSESoilModelParameters{FT}

Point parameters for the standalone fixed-cohort CORPSE carbon model.
Surface-pool rates use inverse seconds; the ordered CORPSE map retains legacy
year units. A `CORPSESoilModel` accepts either one parameter instance or a
surface `ClimaCore.Fields.Field` of instances.
"""
Base.@kwdef struct CORPSESoilModelParameters{
    FT <: AbstractFloat,
    CP <: CarbonParameters{FT},
}
    carbon::CP
    mineral_protection_capacity::FT
    layer_thickness::FT
    rhizosphere_fraction::FT
    litter_option::Int
    freezing_temperature::FT
    cwd_q10::FT
    cwd_litter_optimum::FT
    cwd_base_rate::FT
    cwd_respiration_fraction::FT
end

Base.broadcastable(parameters::CORPSESoilModelParameters) = tuple(parameters)

"""
    PrescribedDrivers

Time-dependent standalone drivers. Temperatures use K, saturation values are
fractions of pore space, and inputs use kg C m⁻² s⁻¹.
"""
struct PrescribedDrivers{T, L, F, AL, AR, BL, BR, E, C}
    soil_temperature::T
    liquid_saturation::L
    frozen_saturation::F
    leaf_labile::AL
    leaf_recalcitrant::AR
    root_labile::BL
    root_recalcitrant::BR
    exudate_labile::E
    litter_cwd::C
end

const PROGNOSTIC_VARIABLES = (
    :c_litter_cwd,
    :soil_rhiz_unprotected_labile,
    :soil_rhiz_unprotected_recalcitrant,
    :soil_rhiz_unprotected_dead_microbe,
    :soil_rhiz_protected_labile,
    :soil_rhiz_protected_recalcitrant,
    :soil_rhiz_protected_dead_microbe,
    :soil_rhiz_live_microbe,
    :soil_rhiz_cumulative_co2,
    :soil_rhiz_original_carbon,
    :soil_bulk_unprotected_labile,
    :soil_bulk_unprotected_recalcitrant,
    :soil_bulk_unprotected_dead_microbe,
    :soil_bulk_protected_labile,
    :soil_bulk_protected_recalcitrant,
    :soil_bulk_protected_dead_microbe,
    :soil_bulk_live_microbe,
    :soil_bulk_cumulative_co2,
    :soil_bulk_original_carbon,
    :litter_rhiz_unprotected_labile,
    :litter_rhiz_unprotected_recalcitrant,
    :litter_rhiz_unprotected_dead_microbe,
    :litter_rhiz_protected_labile,
    :litter_rhiz_protected_recalcitrant,
    :litter_rhiz_protected_dead_microbe,
    :litter_rhiz_live_microbe,
    :litter_rhiz_cumulative_co2,
    :litter_rhiz_original_carbon,
    :litter_bulk_unprotected_labile,
    :litter_bulk_unprotected_recalcitrant,
    :litter_bulk_unprotected_dead_microbe,
    :litter_bulk_protected_labile,
    :litter_bulk_protected_recalcitrant,
    :litter_bulk_protected_dead_microbe,
    :litter_bulk_live_microbe,
    :litter_bulk_cumulative_co2,
    :litter_bulk_original_carbon,
)

"""
    CORPSESoilModel{FT}(; parameters, drivers, domain, temporal_mode)

Standalone carbon-only CORPSE model with fixed rhizosphere and bulk cohorts
for both the soil and litter layer, plus the testbed coarse woody debris pool.
`temporal_mode = LegacyDaily()` preserves the ordered reference map;
`ContinuousRate()` selects a simultaneous, timestep-independent ODE.
"""
struct CORPSESoilModel{FT, TM, PS, D, DR} <:
       Biogeochemistry.AbstractSoilBiogeochemistryModel{FT}
    temporal_mode::TM
    parameters::PS
    domain::D
    drivers::DR
end

function CORPSESoilModel{FT}(;
    parameters,
    drivers,
    domain::ClimaLand.Domains.AbstractDomain{FT} = ClimaLand.Domains.Point(;
        z_sfc = zero(FT),
    ),
    temporal_mode::AbstractTemporalMode = LegacyDaily(),
) where {FT}
    @assert parameters isa CORPSESoilModelParameters{FT} || (
        parameters isa ClimaCore.Fields.Field &&
        eltype(parameters) <: CORPSESoilModelParameters{FT}
    ) "parameters must be CORPSE point parameters or a Field of CORPSE point parameters"
    @assert !(parameters isa ClimaCore.Fields.Field) ||
            axes(parameters) == domain.space.surface "spatial CORPSE parameters must use the model surface space"
    args = (temporal_mode, parameters, domain, drivers)
    return CORPSESoilModel{FT, typeof.(args)...}(args...)
end

ClimaLand.name(::CORPSESoilModel) = :corpse_soil
ClimaLand.prognostic_vars(::CORPSESoilModel) = PROGNOSTIC_VARIABLES
ClimaLand.prognostic_types(::CORPSESoilModel{FT}) where {FT} =
    ntuple(_ -> FT, length(PROGNOSTIC_VARIABLES))
ClimaLand.prognostic_domain_names(::CORPSESoilModel) =
    ntuple(_ -> :surface, length(PROGNOSTIC_VARIABLES))

ClimaLand.auxiliary_vars(::CORPSESoilModel) = (
    :soil_temperature,
    :liquid_saturation,
    :frozen_saturation,
    :leaf_labile_input,
    :leaf_recalcitrant_input,
    :root_labile_input,
    :root_recalcitrant_input,
    :exudate_labile_input,
    :litter_cwd_input,
    :carbon_fluxes,
)
ClimaLand.auxiliary_types(::CORPSESoilModel{FT}) where {FT} =
    (FT, FT, FT, FT, FT, FT, FT, FT, FT, StaticArrays.SVector{39, FT})
ClimaLand.auxiliary_domain_names(::CORPSESoilModel) = ntuple(_ -> :surface, 10)

"""
    cohort_carbon(cohort[, only_active])

Return total cohort carbon. A cohort is ordered as three unprotected pools,
three protected pools, live microbes, cumulative CO₂, and original carbon.
The original-carbon bookkeeping value is not itself included in the sum.
"""
@inline function cohort_carbon(cohort, only_active::Bool = false)
    active =
        cohort[1] +
        cohort[2] +
        cohort[3] +
        cohort[4] +
        cohort[5] +
        cohort[6] +
        cohort[7]
    return only_active ? active : active + cohort[8]
end

"""
    add_litter(parameters, cohort, litter, fraction)

Apply the legacy `add_litter2` operation to one fixed cohort. The small
minimum-microbe share is routed directly to live microbes and original carbon
is reset to the resulting total, including cumulative CO₂.
"""
@inline function add_litter(parameters, cohort, litter, fraction)
    microbial = sum(litter) * parameters.minimum_microbe_fraction * fraction
    substrate_fraction =
        (one(fraction) - parameters.minimum_microbe_fraction) * fraction
    next = StaticArrays.SVector(
        cohort[1] + litter[1] * substrate_fraction,
        cohort[2] + litter[2] * substrate_fraction,
        cohort[3] + litter[3] * substrate_fraction,
        cohort[4],
        cohort[5],
        cohort[6],
        cohort[7] + microbial,
        cohort[8],
        cohort[9],
    )
    return Base.setindex(next, cohort_carbon(next), 9)
end

"""
    add_exudate(cohort, exudate)

Add exudate directly to the rhizosphere unprotected pools, matching the fixed
cohort `add_carbon_to_rhizosphere` path.
"""
@inline function add_exudate(cohort, exudate)
    return StaticArrays.SVector(
        cohort[1] + exudate[1],
        cohort[2] + exudate[2],
        cohort[3] + exudate[3],
        cohort[4],
        cohort[5],
        cohort[6],
        cohort[7],
        cohort[8],
        cohort[9] + sum(exudate),
    )
end

"""
    moisture_factor(parameters, liquid_saturation, air_filled_porosity)

Return the CORPSE soil-moisture multiplier used inside decomposition rates.
"""
@inline function moisture_factor(
    parameters,
    liquid_saturation,
    air_filled_porosity,
)
    anaerobic = max(
        air_filled_porosity^parameters.gas_diffusion_exponent,
        parameters.minimum_anaerobic_factor,
    )
    value = (liquid_saturation^3 + oftype(liquid_saturation, 0.001)) * anaerobic
    return max(parameters.minimum_moisture_factor, value)
end

@inline function respiration_rates(
    parameters,
    substrate,
    living_microbe,
    temperature,
    moisture,
    vmax_factor,
)
    if sum(substrate) == zero(eltype(substrate)) ||
       living_microbe == zero(living_microbe)
        return zero(substrate)
    end
    reference_temperature = oftype(temperature, 293.15)
    gas_constant = oftype(temperature, 8.314472)
    enzyme = living_microbe * parameters.enzyme_fraction
    total_substrate = sum(substrate)
    return StaticArrays.SVector{3}(
        ntuple(3) do index
            vmax =
                parameters.vmax_reference[index] * exp(
                    parameters.activation_energy[index] / gas_constant *
                    (inv(reference_temperature) - inv(temperature)),
                )
            return vmax * vmax_factor * moisture * substrate[index] * enzyme /
                   (
                total_substrate * parameters.michaelis_constant[index] + enzyme
            )
        end,
    )
end

"""
    update_cohort(parameters, cohort, temperature, liquid, air, qmax, depth)

Apply the ordered legacy daily update to one cohort. `depth` and the original
carbon state are retained in the cohort-volume calculation required by the
source, including when microbial protection is disabled in the pinned setup.
"""
@inline function update_cohort(
    parameters,
    cohort,
    temperature,
    liquid_saturation,
    air_filled_porosity,
    qmax,
    layer_thickness,
)
    year_step = inv(oftype(temperature, 365))
    unprotected = StaticArrays.SVector(cohort[1], cohort[2], cohort[3])
    protected = StaticArrays.SVector(cohort[4], cohort[5], cohort[6])
    living_microbe = cohort[7]
    moisture =
        moisture_factor(parameters, liquid_saturation, air_filled_porosity)

    active_volume = cohort_carbon(cohort, true) / parameters.litter_density
    inactive_volume =
        min(cohort[9] / parameters.litter_density, layer_thickness) -
        active_volume
    cohort_volume = active_volume + max(zero(active_volume), inactive_volume)

    unprotected_rate = if liquid_saturation == zero(liquid_saturation)
        zero(unprotected)
    else
        respiration_rates(
            parameters,
            unprotected,
            living_microbe,
            temperature,
            moisture,
            one(temperature),
        )
    end
    unprotected_loss = min.(year_step .* unprotected_rate, unprotected)
    unprotected = unprotected - unprotected_loss
    total_rates = unprotected_loss / year_step

    protected_rate = if liquid_saturation == zero(liquid_saturation)
        zero(protected)
    else
        respiration_rates(
            parameters,
            protected,
            living_microbe,
            temperature,
            moisture,
            parameters.protected_decomposition_factor,
        )
    end
    protected_loss = min.(year_step .* protected_rate, protected)
    protected = protected - protected_loss
    total_rates = total_rates + protected_loss / year_step

    turnover = max(
        zero(living_microbe),
        (
            living_microbe -
            parameters.minimum_microbe_fraction * sum(unprotected)
        ) / parameters.microbe_turnover_time,
    )
    total_respiration_rate = sum(total_rates)
    if total_respiration_rate > zero(total_respiration_rate)
        weighted_inverse =
            total_rates[1] / total_respiration_rate /
            parameters.turnover_factor[1] +
            total_rates[2] / total_respiration_rate /
            parameters.turnover_factor[2] +
            total_rates[3] / total_respiration_rate /
            parameters.turnover_factor[3]
        turnover /= weighted_inverse
    end
    living_microbe +=
        year_step *
        (sum(parameters.uptake_efficiency .* total_rates) - turnover)
    dead_microbe = year_step * turnover * parameters.turnover_efficiency
    unprotected = Base.setindex(unprotected, unprotected[3] + dead_microbe, 3)
    substrate_respiration =
        total_rates[1] * (one(temperature) - parameters.uptake_efficiency[1]) +
        total_rates[2] * (one(temperature) - parameters.uptake_efficiency[2]) +
        total_rates[3] * (one(temperature) - parameters.uptake_efficiency[3])
    carbon_dioxide =
        year_step * (
            substrate_respiration +
            turnover * (one(temperature) - parameters.turnover_efficiency)
        )

    protected_turnover = protected / parameters.protected_turnover_time
    protection =
        parameters.protection_rate .* parameters.protection_species .* qmax
    new_protected =
        if sum(unprotected) > zero(temperature) &&
           cohort_volume > zero(temperature)
            min.(protection .* unprotected .* year_step, unprotected)
        else
            zero(unprotected)
        end
    protected = protected + new_protected - year_step * protected_turnover
    unprotected = unprotected - new_protected + year_step * protected_turnover

    state = StaticArrays.SVector(
        unprotected[1],
        unprotected[2],
        unprotected[3],
        protected[1],
        protected[2],
        protected[3],
        living_microbe,
        cohort[8] + carbon_dioxide,
        cohort[9],
    )
    return (state = state, respiration = carbon_dioxide, moisture = moisture)
end

"""
    continuous_cohort_tendencies(
        parameters,
        cohort,
        litter_input,
        exudate_input,
        litter_fraction,
        temperature,
        liquid_saturation,
        air_filled_porosity,
        qmax,
        layer_thickness,
    )

Return the simultaneous CORPSE cohort tendency in kg C m⁻² s⁻¹. All process
rates are evaluated from the same current `cohort`; no process observes a
partially updated pool and no loss is capped using a numerical timestep.
`litter_input` and `exudate_input` are instantaneous area rates.
"""
@inline function continuous_cohort_tendencies(
    parameters,
    cohort,
    litter_input,
    exudate_input,
    litter_fraction,
    temperature,
    liquid_saturation,
    air_filled_porosity,
    qmax,
    layer_thickness,
)
    seconds_per_year = oftype(temperature, 365 * 86400)
    unprotected = StaticArrays.SVector(cohort[1], cohort[2], cohort[3])
    protected = StaticArrays.SVector(cohort[4], cohort[5], cohort[6])
    living_microbe = cohort[7]
    moisture =
        moisture_factor(parameters, liquid_saturation, air_filled_porosity)

    active_volume = cohort_carbon(cohort, true) / parameters.litter_density
    inactive_volume =
        min(cohort[9] / parameters.litter_density, layer_thickness) -
        active_volume
    cohort_volume = active_volume + max(zero(active_volume), inactive_volume)

    unprotected_decomposition = if liquid_saturation == zero(liquid_saturation)
        zero(unprotected)
    else
        respiration_rates(
            parameters,
            unprotected,
            living_microbe,
            temperature,
            moisture,
            one(temperature),
        ) / seconds_per_year
    end
    protected_decomposition = if liquid_saturation == zero(liquid_saturation)
        zero(protected)
    else
        respiration_rates(
            parameters,
            protected,
            living_microbe,
            temperature,
            moisture,
            parameters.protected_decomposition_factor,
        ) / seconds_per_year
    end
    total_decomposition =
        unprotected_decomposition + protected_decomposition

    turnover = max(
        zero(living_microbe),
        (
            living_microbe -
            parameters.minimum_microbe_fraction * sum(unprotected)
        ) / parameters.microbe_turnover_time / seconds_per_year,
    )
    total_respiration_rate = sum(total_decomposition)
    if total_respiration_rate > zero(total_respiration_rate)
        weighted_inverse =
            total_decomposition[1] / total_respiration_rate /
            parameters.turnover_factor[1] +
            total_decomposition[2] / total_respiration_rate /
            parameters.turnover_factor[2] +
            total_decomposition[3] / total_respiration_rate /
            parameters.turnover_factor[3]
        turnover /= weighted_inverse
    end

    protected_turnover =
        protected / parameters.protected_turnover_time / seconds_per_year
    protection = if sum(unprotected) > zero(temperature) &&
                    cohort_volume > zero(temperature)
        parameters.protection_rate .* parameters.protection_species .* qmax .*
        unprotected / seconds_per_year
    else
        zero(unprotected)
    end

    microbial_litter_input =
        sum(litter_input) * parameters.minimum_microbe_fraction *
        litter_fraction
    substrate_input =
        litter_input .* (
            (one(litter_fraction) - parameters.minimum_microbe_fraction) *
            litter_fraction
        ) + exudate_input
    dead_microbe_input = turnover * parameters.turnover_efficiency
    unprotected_tendency =
        substrate_input -
        unprotected_decomposition -
        protection +
        protected_turnover
    unprotected_tendency = Base.setindex(
        unprotected_tendency,
        unprotected_tendency[3] + dead_microbe_input,
        3,
    )
    protected_tendency =
        protection - protected_decomposition - protected_turnover
    microbe_tendency =
        microbial_litter_input +
        sum(parameters.uptake_efficiency .* total_decomposition) -
        turnover
    respiration =
        sum(
            (one(temperature) .- parameters.uptake_efficiency) .*
            total_decomposition,
        ) + turnover * (one(temperature) - parameters.turnover_efficiency)
    original_carbon_tendency =
        sum(litter_input) * litter_fraction + sum(exudate_input)
    tendency = StaticArrays.SVector(
        unprotected_tendency[1],
        unprotected_tendency[2],
        unprotected_tendency[3],
        protected_tendency[1],
        protected_tendency[2],
        protected_tendency[3],
        microbe_tendency,
        respiration,
        original_carbon_tendency,
    )
    return (state = tendency, respiration = respiration, moisture = moisture)
end

"""
    daily_carbon_map(parameters, state, inputs, environment)

Apply the fixed two-cohort CORPSE map. State order is soil rhizosphere, soil
bulk, litter-layer rhizosphere, and litter-layer bulk. Each cohort contains
nine values in the order documented by [`cohort_carbon`](@ref).
"""
@inline function daily_carbon_map(parameters, state, inputs, environment)
    soil_rhiz = add_litter(
        parameters,
        state[1],
        inputs.root_litter,
        environment.rhizosphere_fraction,
    )
    soil_bulk = add_litter(
        parameters,
        state[2],
        inputs.root_litter,
        one(environment.rhizosphere_fraction) -
        environment.rhizosphere_fraction,
    )
    litter_rhiz = add_litter(
        parameters,
        state[3],
        inputs.leaf_litter,
        one(environment.rhizosphere_fraction),
    )
    litter_bulk = add_litter(
        parameters,
        state[4],
        inputs.leaf_litter,
        zero(environment.rhizosphere_fraction),
    )
    soil_rhiz = add_exudate(soil_rhiz, inputs.exudate)

    next_soil_rhiz = update_cohort(
        parameters,
        soil_rhiz,
        environment.temperature,
        environment.liquid_saturation,
        environment.air_filled_porosity,
        environment.qmax,
        environment.layer_thickness,
    )
    next_soil_bulk = update_cohort(
        parameters,
        soil_bulk,
        environment.temperature,
        environment.liquid_saturation,
        environment.air_filled_porosity,
        environment.qmax,
        environment.layer_thickness,
    )
    next_litter_rhiz = update_cohort(
        parameters,
        litter_rhiz,
        environment.temperature,
        environment.liquid_saturation,
        environment.air_filled_porosity,
        zero(environment.qmax),
        environment.layer_thickness,
    )
    next_litter_bulk = update_cohort(
        parameters,
        litter_bulk,
        environment.temperature,
        environment.liquid_saturation,
        environment.air_filled_porosity,
        zero(environment.qmax),
        environment.layer_thickness,
    )
    respiration =
        next_soil_rhiz.respiration +
        next_soil_bulk.respiration +
        next_litter_rhiz.respiration +
        next_litter_bulk.respiration
    return (
        state = (
            next_soil_rhiz.state,
            next_soil_bulk.state,
            next_litter_rhiz.state,
            next_litter_bulk.state,
        ),
        respiration = respiration,
        moisture = next_soil_rhiz.moisture,
    )
end

@inline cohort_state(a, b, c, d, e, f, g, h, i) =
    StaticArrays.SVector(a, b, c, d, e, f, g, h, i)

"""
    continuous_carbon_fluxes(parameters, state..., drivers...)

Return the 37 prognostic tendencies, total heterotrophic respiration, and
moisture factor for the simultaneous CORPSE ODE. Unlike
`combined_carbon_fluxes`, the result is an instantaneous rate and does
not depend on or encode a numerical timestep.
"""
@inline function continuous_carbon_fluxes(
    parameters,
    c_litter_cwd,
    soil_rhiz,
    soil_bulk,
    litter_rhiz,
    litter_bulk,
    soil_temperature,
    liquid_saturation,
    frozen_saturation,
    leaf_labile_input,
    leaf_recalcitrant_input,
    root_labile_input,
    root_recalcitrant_input,
    exudate_labile_input,
    litter_cwd_input,
)
    temperature = CASA.temperature_factor(
        parameters.cwd_q10,
        soil_temperature,
        parameters.freezing_temperature,
    )
    cwd_moisture = CASA.moisture_factor(liquid_saturation, false)
    cwd_loss =
        parameters.cwd_base_rate *
        parameters.cwd_litter_optimum *
        temperature *
        cwd_moisture *
        c_litter_cwd
    cwd_respiration = parameters.cwd_respiration_fraction * cwd_loss
    cwd_to_recalcitrant = cwd_loss - cwd_respiration
    cwd_tendency = litter_cwd_input - cwd_loss

    total_labile =
        root_labile_input +
        (
            parameters.litter_option == 1 ?
            leaf_labile_input : zero(leaf_labile_input)
        )
    exudate = min(exudate_labile_input, total_labile)
    total_labile -= exudate
    if parameters.litter_option == 1
        root_litter = StaticArrays.SVector(
            total_labile,
            root_recalcitrant_input +
            leaf_recalcitrant_input +
            cwd_to_recalcitrant,
            zero(total_labile),
        )
        leaf_litter = zero(root_litter)
    else
        root_litter = StaticArrays.SVector(
            total_labile,
            root_recalcitrant_input + cwd_to_recalcitrant,
            zero(total_labile),
        )
        leaf_litter = StaticArrays.SVector(
            leaf_labile_input,
            leaf_recalcitrant_input,
            zero(leaf_labile_input),
        )
    end
    exudate_input =
        StaticArrays.SVector(exudate, zero(exudate), zero(exudate))
    no_exudate = zero(exudate_input)
    air_filled_porosity = max(
        zero(liquid_saturation),
        one(liquid_saturation) - liquid_saturation - frozen_saturation,
    )
    carbon = parameters.carbon
    rhizosphere_fraction = parameters.rhizosphere_fraction
    soil_rhiz_tendency = continuous_cohort_tendencies(
        carbon,
        soil_rhiz,
        root_litter,
        exudate_input,
        rhizosphere_fraction,
        soil_temperature,
        liquid_saturation,
        air_filled_porosity,
        parameters.mineral_protection_capacity,
        parameters.layer_thickness,
    )
    soil_bulk_tendency = continuous_cohort_tendencies(
        carbon,
        soil_bulk,
        root_litter,
        no_exudate,
        one(rhizosphere_fraction) - rhizosphere_fraction,
        soil_temperature,
        liquid_saturation,
        air_filled_porosity,
        parameters.mineral_protection_capacity,
        parameters.layer_thickness,
    )
    litter_rhiz_tendency = continuous_cohort_tendencies(
        carbon,
        litter_rhiz,
        leaf_litter,
        no_exudate,
        one(rhizosphere_fraction),
        soil_temperature,
        liquid_saturation,
        air_filled_porosity,
        zero(parameters.mineral_protection_capacity),
        parameters.layer_thickness,
    )
    litter_bulk_tendency = continuous_cohort_tendencies(
        carbon,
        litter_bulk,
        leaf_litter,
        no_exudate,
        zero(rhizosphere_fraction),
        soil_temperature,
        liquid_saturation,
        air_filled_porosity,
        zero(parameters.mineral_protection_capacity),
        parameters.layer_thickness,
    )
    respiration =
        cwd_respiration +
        soil_rhiz_tendency.respiration +
        soil_bulk_tendency.respiration +
        litter_rhiz_tendency.respiration +
        litter_bulk_tendency.respiration
    return StaticArrays.SVector(
        cwd_tendency,
        Tuple(soil_rhiz_tendency.state)...,
        Tuple(soil_bulk_tendency.state)...,
        Tuple(litter_rhiz_tendency.state)...,
        Tuple(litter_bulk_tendency.state)...,
        respiration,
        soil_rhiz_tendency.moisture,
    )
end

@inline function combined_carbon_fluxes(
    parameters,
    c_litter_cwd,
    soil_rhiz,
    soil_bulk,
    litter_rhiz,
    litter_bulk,
    soil_temperature,
    liquid_saturation,
    frozen_saturation,
    leaf_labile_input,
    leaf_recalcitrant_input,
    root_labile_input,
    root_recalcitrant_input,
    exudate_labile_input,
    litter_cwd_input,
)
    seconds_per_day = oftype(c_litter_cwd, 86400)
    temperature = CASA.temperature_factor(
        parameters.cwd_q10,
        soil_temperature,
        parameters.freezing_temperature,
    )
    cwd_moisture = CASA.moisture_factor(liquid_saturation, false)
    cwd_fraction =
        parameters.cwd_base_rate *
        seconds_per_day *
        parameters.cwd_litter_optimum *
        temperature *
        cwd_moisture
    cwd_loss = min(cwd_fraction * c_litter_cwd, c_litter_cwd)
    cwd_respiration = parameters.cwd_respiration_fraction * cwd_loss
    cwd_to_recalcitrant = cwd_loss - cwd_respiration
    next_cwd = c_litter_cwd + litter_cwd_input * seconds_per_day - cwd_loss

    leaf_labile = leaf_labile_input * seconds_per_day
    leaf_recalcitrant = leaf_recalcitrant_input * seconds_per_day
    root_labile = root_labile_input * seconds_per_day
    root_recalcitrant = root_recalcitrant_input * seconds_per_day
    requested_exudate = exudate_labile_input * seconds_per_day
    total_labile =
        root_labile +
        (parameters.litter_option == 1 ? leaf_labile : zero(leaf_labile))
    exudate = min(requested_exudate, total_labile)
    total_labile -= exudate

    if parameters.litter_option == 1
        root_litter = StaticArrays.SVector(
            total_labile,
            root_recalcitrant + leaf_recalcitrant + cwd_to_recalcitrant,
            zero(total_labile),
        )
        leaf_litter = zero(root_litter)
    else
        root_litter = StaticArrays.SVector(
            total_labile,
            root_recalcitrant + cwd_to_recalcitrant,
            zero(total_labile),
        )
        leaf_litter = StaticArrays.SVector(
            leaf_labile,
            leaf_recalcitrant,
            zero(leaf_labile),
        )
    end
    inputs = (;
        root_litter,
        leaf_litter,
        exudate = StaticArrays.SVector(exudate, zero(exudate), zero(exudate)),
    )
    air_filled_porosity = max(
        zero(liquid_saturation),
        one(liquid_saturation) - liquid_saturation - frozen_saturation,
    )
    environment = (;
        rhizosphere_fraction = parameters.rhizosphere_fraction,
        temperature = soil_temperature,
        liquid_saturation,
        air_filled_porosity,
        qmax = parameters.mineral_protection_capacity,
        layer_thickness = parameters.layer_thickness,
    )
    state = (soil_rhiz, soil_bulk, litter_rhiz, litter_bulk)
    mapped = daily_carbon_map(parameters.carbon, state, inputs, environment)
    next_values = (
        next_cwd,
        Tuple(mapped.state[1])...,
        Tuple(mapped.state[2])...,
        Tuple(mapped.state[3])...,
        Tuple(mapped.state[4])...,
    )
    previous_values = (
        c_litter_cwd,
        Tuple(soil_rhiz)...,
        Tuple(soil_bulk)...,
        Tuple(litter_rhiz)...,
        Tuple(litter_bulk)...,
    )
    tendencies =
        StaticArrays.SVector{37}(next_values) -
        StaticArrays.SVector{37}(previous_values)
    tendencies /= seconds_per_day
    respiration = (mapped.respiration + cwd_respiration) / seconds_per_day
    return StaticArrays.SVector(
        Tuple(tendencies)...,
        respiration,
        mapped.moisture,
    )
end

@inline carbon_fluxes(::LegacyDaily, args...) = combined_carbon_fluxes(args...)
@inline carbon_fluxes(::ContinuousRate, args...) =
    continuous_carbon_fluxes(args...)

function ClimaLand.make_update_aux(model::CORPSESoilModel)
    function update_aux!(p, Y, t)
        drivers = model.drivers
        parameters = model.parameters
        temporal_mode = model.temporal_mode
        soil_temperature = drivers.soil_temperature(t)
        liquid_saturation = drivers.liquid_saturation(t)
        frozen_saturation = drivers.frozen_saturation(t)
        leaf_labile = drivers.leaf_labile(t)
        leaf_recalcitrant = drivers.leaf_recalcitrant(t)
        root_labile = drivers.root_labile(t)
        root_recalcitrant = drivers.root_recalcitrant(t)
        exudate_labile = drivers.exudate_labile(t)
        litter_cwd = drivers.litter_cwd(t)

        @. p.corpse_soil.soil_temperature = soil_temperature
        @. p.corpse_soil.liquid_saturation = liquid_saturation
        @. p.corpse_soil.frozen_saturation = frozen_saturation
        update_carbon_fluxes!(
            p,
            Y,
            temporal_mode,
            parameters,
            leaf_labile,
            leaf_recalcitrant,
            root_labile,
            root_recalcitrant,
            exudate_labile,
            litter_cwd,
        )
    end
    return update_aux!
end

function update_carbon_fluxes!(
    p,
    Y,
    temporal_mode,
    parameters,
    leaf_labile,
    leaf_recalcitrant,
    root_labile,
    root_recalcitrant,
    exudate_labile,
    litter_cwd,
)
    @. p.corpse_soil.leaf_labile_input = leaf_labile
    @. p.corpse_soil.leaf_recalcitrant_input = leaf_recalcitrant
    @. p.corpse_soil.root_labile_input = root_labile
    @. p.corpse_soil.root_recalcitrant_input = root_recalcitrant
    @. p.corpse_soil.exudate_labile_input = exudate_labile
    @. p.corpse_soil.litter_cwd_input = litter_cwd
    @. p.corpse_soil.carbon_fluxes = carbon_fluxes(
        temporal_mode,
        parameters,
        Y.corpse_soil.c_litter_cwd,
        cohort_state(
            Y.corpse_soil.soil_rhiz_unprotected_labile,
            Y.corpse_soil.soil_rhiz_unprotected_recalcitrant,
            Y.corpse_soil.soil_rhiz_unprotected_dead_microbe,
            Y.corpse_soil.soil_rhiz_protected_labile,
            Y.corpse_soil.soil_rhiz_protected_recalcitrant,
            Y.corpse_soil.soil_rhiz_protected_dead_microbe,
            Y.corpse_soil.soil_rhiz_live_microbe,
            Y.corpse_soil.soil_rhiz_cumulative_co2,
            Y.corpse_soil.soil_rhiz_original_carbon,
        ),
        cohort_state(
            Y.corpse_soil.soil_bulk_unprotected_labile,
            Y.corpse_soil.soil_bulk_unprotected_recalcitrant,
            Y.corpse_soil.soil_bulk_unprotected_dead_microbe,
            Y.corpse_soil.soil_bulk_protected_labile,
            Y.corpse_soil.soil_bulk_protected_recalcitrant,
            Y.corpse_soil.soil_bulk_protected_dead_microbe,
            Y.corpse_soil.soil_bulk_live_microbe,
            Y.corpse_soil.soil_bulk_cumulative_co2,
            Y.corpse_soil.soil_bulk_original_carbon,
        ),
        cohort_state(
            Y.corpse_soil.litter_rhiz_unprotected_labile,
            Y.corpse_soil.litter_rhiz_unprotected_recalcitrant,
            Y.corpse_soil.litter_rhiz_unprotected_dead_microbe,
            Y.corpse_soil.litter_rhiz_protected_labile,
            Y.corpse_soil.litter_rhiz_protected_recalcitrant,
            Y.corpse_soil.litter_rhiz_protected_dead_microbe,
            Y.corpse_soil.litter_rhiz_live_microbe,
            Y.corpse_soil.litter_rhiz_cumulative_co2,
            Y.corpse_soil.litter_rhiz_original_carbon,
        ),
        cohort_state(
            Y.corpse_soil.litter_bulk_unprotected_labile,
            Y.corpse_soil.litter_bulk_unprotected_recalcitrant,
            Y.corpse_soil.litter_bulk_unprotected_dead_microbe,
            Y.corpse_soil.litter_bulk_protected_labile,
            Y.corpse_soil.litter_bulk_protected_recalcitrant,
            Y.corpse_soil.litter_bulk_protected_dead_microbe,
            Y.corpse_soil.litter_bulk_live_microbe,
            Y.corpse_soil.litter_bulk_cumulative_co2,
            Y.corpse_soil.litter_bulk_original_carbon,
        ),
        p.corpse_soil.soil_temperature,
        p.corpse_soil.liquid_saturation,
        p.corpse_soil.frozen_saturation,
        leaf_labile,
        leaf_recalcitrant,
        root_labile,
        root_recalcitrant,
        exudate_labile,
        litter_cwd,
    )
    return nothing
end

function ClimaLand.make_compute_exp_tendency(::CORPSESoilModel)
    function compute_exp_tendency!(dY, Y, p, t)
        fluxes = p.corpse_soil.carbon_fluxes
        for (index, variable) in enumerate(PROGNOSTIC_VARIABLES)
            destination = getproperty(dY.corpse_soil, variable)
            @. destination = getindex(fluxes, index)
        end
    end
    return compute_exp_tendency!
end

end
