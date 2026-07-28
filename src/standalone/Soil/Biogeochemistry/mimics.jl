module MIMICS

import StaticArrays
import ClimaCore

import ..Biogeochemistry
import ..CASA
import ....ClimaLand

export CarbonParameters,
    CarbonNitrogen,
    CarbonOnly,
    ContinuousRate,
    LegacyDaily,
    MIMICSSoilModel,
    MIMICSSoilModelParameters,
    NitrogenParameters,
    NitrogenPrescribedDrivers,
    PrescribedDrivers,
    TemporalMode,
    continuous_carbon_fluxes,
    cwd_to_structural_flux,
    daily_carbon_map,
    daily_carbon_nitrogen_map,
    environmental_parameters,
    hourly_carbon_map,
    hourly_carbon_nitrogen_map,
    moisture_factor

"""
    TemporalMode

Compile-time strategy for evaluating standalone MIMICS carbon processes.

Concrete subtypes:
- [`LegacyDaily`](@ref): Apply the ordered reference map.
- [`ContinuousRate`](@ref): Evaluate the simultaneous carbon-only ODE.

Subtypes implement `carbon_fluxes(::Subtype, args...)` to select their point
kernel and must remain immutable singleton dispatch types.
"""
abstract type TemporalMode end

"""
    LegacyDaily <: TemporalMode

Select the exact ordered one-day map used by the reference Fortran testbed.

# Examples
```julia
using ClimaLand
MIMICS = ClimaLand.Soil.Biogeochemistry.MIMICS
mode = MIMICS.LegacyDaily()
```
"""
struct LegacyDaily <: TemporalMode end

"""
    ContinuousRate <: TemporalMode

Select the timestep-independent, simultaneous MIMICS carbon ODE.

# Examples
```julia
using ClimaLand
MIMICS = ClimaLand.Soil.Biogeochemistry.MIMICS
mode = MIMICS.ContinuousRate()
```
"""
struct ContinuousRate <: TemporalMode end

"""
    CarbonParameters{FT}

Parameters for the carbon-only MIMICS reverse Michaelis--Menten map. Kinetic
rates use the legacy hourly units and pool concentrations use mg C cm⁻³.
"""
Base.@kwdef struct CarbonParameters{FT <: AbstractFloat}
    vmax_slope::NTuple{6, FT}
    vmax_intercept::NTuple{6, FT}
    vmax_prefactor::NTuple{6, FT}
    vmax_modifier::NTuple{6, FT}
    km_slope::NTuple{6, FT}
    km_intercept::NTuple{6, FT}
    km_prefactor::NTuple{6, FT}
    km_modifier::NTuple{6, FT}
    oxidation_modifier::NTuple{2, FT}
    microbial_growth_efficiency::NTuple{4, FT}
    r_turnover::NTuple{2, FT}
    k_turnover::NTuple{2, FT}
    turnover_npp_denominator::FT
    turnover_modifier_minimum::FT
    turnover_modifier_maximum::FT
    r_physical_partition::NTuple{2, FT}
    k_physical_partition::NTuple{2, FT}
    r_chemical_partition::NTuple{3, FT}
    k_chemical_partition::NTuple{3, FT}
    desorption::NTuple{2, FT}
    physical_scalar::NTuple{2, FT}
    input_protection::NTuple{2, FT}
    depth_cm::FT
end


@inline function cwd_to_structural_flux(
    parameters,
    c_litter_cwd,
    soil_temperature,
    liquid_saturation,
)
    temperature = CASA.temperature_factor(
        parameters.cwd_q10,
        soil_temperature,
        parameters.freezing_temperature,
    )
    moisture = CASA.moisture_factor(liquid_saturation, false)
    loss =
        parameters.cwd_base_rate *
        parameters.cwd_litter_optimum *
        temperature *
        moisture *
        c_litter_cwd
    return (one(loss) - parameters.cwd_respiration_fraction) * loss
end

Base.broadcastable(parameters::CarbonParameters) = tuple(parameters)

"""
    NitrogenParameters{FT}

Parameters for the ordered MIMICS carbon-nitrogen map. Nitrogen-use
efficiencies and the mineral-N available fraction are dimensionless;
microbial ratios use C:N.
"""
Base.@kwdef struct NitrogenParameters{FT <: AbstractFloat}
    nitrogen_use_efficiency::NTuple{4, FT}
    microbial_carbon_nitrogen_ratio::NTuple{2, FT}
    carbon_nitrogen_modifier::FT
    mineral_nitrogen_available_fraction::FT
    microbial_turnover_density_exponent::FT
    maximum_fine_litter::FT = FT(0.157)
    maximum_cwd::FT = FT(0.107)
    loss_threshold::FT = FT(2e-3)
    loss_fraction::FT = FT(0.05)
    leach_rate::FT = FT(10 * 0.05 / 365 / 86400)
end

Base.broadcastable(parameters::NitrogenParameters) = tuple(parameters)

"""
    MIMICSSoilModelParameters{FT}

Point parameters for the standalone MIMICS model. Surface-pool
rates use inverse seconds; MIMICS kinetic parameters retain their legacy
hourly concentration units inside the ordered daily map. A `MIMICSSoilModel`
accepts either one parameter instance or a surface `ClimaCore.Fields.Field` of
instances.
"""
Base.@kwdef struct MIMICSSoilModelParameters{
    FT <: AbstractFloat,
    CP <: CarbonParameters{FT},
}
    carbon::CP
    clay::FT
    freezing_temperature::FT
    cwd_q10::FT
    cwd_litter_optimum::FT
    cwd_base_rate::FT
    cwd_respiration_fraction::FT
end

Base.broadcastable(parameters::MIMICSSoilModelParameters) = tuple(parameters)

"""
    PrescribedDrivers

Time-dependent standalone drivers. Temperatures use K, moisture values are
fractions of saturation, litter inputs use kg C m⁻² s⁻¹, and annual NPP
uses kg C m⁻² yr⁻¹.
"""
struct PrescribedDrivers{T, L, F, M, S, C, Q, N}
    soil_temperature::T
    liquid_saturation::L
    frozen_saturation::F
    litter_metabolic::M
    litter_structural::S
    litter_cwd::C
    litter_metabolic_fraction::Q
    annual_npp::N
end

"""
    NitrogenPrescribedDrivers

Time-dependent MIMICS nitrogen boundary fluxes in kg N m⁻² s⁻¹. CWD N is
the plant wood-turnover input; its decomposition enters structural MIMICS
litter internally.
"""
struct NitrogenPrescribedDrivers{M, S, C, D, F, U}
    litter_metabolic::M
    litter_structural::S
    litter_cwd::C
    deposition::D
    fixation::F
    plant_uptake::U
end

const CarbonOnly = Biogeochemistry.CarbonOnly
const CarbonNitrogen = Biogeochemistry.CarbonNitrogen

"""
    MIMICSSoilModel{FT}(; parameters, drivers, domain, temporal_mode)

Standalone MIMICS model with seven MIMICS pools and the coarse woody debris
pool used by the testbed coupling. `CarbonNitrogen()` adds their nitrogen
states and one mineral-N owner. `temporal_mode = LegacyDaily()` preserves the
ordered reference map; `ContinuousRate()` selects a simultaneous,
timestep-independent carbon-only ODE.
"""
struct MIMICSSoilModel{FT, C, PS, NP, D, DR, NR, TM} <:
       Biogeochemistry.AbstractSoilBiogeochemistryModel{FT}
    configuration::C
    parameters::PS
    nitrogen_parameters::NP
    domain::D
    drivers::DR
    nitrogen_drivers::NR
    temporal_mode::TM
end

function MIMICSSoilModel{FT}(;
    configuration = CarbonOnly(),
    parameters,
    nitrogen_parameters = nothing,
    drivers,
    nitrogen_drivers = nothing,
    domain::ClimaLand.Domains.AbstractDomain{FT} = ClimaLand.Domains.Point(;
        z_sfc = zero(FT),
    ),
    temporal_mode::TemporalMode = LegacyDaily(),
) where {FT}
    @assert parameters isa MIMICSSoilModelParameters{FT} || (
        parameters isa ClimaCore.Fields.Field &&
        eltype(parameters) <: MIMICSSoilModelParameters{FT}
    ) "parameters must be MIMICS point parameters or a Field of MIMICS point parameters"
    @assert !(parameters isa ClimaCore.Fields.Field) ||
            axes(parameters) == domain.space.surface "spatial MIMICS parameters must use the model surface space"
    if configuration isa CarbonNitrogen
        temporal_mode isa LegacyDaily ||
            error("ContinuousRate is available only for carbon-only MIMICS")
        @assert nitrogen_parameters isa NitrogenParameters{FT} || (
            nitrogen_parameters isa ClimaCore.Fields.Field &&
            eltype(nitrogen_parameters) <: NitrogenParameters{FT}
        ) "nitrogen_parameters must be MIMICS nitrogen point parameters or a Field"
        @assert nitrogen_drivers isa NitrogenPrescribedDrivers
        @assert !(nitrogen_parameters isa ClimaCore.Fields.Field) ||
                axes(nitrogen_parameters) == domain.space.surface "spatial MIMICS nitrogen parameters must use the model surface space"
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
    return MIMICSSoilModel{FT, typeof.(args)...}(args...)
end

ClimaLand.name(::MIMICSSoilModel) = :mimics_soil

ClimaLand.prognostic_vars(::MIMICSSoilModel{FT, CarbonOnly}) where {FT} = (
    :c_litter_metabolic,
    :c_litter_structural,
    :c_litter_cwd,
    :c_microbe_r,
    :c_microbe_k,
    :c_soil_available,
    :c_soil_chemical,
    :c_soil_physical,
)
ClimaLand.prognostic_vars(::MIMICSSoilModel{FT, CarbonNitrogen}) where {FT} = (
    :c_litter_metabolic,
    :c_litter_structural,
    :c_litter_cwd,
    :c_microbe_r,
    :c_microbe_k,
    :c_soil_available,
    :c_soil_chemical,
    :c_soil_physical,
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
ClimaLand.prognostic_types(::MIMICSSoilModel{FT, CarbonOnly}) where {FT} =
    (FT, FT, FT, FT, FT, FT, FT, FT)
ClimaLand.prognostic_types(::MIMICSSoilModel{FT, CarbonNitrogen}) where {FT} =
    ntuple(_ -> FT, 17)
ClimaLand.prognostic_domain_names(model::MIMICSSoilModel) =
    ntuple(_ -> :surface, length(ClimaLand.prognostic_vars(model)))

ClimaLand.auxiliary_vars(::MIMICSSoilModel{FT, CarbonOnly}) where {FT} = (
    :soil_temperature,
    :liquid_saturation,
    :frozen_saturation,
    :litter_metabolic_input,
    :litter_structural_input,
    :litter_cwd_input,
    :litter_metabolic_fraction,
    :annual_npp,
    :carbon_fluxes,
)
ClimaLand.auxiliary_vars(::MIMICSSoilModel{FT, CarbonNitrogen}) where {FT} = (
    :soil_temperature,
    :liquid_saturation,
    :frozen_saturation,
    :litter_metabolic_input,
    :litter_structural_input,
    :litter_cwd_input,
    :litter_metabolic_fraction,
    :annual_npp,
    :nitrogen_litter_metabolic_input,
    :nitrogen_litter_structural_input,
    :nitrogen_litter_cwd_input,
    :nitrogen_deposition,
    :nitrogen_fixation,
    :nitrogen_plant_uptake,
    :combined_fluxes,
    :carbon_fluxes,
    :nitrogen_fluxes,
)
ClimaLand.auxiliary_types(::MIMICSSoilModel{FT, CarbonOnly}) where {FT} =
    (FT, FT, FT, FT, FT, FT, FT, FT, StaticArrays.SVector{17, FT})
ClimaLand.auxiliary_types(::MIMICSSoilModel{FT, CarbonNitrogen}) where {FT} = (
    ntuple(_ -> FT, 14)...,
    StaticArrays.SVector{29, FT},
    StaticArrays.SVector{10, FT},
    StaticArrays.SVector{14, FT},
)
ClimaLand.auxiliary_domain_names(model::MIMICSSoilModel) =
    ntuple(_ -> :surface, length(ClimaLand.auxiliary_vars(model)))

"""
    moisture_factor(liquid_saturation, frozen_saturation)

Return the CORPSE-style moisture multiplier used by the archived MIMICS run.
"""
@inline function moisture_factor(liquid_saturation, frozen_saturation)
    air_filled = max(
        zero(liquid_saturation),
        one(liquid_saturation) - liquid_saturation - frozen_saturation,
    )
    normalization = oftype(liquid_saturation, 0.022600567942709)
    value = liquid_saturation^3 * air_filled^oftype(air_filled, 2.5)
    return max(oftype(value, 0.05), value / normalization)
end

"""
    environmental_parameters(
        parameters,
        soil_temperature_c,
        liquid_saturation,
        frozen_saturation,
        litter_metabolic_fraction,
        annual_npp,
        clay,
    )

Compute the hourly kinetic and transfer parameters used for one legacy day.
`annual_npp` uses g C m⁻² yr⁻¹ and `clay` is a mass fraction.
"""
@inline function environmental_parameters(
    parameters,
    soil_temperature_c,
    liquid_saturation,
    frozen_saturation,
    litter_metabolic_fraction,
    annual_npp,
    clay,
)
    water = moisture_factor(liquid_saturation, frozen_saturation)
    turnover_modifier = clamp(
        sqrt(
            max(zero(annual_npp), annual_npp) /
            parameters.turnover_npp_denominator,
        ),
        parameters.turnover_modifier_minimum,
        parameters.turnover_modifier_maximum,
    )
    physical_scalar =
        parameters.physical_scalar[1] *
        exp(parameters.physical_scalar[2] * sqrt(clay))
    km_modifier = (
        parameters.km_modifier[1],
        parameters.km_modifier[2],
        parameters.km_modifier[3] * physical_scalar,
        parameters.km_modifier[4],
        parameters.km_modifier[5],
        parameters.km_modifier[6] * physical_scalar,
    )
    vmax = ntuple(6) do index
        exp(
            parameters.vmax_slope[index] * soil_temperature_c +
            parameters.vmax_intercept[index],
        ) *
        parameters.vmax_prefactor[index] *
        parameters.vmax_modifier[index] *
        water
    end
    km = ntuple(6) do index
        exp(
            parameters.km_slope[index] * soil_temperature_c +
            parameters.km_intercept[index],
        ) * parameters.km_prefactor[index] / km_modifier[index]
    end
    r_physical =
        parameters.r_physical_partition[1] *
        exp(parameters.r_physical_partition[2] * clay)
    k_physical =
        parameters.k_physical_partition[1] *
        exp(parameters.k_physical_partition[2] * clay)
    r_chemical =
        parameters.r_chemical_partition[1] *
        exp(parameters.r_chemical_partition[2] * litter_metabolic_fraction) *
        parameters.r_chemical_partition[3]
    k_chemical =
        parameters.k_chemical_partition[1] *
        exp(parameters.k_chemical_partition[2] * litter_metabolic_fraction) *
        parameters.k_chemical_partition[3]
    r_available = one(r_physical) - r_physical - r_chemical
    k_available = one(k_physical) - k_physical - k_chemical
    r_turnover =
        parameters.r_turnover[1] *
        exp(parameters.r_turnover[2] * litter_metabolic_fraction) *
        turnover_modifier *
        water
    k_turnover =
        parameters.k_turnover[1] *
        exp(parameters.k_turnover[2] * litter_metabolic_fraction) *
        turnover_modifier *
        water
    desorption = parameters.desorption[1] * exp(parameters.desorption[2] * clay)
    return (
        vmax = vmax,
        km = km,
        r_turnover = r_turnover,
        k_turnover = k_turnover,
        r_partition = (r_physical, r_chemical, r_available),
        k_partition = (k_physical, k_chemical, k_available),
        desorption = desorption,
        moisture = water,
        litter_metabolic_fraction = litter_metabolic_fraction,
    )
end

"""
    hourly_carbon_map(parameters, state, daily_inputs, environment)

Apply one of the 24 ordered hourly updates in `mimics_soil_reverseMM`. State
order is LITm, LITs, MICr, MICk, SOMa, SOMc, SOMp.
"""
@inline function hourly_carbon_map(parameters, state, daily_inputs, environment)
    lit_m, lit_s, mic_r, mic_k, som_a, som_c, som_p = state
    vmax = environment.vmax
    km = environment.km

    litter_r_m = mic_r * vmax[1] * lit_m / (km[1] + mic_r)
    litter_r_s = mic_r * vmax[2] * lit_s / (km[2] + mic_r)
    soil_r = mic_r * vmax[3] * som_a / (km[3] + mic_r)
    litter_k_m = mic_k * vmax[4] * lit_m / (km[4] + mic_k)
    litter_k_s = mic_k * vmax[5] * lit_s / (km[5] + mic_k)
    soil_k = mic_k * vmax[6] * som_a / (km[6] + mic_k)

    r_loss = mic_r * environment.r_turnover
    k_loss = mic_k * environment.k_turnover
    r_to_p = r_loss * environment.r_partition[1]
    r_to_c = r_loss * environment.r_partition[2]
    r_to_a = r_loss * environment.r_partition[3]
    k_to_p = k_loss * environment.k_partition[1]
    k_to_c = k_loss * environment.k_partition[2]
    k_to_a = k_loss * environment.k_partition[3]
    desorption = som_p * environment.desorption
    oxidation =
        mic_k * vmax[5] * som_c /
        (parameters.oxidation_modifier[2] * km[5] + mic_k) +
        mic_r * vmax[2] * som_c /
        (parameters.oxidation_modifier[1] * km[2] + mic_r)

    mge = parameters.microbial_growth_efficiency
    hourly = inv(oftype(lit_m, 24))
    next_state = StaticArrays.SVector(
        lit_m +
        daily_inputs[1] *
        hourly *
        (one(lit_m) - parameters.input_protection[1]) - litter_r_m -
        litter_k_m,
        lit_s +
        daily_inputs[2] *
        hourly *
        (one(lit_s) - parameters.input_protection[2]) - litter_r_s -
        litter_k_s,
        mic_r + mge[1] * (litter_r_m + soil_r) + mge[2] * litter_r_s - r_loss,
        mic_k + mge[3] * (litter_k_m + soil_k) + mge[4] * litter_k_s - k_loss,
        som_a + r_to_a + k_to_a + desorption + oxidation - soil_r - soil_k,
        som_c +
        daily_inputs[2] * hourly * parameters.input_protection[2] +
        r_to_c +
        k_to_c - oxidation,
        som_p +
        daily_inputs[1] * hourly * parameters.input_protection[1] +
        r_to_p +
        k_to_p - desorption,
    )
    respiration =
        (one(mge[1]) - mge[1]) * (litter_r_m + soil_r) +
        (one(mge[2]) - mge[2]) * litter_r_s +
        (one(mge[3]) - mge[3]) * (litter_k_m + soil_k) +
        (one(mge[4]) - mge[4]) * litter_k_s
    processes = StaticArrays.SVector(
        r_loss,
        k_loss,
        daily_inputs[1] * hourly * parameters.input_protection[1] +
        r_to_p +
        k_to_p,
        daily_inputs[2] * hourly * parameters.input_protection[2] +
        r_to_c +
        k_to_c,
        desorption,
        oxidation,
    )
    return (; state = next_state, respiration, processes)
end


"""
    hourly_carbon_nitrogen_map(
        carbon_parameters,
        nitrogen_parameters,
        carbon,
        nitrogen,
        mineral_nitrogen,
        daily_carbon_inputs,
        daily_nitrogen_inputs,
        environment,
    )

Apply one ordered hourly update from `mimics_soil_reverseMM_CN`. Carbon and
nitrogen states are ordered as LITm, LITs, MICr, MICk, SOMa, SOMc, SOMp.
The mineral-N value is the MIMICS working DIN stock, not an additional
ecosystem prognostic pool.
"""
@inline function hourly_carbon_nitrogen_map(
    carbon_parameters,
    nitrogen_parameters,
    carbon,
    nitrogen,
    mineral_nitrogen,
    daily_carbon_inputs,
    daily_nitrogen_inputs,
    environment,
)
    lit_m, lit_s, mic_r, mic_k, som_a, som_c, som_p = carbon
    lit_m_n, lit_s_n, mic_r_n, mic_k_n, som_a_n, som_c_n, som_p_n = nitrogen
    vmax = environment.vmax
    km = environment.km
    small = oftype(lit_m, 1e-10)

    litter_r_m = mic_r * vmax[1] * lit_m / (km[1] + mic_r)
    litter_r_s = mic_r * vmax[2] * lit_s / (km[2] + mic_r)
    soil_r = mic_r * vmax[3] * som_a / (km[3] + mic_r)
    litter_k_m = mic_k * vmax[4] * lit_m / (km[4] + mic_k)
    litter_k_s = mic_k * vmax[5] * lit_s / (km[5] + mic_k)
    soil_k = mic_k * vmax[6] * som_a / (km[6] + mic_k)
    litter_r_m_n = litter_r_m * lit_m_n / (lit_m + small)
    litter_r_s_n = litter_r_s * lit_s_n / (lit_s + small)
    soil_r_n = soil_r * som_a_n / (som_a + small)
    litter_k_m_n = litter_k_m * lit_m_n / (lit_m + small)
    litter_k_s_n = litter_k_s * lit_s_n / (lit_s + small)
    soil_k_n = soil_k * som_a_n / (som_a + small)

    density = nitrogen_parameters.microbial_turnover_density_exponent
    r_loss = mic_r^density * environment.r_turnover
    k_loss = mic_k^density * environment.k_turnover
    r_to_p = r_loss * environment.r_partition[1]
    r_to_c = r_loss * environment.r_partition[2]
    r_to_a = r_loss * environment.r_partition[3]
    k_to_p = k_loss * environment.k_partition[1]
    k_to_c = k_loss * environment.k_partition[2]
    k_to_a = k_loss * environment.k_partition[3]
    r_loss_n = r_loss * mic_r_n / (mic_r + small)
    k_loss_n = k_loss * mic_k_n / (mic_k + small)
    r_to_p_n = r_loss_n * environment.r_partition[1]
    r_to_c_n = r_loss_n * environment.r_partition[2]
    r_to_a_n = r_loss_n * environment.r_partition[3]
    k_to_p_n = k_loss_n * environment.k_partition[1]
    k_to_c_n = k_loss_n * environment.k_partition[2]
    k_to_a_n = k_loss_n * environment.k_partition[3]

    desorption = som_p * environment.desorption
    desorption_n = desorption * som_p_n / (som_p + small)
    oxidation =
        mic_k * vmax[5] * som_c /
        (carbon_parameters.oxidation_modifier[2] * km[5] + mic_k) +
        mic_r * vmax[2] * som_c /
        (carbon_parameters.oxidation_modifier[1] * km[2] + mic_r)
    oxidation_n = oxidation * som_c_n / (som_c + small)

    microbial_total = mic_r + mic_k
    microbial_denominator =
        ifelse(iszero(microbial_total), one(microbial_total), microbial_total)
    din_r = mineral_nitrogen * mic_r / microbial_denominator
    din_k = mineral_nitrogen * mic_k / microbial_denominator
    mge = carbon_parameters.microbial_growth_efficiency
    nue = nitrogen_parameters.nitrogen_use_efficiency
    uptake_r_c = mge[1] * (litter_r_m + soil_r) + mge[2] * litter_r_s
    uptake_r_n =
        nue[1] * (litter_r_m_n + soil_r_n) + nue[2] * litter_r_s_n + din_r
    uptake_k_c = mge[3] * (litter_k_m + soil_k) + mge[4] * litter_k_s
    uptake_k_n =
        nue[3] * (litter_k_m_n + soil_k_n) + nue[4] * litter_k_s_n + din_k
    target_r =
        nitrogen_parameters.microbial_carbon_nitrogen_ratio[1] * sqrt(
            nitrogen_parameters.carbon_nitrogen_modifier /
            environment.litter_metabolic_fraction,
        )
    target_k =
        nitrogen_parameters.microbial_carbon_nitrogen_ratio[2] * sqrt(
            nitrogen_parameters.carbon_nitrogen_modifier /
            environment.litter_metabolic_fraction,
        )
    uptake_ratio_r = uptake_r_c / (uptake_r_n + small)
    uptake_ratio_k = uptake_k_c / (uptake_k_n + small)
    overflow_r = uptake_r_c - uptake_r_n * min(target_r, uptake_ratio_r)
    overflow_k = uptake_k_c - uptake_k_n * min(target_k, uptake_ratio_k)
    spill_r = uptake_r_n - uptake_r_c / max(target_r, uptake_ratio_r)
    spill_k = uptake_k_n - uptake_k_c / max(target_k, uptake_ratio_k)

    hourly = inv(oftype(lit_m, 24))
    protection = carbon_parameters.input_protection
    delta_lit_m =
        daily_carbon_inputs[1] * hourly * (one(lit_m) - protection[1]) -
        litter_r_m - litter_k_m
    delta_lit_s =
        daily_carbon_inputs[2] * hourly * (one(lit_s) - protection[2]) -
        litter_r_s - litter_k_s
    delta_mic_r = uptake_r_c - (r_to_p + r_to_c + r_to_a) - overflow_r
    delta_mic_k = uptake_k_c - (k_to_p + k_to_c + k_to_a) - overflow_k
    delta_som_a = r_to_a + k_to_a + desorption + oxidation - soil_r - soil_k
    delta_som_c =
        daily_carbon_inputs[2] * hourly * protection[2] + r_to_c + k_to_c -
        oxidation
    delta_som_p =
        daily_carbon_inputs[1] * hourly * protection[1] + r_to_p + k_to_p -
        desorption
    next_carbon = StaticArrays.SVector(
        lit_m + delta_lit_m,
        lit_s + delta_lit_s,
        mic_r + delta_mic_r,
        mic_k + delta_mic_k,
        som_a + delta_som_a,
        som_c + delta_som_c,
        som_p + delta_som_p,
    )
    delta_lit_m_n =
        daily_nitrogen_inputs[1] * hourly * (one(lit_m_n) - protection[1]) -
        litter_r_m_n - litter_k_m_n
    delta_lit_s_n =
        daily_nitrogen_inputs[2] * hourly * (one(lit_s_n) - protection[2]) -
        litter_r_s_n - litter_k_s_n
    delta_mic_r_n = uptake_r_n - (r_to_p_n + r_to_c_n + r_to_a_n) - spill_r
    delta_mic_k_n = uptake_k_n - (k_to_p_n + k_to_c_n + k_to_a_n) - spill_k
    delta_som_a_n =
        r_to_a_n + k_to_a_n + desorption_n + oxidation_n - soil_r_n - soil_k_n
    delta_som_c_n =
        daily_nitrogen_inputs[2] * hourly * protection[2] +
        r_to_c_n +
        k_to_c_n - oxidation_n
    delta_som_p_n =
        daily_nitrogen_inputs[1] * hourly * protection[1] +
        r_to_p_n +
        k_to_p_n - desorption_n
    next_nitrogen = StaticArrays.SVector(
        lit_m_n + delta_lit_m_n,
        lit_s_n + delta_lit_s_n,
        mic_r_n + delta_mic_r_n,
        mic_k_n + delta_mic_k_n,
        som_a_n + delta_som_a_n,
        som_c_n + delta_som_c_n,
        som_p_n + delta_som_p_n,
    )
    delta_mineral_nitrogen =
        (one(nue[1]) - nue[1]) * (litter_r_m_n + soil_r_n) +
        (one(nue[2]) - nue[2]) * litter_r_s_n +
        (one(nue[3]) - nue[3]) * (litter_k_m_n + soil_k_n) +
        (one(nue[4]) - nue[4]) * litter_k_s_n +
        spill_r +
        spill_k - din_r - din_k
    next_mineral_nitrogen = mineral_nitrogen + delta_mineral_nitrogen
    respiration =
        (one(mge[1]) - mge[1]) * (litter_r_m + soil_r) +
        (one(mge[2]) - mge[2]) * litter_r_s +
        (one(mge[3]) - mge[3]) * (litter_k_m + soil_k) +
        (one(mge[4]) - mge[4]) * litter_k_s +
        overflow_r +
        overflow_k
    physical_protection =
        daily_carbon_inputs[1] * hourly * protection[1] + r_to_p + k_to_p
    microbial_assimilation = uptake_r_c + uptake_k_c
    litter_mineralization =
        (one(nue[1]) - nue[1]) * litter_r_m_n +
        (one(nue[2]) - nue[2]) * litter_r_s_n +
        (one(nue[3]) - nue[3]) * litter_k_m_n +
        (one(nue[4]) - nue[4]) * litter_k_s_n
    soil_mineralization =
        (one(nue[1]) - nue[1]) * soil_r_n + (one(nue[3]) - nue[3]) * soil_k_n
    immobilization = -(din_r + din_k - spill_r - spill_k)
    return (;
        carbon = next_carbon,
        nitrogen = next_nitrogen,
        mineral_nitrogen = next_mineral_nitrogen,
        respiration,
        overflow_r,
        overflow_k,
        physical_protection,
        microbial_assimilation,
        litter_mineralization,
        soil_mineralization,
        immobilization,
    )
end


"""
    daily_carbon_nitrogen_map(
        carbon_parameters,
        nitrogen_parameters,
        carbon,
        nitrogen,
        mineral_nitrogen,
        daily_carbon_inputs,
        daily_nitrogen_inputs,
        environment,
    )

Apply the pinned sequence of 24 MIMICS-CN hourly updates. The returned
mineral-N value is the end-of-map working DIN stock.
"""
@inline function daily_carbon_nitrogen_map(
    carbon_parameters,
    nitrogen_parameters,
    carbon,
    nitrogen,
    mineral_nitrogen,
    daily_carbon_inputs,
    daily_nitrogen_inputs,
    environment,
)
    next_carbon = StaticArrays.SVector{7}(carbon)
    next_nitrogen = StaticArrays.SVector{7}(nitrogen)
    next_mineral_nitrogen = mineral_nitrogen
    respiration = zero(eltype(next_carbon))
    overflow_r = zero(respiration)
    overflow_k = zero(respiration)
    physical_protection = zero(respiration)
    microbial_assimilation = zero(respiration)
    litter_mineralization = zero(respiration)
    soil_mineralization = zero(respiration)
    immobilization = zero(respiration)
    for _ in 1:24
        step = hourly_carbon_nitrogen_map(
            carbon_parameters,
            nitrogen_parameters,
            next_carbon,
            next_nitrogen,
            next_mineral_nitrogen,
            daily_carbon_inputs,
            daily_nitrogen_inputs,
            environment,
        )
        next_carbon = step.carbon
        next_nitrogen = step.nitrogen
        next_mineral_nitrogen = step.mineral_nitrogen
        respiration += step.respiration
        overflow_r += step.overflow_r
        overflow_k += step.overflow_k
        physical_protection += step.physical_protection
        microbial_assimilation += step.microbial_assimilation
        litter_mineralization += step.litter_mineralization
        soil_mineralization += step.soil_mineralization
        immobilization += step.immobilization
    end
    return (;
        carbon = next_carbon,
        nitrogen = next_nitrogen,
        mineral_nitrogen = next_mineral_nitrogen,
        respiration,
        overflow_r,
        overflow_k,
        physical_protection,
        microbial_assimilation,
        litter_mineralization,
        soil_mineralization,
        immobilization,
    )
end

"""
    daily_carbon_map(parameters, state, daily_inputs, environment)

Apply the pinned 24-hour MIMICS map and return the next state and total daily
heterotrophic respiration in the same concentration units as `state`.
"""
@inline function daily_carbon_map(parameters, state, daily_inputs, environment)
    next_state = StaticArrays.SVector{7}(state)
    respiration = zero(eltype(next_state))
    processes = zero(StaticArrays.SVector{6, eltype(next_state)})
    for _ in 1:24
        step =
            hourly_carbon_map(parameters, next_state, daily_inputs, environment)
        next_state = step.state
        respiration += step.respiration
        processes += step.processes
    end
    return (; state = next_state, respiration, processes)
end

@inline function combined_carbon_fluxes(
    parameters,
    c_litter_metabolic,
    c_litter_structural,
    c_litter_cwd,
    c_microbe_r,
    c_microbe_k,
    c_soil_available,
    c_soil_chemical,
    c_soil_physical,
    soil_temperature,
    liquid_saturation,
    frozen_saturation,
    litter_metabolic_input,
    litter_structural_input,
    litter_cwd_input,
    litter_metabolic_fraction,
    annual_npp,
)
    carbon = parameters.carbon
    seconds_per_day = oftype(c_litter_cwd, 86400)
    concentration_factor = oftype(c_litter_cwd, 100) / carbon.depth_cm
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
    cwd_loss = cwd_fraction * c_litter_cwd
    cwd_respiration = parameters.cwd_respiration_fraction * cwd_loss
    cwd_to_structural = cwd_loss - cwd_respiration

    environment = environmental_parameters(
        carbon,
        soil_temperature - parameters.freezing_temperature,
        liquid_saturation,
        frozen_saturation,
        litter_metabolic_fraction,
        annual_npp * oftype(annual_npp, 1000),
        parameters.clay,
    )
    state = StaticArrays.SVector(
        c_litter_metabolic * concentration_factor,
        c_litter_structural * concentration_factor,
        c_microbe_r * concentration_factor,
        c_microbe_k * concentration_factor,
        c_soil_available * concentration_factor,
        c_soil_chemical * concentration_factor,
        c_soil_physical * concentration_factor,
    )
    daily_inputs = (
        litter_metabolic_input * seconds_per_day * concentration_factor,
        (litter_structural_input * seconds_per_day + cwd_to_structural) *
        concentration_factor,
    )
    mapped = daily_carbon_map(carbon, state, daily_inputs, environment)
    inverse_factor = inv(concentration_factor)
    next_cwd = c_litter_cwd + litter_cwd_input * seconds_per_day - cwd_loss
    tendencies = StaticArrays.SVector(
        (mapped.state[1] * inverse_factor - c_litter_metabolic) /
        seconds_per_day,
        (mapped.state[2] * inverse_factor - c_litter_structural) /
        seconds_per_day,
        (next_cwd - c_litter_cwd) / seconds_per_day,
        (mapped.state[3] * inverse_factor - c_microbe_r) / seconds_per_day,
        (mapped.state[4] * inverse_factor - c_microbe_k) / seconds_per_day,
        (mapped.state[5] * inverse_factor - c_soil_available) / seconds_per_day,
        (mapped.state[6] * inverse_factor - c_soil_chemical) / seconds_per_day,
        (mapped.state[7] * inverse_factor - c_soil_physical) / seconds_per_day,
    )
    respiration =
        (mapped.respiration * inverse_factor + cwd_respiration) /
        seconds_per_day
    processes = mapped.processes .* (inverse_factor / seconds_per_day)
    return StaticArrays.SVector{17}(
        tendencies[1],
        tendencies[2],
        tendencies[3],
        tendencies[4],
        tendencies[5],
        tendencies[6],
        tendencies[7],
        tendencies[8],
        respiration,
        environment.moisture,
        processes[1],
        processes[2],
        processes[3],
        processes[4],
        processes[5],
        processes[6],
        cwd_to_structural / seconds_per_day,
    )
end


"""
    continuous_carbon_fluxes(parameters, state..., drivers...)

Return the eight prognostic tendencies, heterotrophic respiration, moisture
factor, and process rates for the simultaneous carbon-only MIMICS ODE. The
result is an instantaneous SI rate and does not depend on a numerical
timestep.

# Arguments
- `parameters`: Point MIMICS parameters.
- `state...`: Eight carbon stocks ordered as metabolic litter, structural
  litter, CWD, r-selected microbes, K-selected microbes, available soil,
  chemically protected soil, and physically protected soil [kg C m⁻²].
- `drivers...`: Soil temperature [K], liquid and frozen saturation [-], three
  litter inputs [kg C m⁻² s⁻¹], metabolic litter fraction [-], and annual NPP
  [kg C m⁻² yr⁻¹].

# Returns
Return an `SVector{17}` containing the eight state tendencies, heterotrophic
respiration [kg C m⁻² s⁻¹], moisture factor [-], r- and K-selected microbial
turnover, physical and chemical formation, desorption, oxidation, and CWD
transfer [kg C m⁻² s⁻¹], in that order.

# Examples
```julia
using ClimaLand
MIMICS = ClimaLand.Soil.Biogeochemistry.MIMICS
FT = Float64
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
parameters = MIMICS.MIMICSSoilModelParameters{FT, typeof(carbon)}(;
    carbon,
    clay = FT(0.21805),
    freezing_temperature = FT(273.15),
    cwd_q10 = FT(1.72),
    cwd_litter_optimum = FT(0.4),
    cwd_base_rate = inv(FT(365 * 0.824 * 86400)),
    cwd_respiration_fraction = FT(0.48),
)
state = FT.((1, 2, 0.5, 0.03, 0.04, 3, 4, 5))
drivers = FT.((283.15, 0.3, 0.1, 1e-8, 2e-8, 3e-8, 0.5, 0.3))
fluxes = MIMICS.continuous_carbon_fluxes(parameters, state..., drivers...)
carbon_tendencies = fluxes[1:8]
```

See also [`daily_carbon_map`](@ref) and [`MIMICSSoilModel`](@ref).
"""
@inline function continuous_carbon_fluxes(
    parameters,
    c_litter_metabolic,
    c_litter_structural,
    c_litter_cwd,
    c_microbe_r,
    c_microbe_k,
    c_soil_available,
    c_soil_chemical,
    c_soil_physical,
    soil_temperature,
    liquid_saturation,
    frozen_saturation,
    litter_metabolic_input,
    litter_structural_input,
    litter_cwd_input,
    litter_metabolic_fraction,
    annual_npp,
)
    carbon = parameters.carbon
    concentration_factor = oftype(c_litter_cwd, 100) / carbon.depth_cm
    environment = environmental_parameters(
        carbon,
        soil_temperature - parameters.freezing_temperature,
        liquid_saturation,
        frozen_saturation,
        litter_metabolic_fraction,
        annual_npp * oftype(annual_npp, 1000),
        parameters.clay,
    )
    lit_m = c_litter_metabolic * concentration_factor
    lit_s = c_litter_structural * concentration_factor
    mic_r = c_microbe_r * concentration_factor
    mic_k = c_microbe_k * concentration_factor
    som_a = c_soil_available * concentration_factor
    som_c = c_soil_chemical * concentration_factor
    som_p = c_soil_physical * concentration_factor
    vmax = environment.vmax
    km = environment.km
    concentration_per_hour_to_surface_rate =
        inv(concentration_factor * oftype(concentration_factor, 3600))

    litter_r_m =
        mic_r * vmax[1] * lit_m / (km[1] + mic_r) *
        concentration_per_hour_to_surface_rate
    litter_r_s =
        mic_r * vmax[2] * lit_s / (km[2] + mic_r) *
        concentration_per_hour_to_surface_rate
    soil_r =
        mic_r * vmax[3] * som_a / (km[3] + mic_r) *
        concentration_per_hour_to_surface_rate
    litter_k_m =
        mic_k * vmax[4] * lit_m / (km[4] + mic_k) *
        concentration_per_hour_to_surface_rate
    litter_k_s =
        mic_k * vmax[5] * lit_s / (km[5] + mic_k) *
        concentration_per_hour_to_surface_rate
    soil_k =
        mic_k * vmax[6] * som_a / (km[6] + mic_k) *
        concentration_per_hour_to_surface_rate

    r_loss =
        mic_r * environment.r_turnover * concentration_per_hour_to_surface_rate
    k_loss =
        mic_k * environment.k_turnover * concentration_per_hour_to_surface_rate
    r_to_p = r_loss * environment.r_partition[1]
    r_to_c = r_loss * environment.r_partition[2]
    r_to_a = r_loss * environment.r_partition[3]
    k_to_p = k_loss * environment.k_partition[1]
    k_to_c = k_loss * environment.k_partition[2]
    k_to_a = k_loss * environment.k_partition[3]
    desorption =
        som_p * environment.desorption * concentration_per_hour_to_surface_rate
    oxidation =
        (
            mic_k * vmax[5] * som_c /
            (carbon.oxidation_modifier[2] * km[5] + mic_k) +
            mic_r * vmax[2] * som_c /
            (carbon.oxidation_modifier[1] * km[2] + mic_r)
        ) * concentration_per_hour_to_surface_rate

    cwd_loss =
        parameters.cwd_base_rate *
        parameters.cwd_litter_optimum *
        CASA.temperature_factor(
            parameters.cwd_q10,
            soil_temperature,
            parameters.freezing_temperature,
        ) *
        CASA.moisture_factor(liquid_saturation, false) *
        c_litter_cwd
    cwd_respiration = parameters.cwd_respiration_fraction * cwd_loss
    cwd_to_structural = cwd_loss - cwd_respiration
    structural_input = litter_structural_input + cwd_to_structural

    mge = carbon.microbial_growth_efficiency
    physical_formation =
        litter_metabolic_input * carbon.input_protection[1] + r_to_p + k_to_p
    chemical_formation =
        structural_input * carbon.input_protection[2] + r_to_c + k_to_c
    respiration =
        (one(mge[1]) - mge[1]) * (litter_r_m + soil_r) +
        (one(mge[2]) - mge[2]) * litter_r_s +
        (one(mge[3]) - mge[3]) * (litter_k_m + soil_k) +
        (one(mge[4]) - mge[4]) * litter_k_s +
        cwd_respiration
    return StaticArrays.SVector{17}(
        litter_metabolic_input *
        (one(litter_metabolic_input) - carbon.input_protection[1]) -
        litter_r_m - litter_k_m,
        structural_input *
        (one(structural_input) - carbon.input_protection[2]) - litter_r_s -
        litter_k_s,
        litter_cwd_input - cwd_loss,
        mge[1] * (litter_r_m + soil_r) + mge[2] * litter_r_s - r_loss,
        mge[3] * (litter_k_m + soil_k) + mge[4] * litter_k_s - k_loss,
        r_to_a + k_to_a + desorption + oxidation - soil_r - soil_k,
        chemical_formation - oxidation,
        physical_formation - desorption,
        respiration,
        environment.moisture,
        r_loss,
        k_loss,
        physical_formation,
        chemical_formation,
        desorption,
        oxidation,
        cwd_to_structural,
    )
end


@inline carbon_fluxes(::LegacyDaily, args...) = combined_carbon_fluxes(args...)
@inline carbon_fluxes(::ContinuousRate, args...) =
    continuous_carbon_fluxes(args...)


@inline function combined_carbon_nitrogen_fluxes(
    parameters,
    nitrogen_parameters,
    c_litter_metabolic,
    c_litter_structural,
    c_litter_cwd,
    c_microbe_r,
    c_microbe_k,
    c_soil_available,
    c_soil_chemical,
    c_soil_physical,
    n_litter_metabolic,
    n_litter_structural,
    n_microbe_r,
    n_microbe_k,
    n_soil_available,
    n_soil_chemical,
    n_soil_physical,
    n_litter_cwd,
    n_mineral,
    soil_temperature,
    liquid_saturation,
    frozen_saturation,
    litter_metabolic_input,
    litter_structural_input,
    litter_cwd_input,
    nitrogen_litter_metabolic_input,
    nitrogen_litter_structural_input,
    nitrogen_litter_cwd_input,
    deposition,
    fixation,
    plant_uptake,
    litter_metabolic_fraction,
    annual_npp,
)
    carbon_parameters = parameters.carbon
    seconds_per_day = oftype(c_litter_cwd, 86400)
    grams_per_kilogram = oftype(c_litter_cwd, 1000)
    concentration_factor =
        oftype(c_litter_cwd, 0.1) / carbon_parameters.depth_cm
    inverse_factor = inv(concentration_factor) / grams_per_kilogram
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
    cwd_carbon_loss = cwd_fraction * c_litter_cwd
    cwd_respiration = parameters.cwd_respiration_fraction * cwd_carbon_loss
    cwd_to_structural = cwd_carbon_loss - cwd_respiration
    cwd_nitrogen_loss = cwd_fraction * n_litter_cwd

    environment = environmental_parameters(
        carbon_parameters,
        soil_temperature - parameters.freezing_temperature,
        liquid_saturation,
        frozen_saturation,
        litter_metabolic_fraction,
        annual_npp * oftype(annual_npp, 1000),
        parameters.clay,
    )
    carbon = StaticArrays.SVector(
        c_litter_metabolic * grams_per_kilogram * concentration_factor,
        c_litter_structural * grams_per_kilogram * concentration_factor,
        c_microbe_r * grams_per_kilogram * concentration_factor,
        c_microbe_k * grams_per_kilogram * concentration_factor,
        c_soil_available * grams_per_kilogram * concentration_factor,
        c_soil_chemical * grams_per_kilogram * concentration_factor,
        c_soil_physical * grams_per_kilogram * concentration_factor,
    )
    nitrogen = StaticArrays.SVector(
        n_litter_metabolic * grams_per_kilogram * concentration_factor,
        n_litter_structural * grams_per_kilogram * concentration_factor,
        n_microbe_r * grams_per_kilogram * concentration_factor,
        n_microbe_k * grams_per_kilogram * concentration_factor,
        n_soil_available * grams_per_kilogram * concentration_factor,
        n_soil_chemical * grams_per_kilogram * concentration_factor,
        n_soil_physical * grams_per_kilogram * concentration_factor,
    )
    daily_carbon_inputs = (
        litter_metabolic_input *
        seconds_per_day *
        grams_per_kilogram *
        concentration_factor,
        (litter_structural_input * seconds_per_day + cwd_to_structural) *
        grams_per_kilogram *
        concentration_factor,
    )
    daily_nitrogen_inputs = (
        nitrogen_litter_metabolic_input *
        seconds_per_day *
        grams_per_kilogram *
        concentration_factor,
        (
            nitrogen_litter_structural_input * seconds_per_day +
            cwd_nitrogen_loss
        ) *
        grams_per_kilogram *
        concentration_factor,
    )
    leaching =
        nitrogen_parameters.leach_rate *
        seconds_per_day *
        max(zero(n_mineral), n_mineral)
    mineral_after_leaching = n_mineral - leaching
    working_mineral_nitrogen =
        nitrogen_parameters.mineral_nitrogen_available_fraction *
        mineral_after_leaching *
        grams_per_kilogram *
        concentration_factor
    mapped = daily_carbon_nitrogen_map(
        carbon_parameters,
        nitrogen_parameters,
        carbon,
        nitrogen,
        working_mineral_nitrogen,
        daily_carbon_inputs,
        daily_nitrogen_inputs,
        environment,
    )

    next_cwd =
        c_litter_cwd + litter_cwd_input * seconds_per_day - cwd_carbon_loss
    carbon_tendencies = StaticArrays.SVector(
        (mapped.carbon[1] * inverse_factor - c_litter_metabolic) /
        seconds_per_day,
        (mapped.carbon[2] * inverse_factor - c_litter_structural) /
        seconds_per_day,
        (next_cwd - c_litter_cwd) / seconds_per_day,
        (mapped.carbon[3] * inverse_factor - c_microbe_r) / seconds_per_day,
        (mapped.carbon[4] * inverse_factor - c_microbe_k) / seconds_per_day,
        (mapped.carbon[5] * inverse_factor - c_soil_available) /
        seconds_per_day,
        (mapped.carbon[6] * inverse_factor - c_soil_chemical) / seconds_per_day,
        (mapped.carbon[7] * inverse_factor - c_soil_physical) / seconds_per_day,
    )
    respiration =
        (mapped.respiration * inverse_factor + cwd_respiration) /
        seconds_per_day

    litter_mineralization = mapped.litter_mineralization * inverse_factor
    soil_mineralization = mapped.soil_mineralization * inverse_factor
    immobilization = mapped.immobilization * inverse_factor
    net_mineralization =
        litter_mineralization + soil_mineralization + immobilization
    warm = soil_temperature > oftype(soil_temperature, 273.12)
    abundant = mineral_after_leaching > nitrogen_parameters.loss_threshold
    mineral_scale = ifelse(
        warm && abundant,
        one(n_mineral),
        max(
            zero(n_mineral),
            mineral_after_leaching / nitrogen_parameters.loss_threshold,
        ),
    )
    gaseous_loss =
        nitrogen_parameters.loss_fraction *
        max(zero(net_mineralization), net_mineralization) *
        mineral_scale
    working_change =
        (mapped.mineral_nitrogen - working_mineral_nitrogen) * inverse_factor
    next_mineral_nitrogen =
        mineral_after_leaching +
        working_change +
        (deposition + fixation - plant_uptake) * seconds_per_day - gaseous_loss
    next_cwd_nitrogen =
        n_litter_cwd + nitrogen_litter_cwd_input * seconds_per_day -
        cwd_nitrogen_loss
    nitrogen_tendencies = StaticArrays.SVector(
        (mapped.nitrogen[1] * inverse_factor - n_litter_metabolic) /
        seconds_per_day,
        (mapped.nitrogen[2] * inverse_factor - n_litter_structural) /
        seconds_per_day,
        (mapped.nitrogen[3] * inverse_factor - n_microbe_r) / seconds_per_day,
        (mapped.nitrogen[4] * inverse_factor - n_microbe_k) / seconds_per_day,
        (mapped.nitrogen[5] * inverse_factor - n_soil_available) /
        seconds_per_day,
        (mapped.nitrogen[6] * inverse_factor - n_soil_chemical) /
        seconds_per_day,
        (mapped.nitrogen[7] * inverse_factor - n_soil_physical) /
        seconds_per_day,
        (next_cwd_nitrogen - n_litter_cwd) / seconds_per_day,
        (next_mineral_nitrogen - n_mineral) / seconds_per_day,
    )
    return StaticArrays.SVector{29}(
        carbon_tendencies...,
        respiration,
        environment.moisture,
        nitrogen_tendencies...,
        gaseous_loss / seconds_per_day,
        leaching / seconds_per_day,
        litter_mineralization / seconds_per_day,
        soil_mineralization / seconds_per_day,
        immobilization / seconds_per_day,
        mapped.overflow_r * inverse_factor / seconds_per_day,
        mapped.overflow_k * inverse_factor / seconds_per_day,
        mapped.mineral_nitrogen * inverse_factor,
        mapped.physical_protection * inverse_factor / seconds_per_day,
        mapped.microbial_assimilation * inverse_factor / seconds_per_day,
    )
end

@inline carbon_flux_part(fluxes) =
    StaticArrays.SVector{10}(ntuple(index -> fluxes[index], Val(10)))
@inline nitrogen_flux_part(fluxes) =
    StaticArrays.SVector{14}(ntuple(index -> fluxes[index + 10], Val(14)))

function ClimaLand.make_update_aux(
    model::MIMICSSoilModel{FT, CarbonOnly},
) where {FT}
    function update_aux!(p, Y, t)
        drivers = model.drivers
        parameters = model.parameters
        temporal_mode = model.temporal_mode
        soil_temperature = drivers.soil_temperature(t)
        liquid_saturation = drivers.liquid_saturation(t)
        frozen_saturation = drivers.frozen_saturation(t)
        litter_metabolic = drivers.litter_metabolic(t)
        litter_structural = drivers.litter_structural(t)
        litter_cwd = drivers.litter_cwd(t)
        metabolic_fraction = drivers.litter_metabolic_fraction(t)
        annual_npp = drivers.annual_npp(t)

        @. p.mimics_soil.soil_temperature = soil_temperature
        @. p.mimics_soil.liquid_saturation = liquid_saturation
        @. p.mimics_soil.frozen_saturation = frozen_saturation
        @. p.mimics_soil.litter_metabolic_fraction = metabolic_fraction
        @. p.mimics_soil.annual_npp = annual_npp
        update_carbon_fluxes!(
            p,
            Y,
            temporal_mode,
            parameters,
            soil_temperature,
            liquid_saturation,
            frozen_saturation,
            litter_metabolic,
            litter_structural,
            litter_cwd,
            metabolic_fraction,
            annual_npp,
        )
    end
    return update_aux!
end


function ClimaLand.make_update_aux(
    model::MIMICSSoilModel{FT, CarbonNitrogen},
) where {FT}
    function update_aux!(p, Y, t)
        drivers = model.drivers
        nitrogen_drivers = model.nitrogen_drivers
        soil_temperature = drivers.soil_temperature(t)
        liquid_saturation = drivers.liquid_saturation(t)
        frozen_saturation = drivers.frozen_saturation(t)
        litter_metabolic = drivers.litter_metabolic(t)
        litter_structural = drivers.litter_structural(t)
        litter_cwd = drivers.litter_cwd(t)
        metabolic_fraction = drivers.litter_metabolic_fraction(t)
        annual_npp = drivers.annual_npp(t)
        nitrogen_litter_metabolic = nitrogen_drivers.litter_metabolic(t)
        nitrogen_litter_structural = nitrogen_drivers.litter_structural(t)
        nitrogen_litter_cwd = nitrogen_drivers.litter_cwd(t)
        deposition = nitrogen_drivers.deposition(t)
        fixation = nitrogen_drivers.fixation(t)
        plant_uptake = nitrogen_drivers.plant_uptake(t)

        @. p.mimics_soil.soil_temperature = soil_temperature
        @. p.mimics_soil.liquid_saturation = liquid_saturation
        @. p.mimics_soil.frozen_saturation = frozen_saturation
        @. p.mimics_soil.litter_metabolic_fraction = metabolic_fraction
        @. p.mimics_soil.annual_npp = annual_npp
        update_carbon_nitrogen_fluxes!(
            p,
            Y,
            model.parameters,
            model.nitrogen_parameters,
            soil_temperature,
            liquid_saturation,
            frozen_saturation,
            litter_metabolic,
            litter_structural,
            litter_cwd,
            nitrogen_litter_metabolic,
            nitrogen_litter_structural,
            nitrogen_litter_cwd,
            deposition,
            fixation,
            plant_uptake,
            metabolic_fraction,
            annual_npp,
        )
    end
    return update_aux!
end

function update_carbon_fluxes!(
    p,
    Y,
    temporal_mode,
    parameters,
    soil_temperature,
    liquid_saturation,
    frozen_saturation,
    litter_metabolic,
    litter_structural,
    litter_cwd,
    metabolic_fraction,
    annual_npp,
)
    @. p.mimics_soil.litter_metabolic_input = litter_metabolic
    @. p.mimics_soil.litter_structural_input = litter_structural
    @. p.mimics_soil.litter_cwd_input = litter_cwd
    @. p.mimics_soil.carbon_fluxes = carbon_fluxes(
        $(tuple(temporal_mode)),
        parameters,
        Y.mimics_soil.c_litter_metabolic,
        Y.mimics_soil.c_litter_structural,
        Y.mimics_soil.c_litter_cwd,
        Y.mimics_soil.c_microbe_r,
        Y.mimics_soil.c_microbe_k,
        Y.mimics_soil.c_soil_available,
        Y.mimics_soil.c_soil_chemical,
        Y.mimics_soil.c_soil_physical,
        soil_temperature,
        liquid_saturation,
        frozen_saturation,
        litter_metabolic,
        litter_structural,
        litter_cwd,
        metabolic_fraction,
        annual_npp,
    )
    return nothing
end


function update_carbon_nitrogen_fluxes!(
    p,
    Y,
    parameters,
    nitrogen_parameters,
    soil_temperature,
    liquid_saturation,
    frozen_saturation,
    litter_metabolic,
    litter_structural,
    litter_cwd,
    nitrogen_litter_metabolic,
    nitrogen_litter_structural,
    nitrogen_litter_cwd,
    deposition,
    fixation,
    plant_uptake,
    metabolic_fraction,
    annual_npp,
)
    @. p.mimics_soil.litter_metabolic_input = litter_metabolic
    @. p.mimics_soil.litter_structural_input = litter_structural
    @. p.mimics_soil.litter_cwd_input = litter_cwd
    @. p.mimics_soil.nitrogen_litter_metabolic_input = nitrogen_litter_metabolic
    @. p.mimics_soil.nitrogen_litter_structural_input =
        nitrogen_litter_structural
    @. p.mimics_soil.nitrogen_litter_cwd_input = nitrogen_litter_cwd
    @. p.mimics_soil.nitrogen_deposition = deposition
    @. p.mimics_soil.nitrogen_fixation = fixation
    @. p.mimics_soil.nitrogen_plant_uptake = plant_uptake
    @. p.mimics_soil.combined_fluxes = combined_carbon_nitrogen_fluxes(
        parameters,
        nitrogen_parameters,
        Y.mimics_soil.c_litter_metabolic,
        Y.mimics_soil.c_litter_structural,
        Y.mimics_soil.c_litter_cwd,
        Y.mimics_soil.c_microbe_r,
        Y.mimics_soil.c_microbe_k,
        Y.mimics_soil.c_soil_available,
        Y.mimics_soil.c_soil_chemical,
        Y.mimics_soil.c_soil_physical,
        Y.mimics_soil.n_litter_metabolic,
        Y.mimics_soil.n_litter_structural,
        Y.mimics_soil.n_microbe_r,
        Y.mimics_soil.n_microbe_k,
        Y.mimics_soil.n_soil_available,
        Y.mimics_soil.n_soil_chemical,
        Y.mimics_soil.n_soil_physical,
        Y.mimics_soil.n_litter_cwd,
        Y.mimics_soil.n_mineral,
        soil_temperature,
        liquid_saturation,
        frozen_saturation,
        litter_metabolic,
        litter_structural,
        litter_cwd,
        nitrogen_litter_metabolic,
        nitrogen_litter_structural,
        nitrogen_litter_cwd,
        deposition,
        fixation,
        plant_uptake,
        metabolic_fraction,
        annual_npp,
    )
    @. p.mimics_soil.carbon_fluxes =
        carbon_flux_part(p.mimics_soil.combined_fluxes)
    @. p.mimics_soil.nitrogen_fluxes =
        nitrogen_flux_part(p.mimics_soil.combined_fluxes)
    return nothing
end

function ClimaLand.make_compute_exp_tendency(
    ::MIMICSSoilModel{FT, CarbonOnly},
) where {FT}
    function compute_exp_tendency!(dY, Y, p, t)
        fluxes = p.mimics_soil.carbon_fluxes
        @. dY.mimics_soil.c_litter_metabolic = getindex(fluxes, 1)
        @. dY.mimics_soil.c_litter_structural = getindex(fluxes, 2)
        @. dY.mimics_soil.c_litter_cwd = getindex(fluxes, 3)
        @. dY.mimics_soil.c_microbe_r = getindex(fluxes, 4)
        @. dY.mimics_soil.c_microbe_k = getindex(fluxes, 5)
        @. dY.mimics_soil.c_soil_available = getindex(fluxes, 6)
        @. dY.mimics_soil.c_soil_chemical = getindex(fluxes, 7)
        @. dY.mimics_soil.c_soil_physical = getindex(fluxes, 8)
    end
    return compute_exp_tendency!
end


function ClimaLand.make_compute_exp_tendency(
    ::MIMICSSoilModel{FT, CarbonNitrogen},
) where {FT}
    function compute_exp_tendency!(dY, Y, p, t)
        carbon = p.mimics_soil.carbon_fluxes
        nitrogen = p.mimics_soil.nitrogen_fluxes
        @. dY.mimics_soil.c_litter_metabolic = getindex(carbon, 1)
        @. dY.mimics_soil.c_litter_structural = getindex(carbon, 2)
        @. dY.mimics_soil.c_litter_cwd = getindex(carbon, 3)
        @. dY.mimics_soil.c_microbe_r = getindex(carbon, 4)
        @. dY.mimics_soil.c_microbe_k = getindex(carbon, 5)
        @. dY.mimics_soil.c_soil_available = getindex(carbon, 6)
        @. dY.mimics_soil.c_soil_chemical = getindex(carbon, 7)
        @. dY.mimics_soil.c_soil_physical = getindex(carbon, 8)
        @. dY.mimics_soil.n_litter_metabolic = getindex(nitrogen, 1)
        @. dY.mimics_soil.n_litter_structural = getindex(nitrogen, 2)
        @. dY.mimics_soil.n_microbe_r = getindex(nitrogen, 3)
        @. dY.mimics_soil.n_microbe_k = getindex(nitrogen, 4)
        @. dY.mimics_soil.n_soil_available = getindex(nitrogen, 5)
        @. dY.mimics_soil.n_soil_chemical = getindex(nitrogen, 6)
        @. dY.mimics_soil.n_soil_physical = getindex(nitrogen, 7)
        @. dY.mimics_soil.n_litter_cwd = getindex(nitrogen, 8)
        @. dY.mimics_soil.n_mineral = getindex(nitrogen, 9)
    end
    return compute_exp_tendency!
end

end
