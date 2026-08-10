module CLASSIC

import ClimaComms
import ClimaCore
import StaticArrays

const SoilBiogeochemistry = parentmodule(@__MODULE__)
const Land = parentmodule(parentmodule(parentmodule(@__MODULE__)))

export CLASSICAudit,
    CLASSICForcing,
    CLASSICParameters,
    CLASSICPhases,
    CLASSICSoilModel,
    ConstantForcingProvider,
    PrescribedDailyForcingProvider,
    CLASSICState,
    CLASSICTransition,
    N_CATEGORIES,
    N_PARAMETER_PFTS,
    N_PFTS,
    N_SOIL_LAYERS,
    StageBTransfer,
    advance_stage_b,
    advance!,
    classic_domain,
    forcing_at,
    set_prognostic_state!,
    state_from_prognostic

# -----------------------------------------------------------------------------
# Public constants and data model
# -----------------------------------------------------------------------------

"""
    N_PFTS

Number of vegetation plant-functional-type categories in Stage B.
"""
const N_PFTS = 12

"""
    N_CATEGORIES

Number of owned PFT-plus-bare-ground carbon categories in Stage B.
"""
const N_CATEGORIES = 13

"""
    N_SOIL_LAYERS

Number of source-native CLASSIC soil layers.
"""
const N_SOIL_LAYERS = 20

"""
    N_PARAMETER_PFTS

Number of entries in each source-native PFT parameter vector.
"""
const N_PARAMETER_PFTS = 15

function _check_pool_shape(field, label)
    expected = (1, N_CATEGORIES, N_SOIL_LAYERS)
    size(field) == expected || throw(
        ArgumentError("$label has shape $(size(field)); expected $expected"),
    )
    return nothing
end

"""
    CLASSICState{FT}

Store the owned mineral-soil carbon state for one CLASSIC tile.
`FT` is the `Float32` or `Float64` precision of both carbon-pool arrays.

# Fields
- `litrmass`: Litter carbon by tile, PFT-plus-bare category, and layer
  [kg C m⁻²].
- `soilcmas`: Soil organic carbon on the same dimensions [kg C m⁻²].

# Examples
```julia
using ClimaLand.Soil.Biogeochemistry.CLASSIC
shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
state = CLASSICState(zeros(Float64, shape), zeros(Float64, shape))
```
"""
struct CLASSICState{FT <: AbstractFloat}
    litrmass::Array{FT, 3}
    soilcmas::Array{FT, 3}
    function CLASSICState(
        litrmass::Array{FT, 3},
        soilcmas::Array{FT, 3},
    ) where {FT <: AbstractFloat}
        _check_pool_shape(litrmass, "litrmass")
        _check_pool_shape(soilcmas, "soilcmas")
        return new{FT}(litrmass, soilcmas)
    end
end

"""
    StageBTransfer{FT}

Store an externally computed carbon-pool delta for one daily Stage B seam.
`FT` is the `Float32` or `Float64` precision of both transfer arrays.
Positive values add carbon and negative values remove carbon.

# Fields
- `litter`: Litter-carbon delta by tile, category, and layer [kg C m⁻²].
- `soil`: Soil-carbon delta on the same dimensions [kg C m⁻²].

# Examples
```julia
using ClimaLand.Soil.Biogeochemistry.CLASSIC
shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
transfer = StageBTransfer(zeros(Float64, shape), zeros(Float64, shape))
```
"""
struct StageBTransfer{FT <: AbstractFloat}
    litter::Array{FT, 3}
    soil::Array{FT, 3}
    function StageBTransfer(
        litter::Array{FT, 3},
        soil::Array{FT, 3},
    ) where {FT <: AbstractFloat}
        _check_pool_shape(litter, "transfer litter")
        _check_pool_shape(soil, "transfer soil")
        return new{FT}(litter, soil)
    end
end


"""
    CLASSICParameters{FT}
    CLASSICParameters(; kwargs...)

Store precision-generic parameters and source-native switches for Stage B.
`FT` is inferred from the floating-point parameter arrays.

# Fields
- `thpor`: Total soil porosity by tile and layer [m³ m⁻³].
- `psisat`: Saturated matric-potential magnitude [m].
- `bi`: Clapp-Hornberger soil-moisture exponent [-].
- `isand`: Source-native soil-class code [-].
- `zbotw`: Source-native turbation depth coordinate [m].
- `zbot`: Strictly increasing layer-bottom depths [m].
- `delzw`: Permeable layer thickness [m].
- `sort`: Map from owned PFTs to the 15-entry parameter vectors [-].
- `bsratelt`, `bsratesc`: PFT litter and soil base rates [kg C kgC⁻¹ yr⁻¹].
- `humicfac`: PFT litter-to-soil humification fractions [-].
- `bsratelt_g`, `bsratesc_g`: Bare-ground litter and soil base rates
  [kg C kgC⁻¹ yr⁻¹].
- `humicfac_bg`: Bare-ground humification fraction [-].
- `tanhq10`: Four source coefficients for temperature sensitivity [-].
- `deltat`: Length of one source transition [day].
- `tfrez`: Freezing temperature [K].
- `zero`: Source-native numerical threshold [kg C m⁻²].
- `tcrit`: Cold-reduction threshold [°C].
- `frozered`: Below-threshold respiration multiplier [-].
- `r_depthredu`: E-folding depth for respiration reduction [m].
- `cryodiffus`, `biodiffus`: Cryoturbation and bioturbation diffusivities
  [m² yr⁻¹].
- `kterm`: Cryoturbation taper multiplier [-].
- `spinfast`: Source-native accelerated-spinup multiplier [-].
- `turbation_on`: Whether vertical carbon movement is enabled.
- `rate_to_step`: Source conversion from rate to daily pool change
  [μmol CO₂ kg C⁻¹].
- `base_rate_conversion`: Source conversion applied to annual base rates [-].

# Examples
```julia
using ClimaLand.Soil.Biogeochemistry.CLASSIC
FT = Float64
parameters = CLASSICParameters(;
    thpor = fill(FT(0.5), 1, 20), psisat = fill(FT(4), 1, 20),
    bi = fill(one(FT), 1, 20), isand = fill(Int32(0), 1, 20),
    zbotw = reshape(collect(FT(0.1):FT(0.1):FT(2)), 1, :),
    zbot = cumsum(fill(FT(0.1), 20)), delzw = fill(FT(0.1), 1, 20),
    sort = Int32[1, 2, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14],
    bsratelt = ones(FT, 15), bsratesc = ones(FT, 15),
    humicfac = fill(FT(0.5), 15), bsratelt_g = FT(1),
    bsratesc_g = FT(1), humicfac_bg = FT(0.5),
    tanhq10 = FT[2.16, 0.67, 0.075, 28.1], deltat = one(FT),
    tfrez = FT(273.16), zero = FT(1e-20), tcrit = -one(FT),
    frozered = FT(0.1), r_depthredu = FT(8.3),
    cryodiffus = FT(1.26873e-6), biodiffus = FT(3.57059e-7),
    kterm = FT(3), spinfast = Int32(1), turbation_on = false,
)
```
"""
Base.@kwdef struct CLASSICParameters{FT <: AbstractFloat}
    thpor::Matrix{FT}
    psisat::Matrix{FT}
    bi::Matrix{FT}
    isand::Matrix{Int32}
    zbotw::Matrix{FT}
    zbot::Vector{FT}
    delzw::Matrix{FT}
    sort::Vector{Int32}
    bsratelt::Vector{FT}
    bsratesc::Vector{FT}
    humicfac::Vector{FT}
    bsratelt_g::FT
    bsratesc_g::FT
    humicfac_bg::FT
    tanhq10::Vector{FT}
    deltat::FT
    tfrez::FT
    zero::FT
    tcrit::FT
    frozered::FT
    r_depthredu::FT
    cryodiffus::FT
    biodiffus::FT
    kterm::FT
    spinfast::Int32
    turbation_on::Bool
    rate_to_step::FT = eltype(thpor)(963.62)
    base_rate_conversion::FT = eltype(thpor)(2.64)
end

"""
    CLASSICForcing{FT}
    CLASSICForcing(; kwargs...)

Store one day of external Stage B forcing in source application order.
`FT` is the shared precision of the forcing arrays and ordered transfers.

# Fields
- `tbar`: Daily mean soil temperature by tile and layer [K].
- `thliq`, `thice`: Daily mean liquid-water and ice fractions [m³ m⁻³].
- `fcancmx`: PFT cover fractions at respiration time [-].
- `fg`: Bare-ground cover fraction [-].
- `rmrveg`: PFT root respiration used by the audit [μmol CO₂ m⁻² s⁻¹].
- `rmr`: Tile root respiration used by the audit [μmol CO₂ m⁻² s⁻¹].
- `max_annual_active_layer`: Maximum annual active-layer depth [m].
- `competition`, `land_use`, `harvest`: Ordered pre-respiration transfers.
- `turnover`, `mortality`, `disturbance`: Ordered post-respiration transfers.

# Examples
```julia
using ClimaLand.Soil.Biogeochemistry.CLASSIC
shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
zero_transfer = StageBTransfer(zeros(Float64, shape), zeros(Float64, shape))
forcing = CLASSICForcing(;
    tbar = fill(288.16, 1, 20), thliq = fill(0.5, 1, 20),
    thice = zeros(1, 20), fcancmx = zeros(1, 12), fg = [1.0],
    rmrveg = zeros(1, 12), rmr = [0.0], max_annual_active_layer = [2.0],
    competition = zero_transfer, land_use = zero_transfer, harvest = zero_transfer,
    turnover = zero_transfer, mortality = zero_transfer, disturbance = zero_transfer,
)
```
"""
Base.@kwdef struct CLASSICForcing{FT <: AbstractFloat}
    tbar::Matrix{FT}
    thliq::Matrix{FT}
    thice::Matrix{FT}
    fcancmx::Matrix{FT}
    fg::Vector{FT}
    rmrveg::Matrix{FT}
    rmr::Vector{FT}
    max_annual_active_layer::Vector{FT}
    competition::StageBTransfer{FT}
    land_use::StageBTransfer{FT}
    harvest::StageBTransfer{FT}
    turnover::StageBTransfer{FT}
    mortality::StageBTransfer{FT}
    disturbance::StageBTransfer{FT}
end

"""
    CLASSICAudit{FT}

Store flux, conservation, clamp, and turbation diagnostics for one transition.
`FT` is the floating-point precision shared by every diagnostic array.

# Fields
- `ltresveg`, `scresveg`: Layered litter and soil respiration
  [μmol CO₂ m⁻² s⁻¹].
- `hetrsveg`: Category-summed heterotrophic respiration [μmol CO₂ m⁻² s⁻¹].
- `litres`, `socres`, `hetrores`: Tile litter, soil, and total respiration
  [μmol CO₂ m⁻² s⁻¹].
- `soilresp`: Tile soil-plus-root respiration [kg C m⁻² step⁻¹].
- `humtrsvg`, `humiftrs`: Layered and tile humification rates
  [μmol CO₂ m⁻² s⁻¹].
- `litter_clamp_correction`, `soil_clamp_correction`: Carbon removed by
  source-compatible nonnegative clamping [kg C m⁻²].
- `turbation_litter_delta`, `turbation_soil_delta`: Vertical-movement pool
  changes [kg C m⁻²].

# Examples
```julia
using ClimaLand.Soil.Biogeochemistry.CLASSIC
FT = Float64
shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
pool = zeros(FT, shape)
category = zeros(FT, 1, N_CATEGORIES)
tile = zeros(FT, 1)
audit = CLASSICAudit(
    pool, pool, category, tile, tile, tile, tile,
    pool, tile, pool, pool, pool, pool,
)
```
"""
struct CLASSICAudit{FT <: AbstractFloat}
    ltresveg::Array{FT, 3}
    scresveg::Array{FT, 3}
    hetrsveg::Matrix{FT}
    litres::Vector{FT}
    socres::Vector{FT}
    hetrores::Vector{FT}
    soilresp::Vector{FT}
    humtrsvg::Array{FT, 3}
    humiftrs::Vector{FT}
    litter_clamp_correction::Array{FT, 3}
    soil_clamp_correction::Array{FT, 3}
    turbation_litter_delta::Array{FT, 3}
    turbation_soil_delta::Array{FT, 3}
end

"""
    CLASSICPhases{FT}

Store owned-state checkpoints at the Stage B process seams.
`FT` is the floating-point precision of every checkpoint state.

# Fields
- `after_pre_transfers`: State after competition, land use, and harvest.
- `after_pool_update`: State after respiration and humification.
- `before_turbation`: State after turnover, mortality, and disturbance.

# Examples
```julia
using ClimaLand.Soil.Biogeochemistry.CLASSIC
shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
state = CLASSICState(zeros(Float64, shape), zeros(Float64, shape))
phases = CLASSICPhases(state, state, state)
checkpoint = phases.after_pool_update
```
"""
struct CLASSICPhases{FT <: AbstractFloat}
    after_pre_transfers::CLASSICState{FT}
    after_pool_update::CLASSICState{FT}
    before_turbation::CLASSICState{FT}
end

"""
    CLASSICTransition{FT}

Return the state, audit diagnostics, and checkpoints from one Stage B day.
`FT` is the floating-point precision shared by all transition components.

# Fields
- `state`: Owned state after the complete transition.
- `audit`: Flux and conservation diagnostics for the transition.
- `phases`: Intermediate owned-state checkpoints.

# Examples
```julia
using ClimaLand.Soil.Biogeochemistry.CLASSIC
FT = Float64
shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
pool = zeros(FT, shape)
category = zeros(FT, 1, N_CATEGORIES)
tile = zeros(FT, 1)
state = CLASSICState(pool, pool)
audit = CLASSICAudit(
    pool, pool, category, tile, tile, tile, tile,
    pool, tile, pool, pool, pool, pool,
)
phases = CLASSICPhases(state, state, state)
transition = CLASSICTransition(state, audit, phases)
next_state = transition.state
```
"""
struct CLASSICTransition{FT <: AbstractFloat}
    state::CLASSICState{FT}
    audit::CLASSICAudit{FT}
    phases::CLASSICPhases{FT}
end

struct CLASSICMixingCache{FT <: AbstractFloat}
    depth::Vector{FT}
    litter_intermediate::Vector{FT}
    soil_intermediate::Vector{FT}
    litter_diffusivity::Vector{FT}
    soil_diffusivity::Vector{FT}
    lower_diagonal::Vector{FT}
    diagonal::Vector{FT}
    upper_diagonal::Vector{FT}
    right_hand_side::Vector{FT}
    solution::Vector{FT}
    tridiagonal_work::Vector{FT}
end

struct CLASSICCache{FT <: AbstractFloat}
    input_state::CLASSICState{FT}
    transition::CLASSICTransition{FT}
    mixing::CLASSICMixingCache{FT}
end

function _empty_state(::Type{FT}) where {FT <: AbstractFloat}
    shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
    return CLASSICState(zeros(FT, shape), zeros(FT, shape))
end

function _empty_audit(::Type{FT}) where {FT <: AbstractFloat}
    pool_shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
    category_shape = (1, N_CATEGORIES)
    return CLASSICAudit(
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
        zeros(FT, category_shape),
        zeros(FT, 1),
        zeros(FT, 1),
        zeros(FT, 1),
        zeros(FT, 1),
        zeros(FT, pool_shape),
        zeros(FT, 1),
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
    )
end

# -----------------------------------------------------------------------------
# Reusable transition storage
# -----------------------------------------------------------------------------

function _classic_cache(::Type{FT}) where {FT <: AbstractFloat}
    phases = CLASSICPhases(_empty_state(FT), _empty_state(FT), _empty_state(FT))
    transition = CLASSICTransition(_empty_state(FT), _empty_audit(FT), phases)
    work_length = N_SOIL_LAYERS + 2
    work() = zeros(FT, work_length)
    mixing = CLASSICMixingCache(
        work(),
        work(),
        work(),
        work(),
        work(),
        work(),
        work(),
        work(),
        work(),
        work(),
        work(),
    )
    return CLASSICCache(_empty_state(FT), transition, mixing)
end


# -----------------------------------------------------------------------------
# Forcing providers
# -----------------------------------------------------------------------------

"""
    ConstantForcingProvider{F}
    ConstantForcingProvider(forcing)

Return the same typed forcing at every daily transition.
`F` is the concrete `CLASSICForcing` type retained by the provider.

# Fields
- `forcing`: The `CLASSICForcing` returned by [`forcing_at`](@ref).

# Examples
```julia
using ClimaLand.Soil.Biogeochemistry.CLASSIC
shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
transfer = StageBTransfer(zeros(Float64, shape), zeros(Float64, shape))
forcing = CLASSICForcing(;
    tbar = zeros(1, N_SOIL_LAYERS), thliq = zeros(1, N_SOIL_LAYERS),
    thice = zeros(1, N_SOIL_LAYERS), fcancmx = zeros(1, N_PFTS),
    fg = zeros(1), rmrveg = zeros(1, N_PFTS), rmr = zeros(1),
    max_annual_active_layer = zeros(1), competition = transfer,
    land_use = transfer, harvest = transfer, turnover = transfer,
    mortality = transfer, disturbance = transfer,
)
provider = ConstantForcingProvider(forcing)
forcing_at(provider, 86400.0) === forcing
```
"""
struct ConstantForcingProvider{F}
    forcing::F
end

"""
    forcing_at(provider, time)

Return the typed CLASSIC forcing selected for the transition ending at `time`.

# Arguments
- `provider`: A constant or prescribed daily forcing provider.
- `time`: End time of the requested transition [simulation time].

# Returns
The selected `CLASSICForcing`.

# Examples
```julia
using ClimaLand.Soil.Biogeochemistry.CLASSIC
shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
transfer = StageBTransfer(zeros(Float64, shape), zeros(Float64, shape))
forcing = CLASSICForcing(;
    tbar = zeros(1, N_SOIL_LAYERS), thliq = zeros(1, N_SOIL_LAYERS),
    thice = zeros(1, N_SOIL_LAYERS), fcancmx = zeros(1, N_PFTS),
    fg = zeros(1), rmrveg = zeros(1, N_PFTS), rmr = zeros(1),
    max_annual_active_layer = zeros(1), competition = transfer,
    land_use = transfer, harvest = transfer, turnover = transfer,
    mortality = transfer, disturbance = transfer,
)
provider = ConstantForcingProvider(forcing)
forcing_at(provider, 86400.0) === forcing
```
"""
forcing_at(provider::ConstantForcingProvider, _) = provider.forcing

"""
    PrescribedDailyForcingProvider{T, F}
    PrescribedDailyForcingProvider(times, forcings)

Store strictly increasing transition end times and their typed forcing values.
`T` and `F` are the concrete tuple types for times and forcing values.

# Fields
- `times`: Strictly increasing daily transition end times [simulation time].
- `forcings`: `CLASSICForcing` values corresponding one-to-one with `times`.

# Examples
```julia
using ClimaLand.Soil.Biogeochemistry.CLASSIC
shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
transfer = StageBTransfer(zeros(Float64, shape), zeros(Float64, shape))
forcing = CLASSICForcing(;
    tbar = zeros(1, N_SOIL_LAYERS), thliq = zeros(1, N_SOIL_LAYERS),
    thice = zeros(1, N_SOIL_LAYERS), fcancmx = zeros(1, N_PFTS),
    fg = zeros(1), rmrveg = zeros(1, N_PFTS), rmr = zeros(1),
    max_annual_active_layer = zeros(1), competition = transfer,
    land_use = transfer, harvest = transfer, turnover = transfer,
    mortality = transfer, disturbance = transfer,
)
provider = PrescribedDailyForcingProvider((86400.0,), (forcing,))
forcing_at(provider, 86400.0) === forcing
```
"""
struct PrescribedDailyForcingProvider{T <: Tuple, F <: Tuple}
    times::T
    forcings::F
    function PrescribedDailyForcingProvider(
        times::T,
        forcings::F,
    ) where {T <: Tuple, F <: Tuple}
        length(times) == length(forcings) || throw(
            ArgumentError("forcing times and values must have equal length"),
        )
        isempty(times) &&
            throw(ArgumentError("forcing provider cannot be empty"))
        all(index -> times[index] > times[index - 1], 2:length(times)) ||
            throw(ArgumentError("forcing times must be strictly increasing"))
        all(forcing -> forcing isa CLASSICForcing, forcings) ||
            throw(ArgumentError("forcing values must be CLASSICForcing"))
        return new{T, F}(times, forcings)
    end
end

function forcing_at(provider::PrescribedDailyForcingProvider, time)
    index = findlast(value -> value <= time, provider.times)
    isnothing(index) &&
        throw(ArgumentError("no CLASSIC forcing at requested time"))
    return provider.forcings[index]
end

# -----------------------------------------------------------------------------
# ClimaLand model integration
# -----------------------------------------------------------------------------

"""
    classic_domain(parameters; device = ClimaComms.device())

Construct the exact nonuniform CLASSIC total-layer domain from `zbot`.
`zbotw` remains the turbation coordinate and `delzw` the permeable thickness.

# Arguments
- `parameters`: Stage B parameters containing the 20 layer-bottom depths.

# Keyword Arguments
- `device = ClimaComms.device()`: ClimaComms device for the domain spaces.

# Returns
A `ClimaLand.Domains.Column` whose precision matches `parameters`.

# Examples
```julia
using ClimaLand.Soil.Biogeochemistry.CLASSIC

function demo_inputs(::Type{FT} = Float64) where {FT}
    layer_shape = (1, N_SOIL_LAYERS)
    pool_shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
    depths = collect(range(FT(0.1); step = FT(0.1), length = N_SOIL_LAYERS))
    parameters = CLASSICParameters(;
        thpor = fill(FT(0.5), layer_shape),
        psisat = fill(FT(4), layer_shape),
        bi = ones(FT, layer_shape),
        isand = zeros(Int32, layer_shape),
        zbotw = reshape(copy(depths), layer_shape),
        zbot = depths,
        delzw = fill(FT(0.1), layer_shape),
        sort = Int32[1, 2, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14],
        bsratelt = ones(FT, N_PARAMETER_PFTS),
        bsratesc = ones(FT, N_PARAMETER_PFTS),
        humicfac = fill(FT(0.5), N_PARAMETER_PFTS),
        bsratelt_g = one(FT),
        bsratesc_g = one(FT),
        humicfac_bg = FT(0.5),
        tanhq10 = FT[2.16, 0.67, 0.075, 28.1],
        deltat = one(FT),
        tfrez = FT(273.16),
        zero = FT(1e-20),
        tcrit = -one(FT),
        frozered = FT(0.1),
        r_depthredu = FT(8.3),
        cryodiffus = zero(FT),
        biodiffus = zero(FT),
        kterm = FT(3),
        spinfast = Int32(1),
        turbation_on = false,
    )
    transfer = StageBTransfer(
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
    )
    forcing = CLASSICForcing(;
        tbar = fill(FT(288.16), layer_shape),
        thliq = fill(FT(0.25), layer_shape),
        thice = zeros(FT, layer_shape),
        fcancmx = zeros(FT, 1, N_PFTS),
        fg = ones(FT, 1),
        rmrveg = zeros(FT, 1, N_PFTS),
        rmr = zeros(FT, 1),
        max_annual_active_layer = fill(FT(2), 1),
        competition = transfer,
        land_use = transfer,
        harvest = transfer,
        turnover = transfer,
        mortality = transfer,
        disturbance = transfer,
    )
    state = CLASSICState(
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
    )
    return (; state, parameters, forcing)
end
inputs = demo_inputs()
domain = classic_domain(inputs.parameters)
length(parent(domain.fields.z)) == N_SOIL_LAYERS
```

See also [`CLASSICParameters`](@ref) and [`CLASSICSoilModel`](@ref).

"""
function classic_domain(
    parameters::CLASSICParameters{FT};
    device = ClimaComms.device(),
) where {FT}
    bottoms = vec(parameters.zbot)
    all(index -> bottoms[index] > bottoms[index - 1], 2:length(bottoms)) ||
        throw(ArgumentError("zbot must be strictly increasing"))
    boundary_names = (:bottom, :top)
    zlim = (-bottoms[end], zero(FT))
    interval = ClimaCore.Domains.IntervalDomain(
        ClimaCore.Geometry.ZPoint(zlim[1]),
        ClimaCore.Geometry.ZPoint(zlim[2]);
        boundary_names,
    )
    faces = ClimaCore.Geometry.ZPoint.(vcat(-reverse(bottoms), zero(FT)))
    mesh = ClimaCore.Meshes.IntervalMesh(interval, faces)
    subsurface = ClimaCore.Spaces.CenterFiniteDifferenceSpace(device, mesh)
    surface = Land.Domains.obtain_surface_space(subsurface)
    space = (;
        surface,
        subsurface,
        subsurface_face = ClimaCore.Spaces.face_space(subsurface),
    )
    fields = Land.Domains.get_additional_coordinate_field_data(subsurface)
    return Land.Domains.Column{FT, typeof(space), typeof(fields)}(
        zlim,
        (N_SOIL_LAYERS,),
        nothing,
        boundary_names,
        space,
        fields,
    )
end

"""
    CLASSICSoilModel{FT, P, D, DR, C}
    CLASSICSoilModel(parameters; drivers, domain, callback_period)

Construct a standalone daily CLASSIC soil-carbon model.
`FT` is the model precision; `P`, `D`, `DR`, and `C` are the concrete
parameter, domain, driver, and cache types.

# Arguments
- `parameters`: Precision-generic Stage B parameters.

# Keyword Arguments
- `drivers`: Constant or prescribed daily forcing provider.
- `domain = classic_domain(parameters)`: Source-native 20-layer domain.
- `callback_period = 86400`: Time between discrete daily transitions [s].

# Fields
- `parameters`: Validated Stage B parameters.
- `domain`: ClimaLand column domain.
- `drivers`: Typed forcing provider.
- `callback_period`: Discrete transition interval [simulation time].
- `cache`: Reusable transition and turbation workspace.

# Examples
```julia
using ClimaLand.Soil.Biogeochemistry.CLASSIC

function demo_inputs(::Type{FT} = Float64) where {FT}
    layer_shape = (1, N_SOIL_LAYERS)
    pool_shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
    depths = collect(range(FT(0.1); step = FT(0.1), length = N_SOIL_LAYERS))
    parameters = CLASSICParameters(;
        thpor = fill(FT(0.5), layer_shape),
        psisat = fill(FT(4), layer_shape),
        bi = ones(FT, layer_shape),
        isand = zeros(Int32, layer_shape),
        zbotw = reshape(copy(depths), layer_shape),
        zbot = depths,
        delzw = fill(FT(0.1), layer_shape),
        sort = Int32[1, 2, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14],
        bsratelt = ones(FT, N_PARAMETER_PFTS),
        bsratesc = ones(FT, N_PARAMETER_PFTS),
        humicfac = fill(FT(0.5), N_PARAMETER_PFTS),
        bsratelt_g = one(FT),
        bsratesc_g = one(FT),
        humicfac_bg = FT(0.5),
        tanhq10 = FT[2.16, 0.67, 0.075, 28.1],
        deltat = one(FT),
        tfrez = FT(273.16),
        zero = FT(1e-20),
        tcrit = -one(FT),
        frozered = FT(0.1),
        r_depthredu = FT(8.3),
        cryodiffus = zero(FT),
        biodiffus = zero(FT),
        kterm = FT(3),
        spinfast = Int32(1),
        turbation_on = false,
    )
    transfer = StageBTransfer(
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
    )
    forcing = CLASSICForcing(;
        tbar = fill(FT(288.16), layer_shape),
        thliq = fill(FT(0.25), layer_shape),
        thice = zeros(FT, layer_shape),
        fcancmx = zeros(FT, 1, N_PFTS),
        fg = ones(FT, 1),
        rmrveg = zeros(FT, 1, N_PFTS),
        rmr = zeros(FT, 1),
        max_annual_active_layer = fill(FT(2), 1),
        competition = transfer,
        land_use = transfer,
        harvest = transfer,
        turnover = transfer,
        mortality = transfer,
        disturbance = transfer,
    )
    state = CLASSICState(
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
    )
    return (; state, parameters, forcing)
end
inputs = demo_inputs()
provider = ConstantForcingProvider(inputs.forcing)
model = CLASSICSoilModel(inputs.parameters; drivers = provider)
model.callback_period == 86400.0
```


See also [`advance!`](@ref) and [`classic_domain`](@ref).
"""
struct CLASSICSoilModel{FT <: AbstractFloat, P, D, DR, C} <:
       SoilBiogeochemistry.AbstractSoilBiogeochemistryModel{FT}
    parameters::P
    domain::D
    drivers::DR
    callback_period::FT
    cache::C
end

function CLASSICSoilModel(
    parameters::CLASSICParameters{FT};
    drivers,
    domain = classic_domain(parameters),
    callback_period = FT(24 * 60 * 60),
) where {FT}
    _validate_parameters(parameters)
    callback_period > 0 ||
        throw(ArgumentError("callback period must be positive"))
    cache = _classic_cache(FT)
    return CLASSICSoilModel{
        FT,
        typeof(parameters),
        typeof(domain),
        typeof(drivers),
        typeof(cache),
    }(
        parameters,
        domain,
        drivers,
        FT(callback_period),
        cache,
    )
end

Land.name(::CLASSICSoilModel) = :classic_soil
Land.prognostic_vars(::CLASSICSoilModel) = (:litrmass, :soilcmas)
Land.prognostic_types(::CLASSICSoilModel{FT}) where {FT} = (
    StaticArrays.SVector{N_CATEGORIES, FT},
    StaticArrays.SVector{N_CATEGORIES, FT},
)
Land.prognostic_domain_names(::CLASSICSoilModel) = (:subsurface, :subsurface)
Land.auxiliary_vars(::CLASSICSoilModel) = ()
Land.auxiliary_types(::CLASSICSoilModel) = ()
Land.auxiliary_domain_names(::CLASSICSoilModel) = ()

"""
    state_from_prognostic(Y)

Copy bottom-to-top ClimaCore prognostic fields into source-order CLASSIC state.

# Arguments
- `Y`: ClimaLand prognostic state containing `classic_soil`.

# Returns
A newly allocated `CLASSICState` in top-to-bottom source order [kg C m⁻²].

# Examples
```julia
using ClimaLand.Soil.Biogeochemistry.CLASSIC

function demo_inputs(::Type{FT} = Float64) where {FT}
    layer_shape = (1, N_SOIL_LAYERS)
    pool_shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
    depths = collect(range(FT(0.1); step = FT(0.1), length = N_SOIL_LAYERS))
    parameters = CLASSICParameters(;
        thpor = fill(FT(0.5), layer_shape),
        psisat = fill(FT(4), layer_shape),
        bi = ones(FT, layer_shape),
        isand = zeros(Int32, layer_shape),
        zbotw = reshape(copy(depths), layer_shape),
        zbot = depths,
        delzw = fill(FT(0.1), layer_shape),
        sort = Int32[1, 2, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14],
        bsratelt = ones(FT, N_PARAMETER_PFTS),
        bsratesc = ones(FT, N_PARAMETER_PFTS),
        humicfac = fill(FT(0.5), N_PARAMETER_PFTS),
        bsratelt_g = one(FT),
        bsratesc_g = one(FT),
        humicfac_bg = FT(0.5),
        tanhq10 = FT[2.16, 0.67, 0.075, 28.1],
        deltat = one(FT),
        tfrez = FT(273.16),
        zero = FT(1e-20),
        tcrit = -one(FT),
        frozered = FT(0.1),
        r_depthredu = FT(8.3),
        cryodiffus = zero(FT),
        biodiffus = zero(FT),
        kterm = FT(3),
        spinfast = Int32(1),
        turbation_on = false,
    )
    transfer = StageBTransfer(
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
    )
    forcing = CLASSICForcing(;
        tbar = fill(FT(288.16), layer_shape),
        thliq = fill(FT(0.25), layer_shape),
        thice = zeros(FT, layer_shape),
        fcancmx = zeros(FT, 1, N_PFTS),
        fg = ones(FT, 1),
        rmrveg = zeros(FT, 1, N_PFTS),
        rmr = zeros(FT, 1),
        max_annual_active_layer = fill(FT(2), 1),
        competition = transfer,
        land_use = transfer,
        harvest = transfer,
        turnover = transfer,
        mortality = transfer,
        disturbance = transfer,
    )
    state = CLASSICState(
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
    )
    return (; state, parameters, forcing)
end
import ClimaLand
inputs = demo_inputs()
model = CLASSICSoilModel(
    inputs.parameters;
    drivers = ConstantForcingProvider(inputs.forcing),
)
Y, _, _ = ClimaLand.initialize(model)
state = state_from_prognostic(Y)
size(state.litrmass) == (1, N_CATEGORIES, N_SOIL_LAYERS)
```

See also [`set_prognostic_state!`](@ref) and [`CLASSICSoilModel`](@ref).

"""
function state_from_prognostic(Y)
    component = getproperty(Y, :classic_soil)
    FT = eltype(eltype(component.litrmass))
    state = _empty_state(FT)
    state_from_prognostic!(state, Y)
    return state
end

function state_from_prognostic!(state::CLASSICState, Y)
    component = getproperty(Y, :classic_soil)
    public_litter = parent(component.litrmass)
    public_soil = parent(component.soilcmas)
    for layer in 1:N_SOIL_LAYERS, category in 1:N_CATEGORIES
        public_layer = N_SOIL_LAYERS + 1 - layer
        public_index = category + (public_layer - 1) * N_CATEGORIES
        state.litrmass[1, category, layer] = public_litter[public_index]
        state.soilcmas[1, category, layer] = public_soil[public_index]
    end
    return nothing
end

"""
    set_prognostic_state!(Y, state)

Write source-order CLASSIC state into bottom-to-top ClimaCore fields.

# Arguments
- `Y`: ClimaLand prognostic state mutated in place.
- `state`: Top-to-bottom `CLASSICState` [kg C m⁻²].

# Returns
`nothing`.

# Examples
```julia
using ClimaLand.Soil.Biogeochemistry.CLASSIC

function demo_inputs(::Type{FT} = Float64) where {FT}
    layer_shape = (1, N_SOIL_LAYERS)
    pool_shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
    depths = collect(range(FT(0.1); step = FT(0.1), length = N_SOIL_LAYERS))
    parameters = CLASSICParameters(;
        thpor = fill(FT(0.5), layer_shape),
        psisat = fill(FT(4), layer_shape),
        bi = ones(FT, layer_shape),
        isand = zeros(Int32, layer_shape),
        zbotw = reshape(copy(depths), layer_shape),
        zbot = depths,
        delzw = fill(FT(0.1), layer_shape),
        sort = Int32[1, 2, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14],
        bsratelt = ones(FT, N_PARAMETER_PFTS),
        bsratesc = ones(FT, N_PARAMETER_PFTS),
        humicfac = fill(FT(0.5), N_PARAMETER_PFTS),
        bsratelt_g = one(FT),
        bsratesc_g = one(FT),
        humicfac_bg = FT(0.5),
        tanhq10 = FT[2.16, 0.67, 0.075, 28.1],
        deltat = one(FT),
        tfrez = FT(273.16),
        zero = FT(1e-20),
        tcrit = -one(FT),
        frozered = FT(0.1),
        r_depthredu = FT(8.3),
        cryodiffus = zero(FT),
        biodiffus = zero(FT),
        kterm = FT(3),
        spinfast = Int32(1),
        turbation_on = false,
    )
    transfer = StageBTransfer(
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
    )
    forcing = CLASSICForcing(;
        tbar = fill(FT(288.16), layer_shape),
        thliq = fill(FT(0.25), layer_shape),
        thice = zeros(FT, layer_shape),
        fcancmx = zeros(FT, 1, N_PFTS),
        fg = ones(FT, 1),
        rmrveg = zeros(FT, 1, N_PFTS),
        rmr = zeros(FT, 1),
        max_annual_active_layer = fill(FT(2), 1),
        competition = transfer,
        land_use = transfer,
        harvest = transfer,
        turnover = transfer,
        mortality = transfer,
        disturbance = transfer,
    )
    state = CLASSICState(
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
    )
    return (; state, parameters, forcing)
end
import ClimaLand
inputs = demo_inputs()
model = CLASSICSoilModel(
    inputs.parameters;
    drivers = ConstantForcingProvider(inputs.forcing),
)
Y, _, _ = ClimaLand.initialize(model)
set_prognostic_state!(Y, inputs.state)
state_from_prognostic(Y).litrmass == inputs.state.litrmass
```

See also [`state_from_prognostic`](@ref).

"""
function set_prognostic_state!(Y, state::CLASSICState)
    component = getproperty(Y, :classic_soil)
    public_litter = parent(component.litrmass)
    public_soil = parent(component.soilcmas)
    for layer in 1:N_SOIL_LAYERS, category in 1:N_CATEGORIES
        public_layer = N_SOIL_LAYERS + 1 - layer
        public_index = category + (public_layer - 1) * N_CATEGORIES
        public_litter[public_index] = state.litrmass[1, category, layer]
        public_soil[public_index] = state.soilcmas[1, category, layer]
    end
    return nothing
end

# -----------------------------------------------------------------------------
# Contract validation
# -----------------------------------------------------------------------------

function _check_layer_matrix(value, label)
    size(value) == (1, N_SOIL_LAYERS) || throw(
        ArgumentError(
            string(label, " must have shape (1, ", N_SOIL_LAYERS, ")"),
        ),
    )
    return nothing
end

function _check_parameter_vector(value, label)
    length(value) == N_PARAMETER_PFTS || throw(
        ArgumentError(string(label, " must have length ", N_PARAMETER_PFTS)),
    )
    return nothing
end

function _validate_parameters(parameters)
    _check_layer_matrix(parameters.thpor, :thpor)
    _check_layer_matrix(parameters.psisat, :psisat)
    _check_layer_matrix(parameters.delzw, :delzw)
    _check_layer_matrix(parameters.bi, :bi)
    _check_layer_matrix(parameters.isand, :isand)
    _check_layer_matrix(parameters.zbotw, :zbotw)
    length(parameters.zbot) == N_SOIL_LAYERS ||
        throw(ArgumentError("zbot must have length 20"))
    for index in 2:N_SOIL_LAYERS
        parameters.zbot[index] > parameters.zbot[index - 1] ||
            throw(ArgumentError("zbot must be strictly increasing"))
    end
    length(parameters.sort) == N_PFTS ||
        throw(ArgumentError("sort must contain 12 indices"))
    for index in parameters.sort
        1 <= index <= N_PARAMETER_PFTS ||
            throw(ArgumentError("sort indices must be in 1:15"))
    end
    _check_parameter_vector(parameters.bsratelt, :bsratelt)
    _check_parameter_vector(parameters.bsratesc, :bsratesc)
    _check_parameter_vector(parameters.humicfac, :humicfac)
    length(parameters.tanhq10) == 4 ||
        throw(ArgumentError("tanhq10 must have length 4"))
    return nothing
end

function _validate_forcing(forcing)
    for (label, value) in (
        (:tbar, forcing.tbar),
        (:thliq, forcing.thliq),
        (:thice, forcing.thice),
    )
        size(value) == (1, N_SOIL_LAYERS) ||
            throw(ArgumentError("$label must have shape (1, $N_SOIL_LAYERS)"))
    end
    size(forcing.fcancmx) == (1, N_PFTS) ||
        throw(ArgumentError("fcancmx must have shape (1, $N_PFTS)"))
    size(forcing.rmrveg) == (1, N_PFTS) ||
        throw(ArgumentError("rmrveg must have shape (1, $N_PFTS)"))
    for (label, value) in (
        (:fg, forcing.fg),
        (:rmr, forcing.rmr),
        (:max_annual_active_layer, forcing.max_annual_active_layer),
    )
        length(value) == 1 || throw(ArgumentError("$label must have length 1"))
    end
    return nothing
end

_copy_state(state) = CLASSICState(copy(state.litrmass), copy(state.soilcmas))

function _copy_state!(destination, source)
    copyto!(destination.litrmass, source.litrmass)
    copyto!(destination.soilcmas, source.soilcmas)
    return nothing
end

function _apply_transfer!(state, transfer)
    state.litrmass .+= transfer.litter
    state.soilcmas .+= transfer.soil
    return nothing
end

function _moisture_scalars(parameters, forcing, layer)
    FT = eltype(parameters.zbot)
    isand = parameters.isand[1, layer]
    if isand == -3 || isand == -4
        return FT(0.2), FT(0.2)
    end
    thpor = parameters.thpor[1, layer]
    thice = forcing.thice[1, layer]
    psi = if thice < thpor
        parameters.psisat[1, layer] *
        (forcing.thliq[1, layer] / (thpor - thice))^(-parameters.bi[1, layer])
    else
        FT(10000)
    end
    psisat = parameters.psisat[1, layer]
    litter, soil = if psi >= FT(10000)
        (FT(0.2), FT(0.2))
    elseif psi > FT(6)
        scalar =
            one(FT) -
            FT(0.8) * (
                (log10(psi) - log10(FT(6))) / (log10(FT(10000)) - log10(FT(6)))
            )
        (scalar, scalar)
    elseif psi >= FT(4)
        (one(FT), one(FT))
    elseif psi > psisat
        scalar =
            one(FT) -
            FT(0.5) *
            ((log10(FT(4)) - log10(psi)) / (log10(FT(4)) - log10(psisat)))
        (layer == 1 ? one(FT) : scalar, scalar)
    else
        (layer == 1 ? one(FT) : FT(0.5), FT(0.5))
    end
    return clamp(litter, FT(0.2), one(FT)), clamp(soil, FT(0.2), one(FT))
end

# -----------------------------------------------------------------------------
# Respiration and pool recurrence
# -----------------------------------------------------------------------------

"""
    _respiration!(ltresveg, scresveg, state, parameters, forcing)

Compute positive litter and soil carbon-emission rates in source order.

The function reads carbon pools from `state`, environmental drivers from
`forcing`, and rate coefficients from `parameters`. It overwrites `ltresveg`
and `scresveg`; positive values denote carbon leaving the pools
[μmol CO₂ m⁻² s⁻¹].

# Arguments
- `ltresveg`: Litter-respiration output mutated in place [μmol CO₂ m⁻² s⁻¹].
- `scresveg`: Soil-respiration output mutated in place [μmol CO₂ m⁻² s⁻¹].
- `state`: Carbon pools at the respiration seam [kg C m⁻²].
- `parameters`: CLASSIC Stage B parameters.
- `forcing`: Environmental and cover forcing for the current day.

# Returns
`nothing`.

Called from [`advance_stage_b!`](@ref).
"""
function _respiration!(ltresveg, scresveg, state, parameters, forcing)
    FT = eltype(state.litrmass)
    fill!(ltresveg, zero(FT))
    fill!(scresveg, zero(FT))
    for layer in 1:N_SOIL_LAYERS
        litter_moisture, soil_moisture =
            _moisture_scalars(parameters, forcing, layer)
        temperature_c = forcing.tbar[1, layer] - parameters.tfrez
        q10 =
            parameters.tanhq10[1] +
            parameters.tanhq10[2] * tanh(
                parameters.tanhq10[3] * (parameters.tanhq10[4] - temperature_c),
            )
        temperature_factor = q10^(FT(0.1) * (temperature_c - FT(15)))
        temperature_c <= parameters.tcrit &&
            (temperature_factor *= parameters.frozered)
        depth_factor =
            parameters.turbation_on ?
            exp(-parameters.zbotw[1, layer] / parameters.r_depthredu) : one(FT)
        for pft in 1:N_PFTS
            forcing.fcancmx[1, pft] > zero(FT) || continue
            parameter_index = parameters.sort[pft]
            ltresveg[1, pft, layer] =
                litter_moisture *
                state.litrmass[1, pft, layer] *
                parameters.bsratelt[parameter_index] *
                parameters.base_rate_conversion *
                temperature_factor *
                depth_factor
            scresveg[1, pft, layer] =
                soil_moisture *
                state.soilcmas[1, pft, layer] *
                parameters.bsratesc[parameter_index] *
                parameters.base_rate_conversion *
                temperature_factor *
                depth_factor
        end
        if forcing.fg[1] > parameters.zero
            ltresveg[1, N_CATEGORIES, layer] =
                litter_moisture *
                state.litrmass[1, N_CATEGORIES, layer] *
                parameters.bsratelt_g *
                parameters.base_rate_conversion *
                temperature_factor *
                depth_factor
            scresveg[1, N_CATEGORIES, layer] =
                soil_moisture *
                state.soilcmas[1, N_CATEGORIES, layer] *
                parameters.bsratesc_g *
                parameters.base_rate_conversion *
                temperature_factor *
                depth_factor
        end
    end
    return nothing
end

function _respiration(state, parameters, forcing)
    FT = eltype(state.litrmass)
    ltresveg = zeros(FT, size(state.litrmass))
    scresveg = zeros(FT, size(state.soilcmas))
    _respiration!(ltresveg, scresveg, state, parameters, forcing)
    return ltresveg, scresveg
end

"""
    _update_pools_cached!(audit, state, parameters, forcing, ltresveg, scresveg)

Apply respiration, humification, spin-up, and nonnegative clamping in place.

The function reads positive emission rates from `ltresveg` and `scresveg`,
mutates the carbon pools in `state`, and overwrites the corresponding flux,
budget, and clamp arrays in `audit`. Clamp corrections are positive carbon
amounts removed from negative source-compatible raw pools [kg C m⁻²].

# Arguments
- `audit`: Cache-owned diagnostics overwritten in place.
- `state`: Carbon pools mutated to the post-respiration state [kg C m⁻²].
- `parameters`: CLASSIC Stage B parameters.
- `forcing`: Cover and root-respiration forcing for the current day.
- `ltresveg`: Positive litter-respiration rates [μmol CO₂ m⁻² s⁻¹].
- `scresveg`: Positive soil-respiration rates [μmol CO₂ m⁻² s⁻¹].

# Returns
`nothing`.

Called from [`advance_stage_b!`](@ref).
"""
function _update_pools_cached!(
    audit,
    state,
    parameters,
    forcing,
    ltresveg,
    scresveg,
)
    FT = eltype(state.litrmass)
    hetrsveg = audit.hetrsveg
    litres = audit.litres
    socres = audit.socres
    hetrores = audit.hetrores
    soilresp = audit.soilresp
    humiftrs = audit.humiftrs
    humtrsvg = audit.humtrsvg
    litter_clamp = audit.litter_clamp_correction
    soil_clamp = audit.soil_clamp_correction
    fill!(hetrsveg, zero(FT))
    fill!(litres, zero(FT))
    fill!(socres, zero(FT))
    fill!(hetrores, zero(FT))
    fill!(soilresp, zero(FT))
    fill!(humiftrs, zero(FT))
    fill!(humtrsvg, zero(FT))
    fill!(litter_clamp, zero(FT))
    fill!(soil_clamp, zero(FT))
    for category in 1:N_CATEGORIES
        covered =
            category <= N_PFTS ?
            forcing.fcancmx[1, category] > parameters.zero :
            forcing.fg[1] > parameters.zero
        if covered
            for layer in 1:N_SOIL_LAYERS
                hetrsveg[1, category] += ltresveg[1, category, layer]
                hetrsveg[1, category] += scresveg[1, category, layer]
            end
        end
    end
    for category in 1:N_CATEGORIES
        cover =
            category <= N_PFTS ? forcing.fcancmx[1, category] : forcing.fg[1]
        root_respiration =
            category <= N_PFTS && cover > parameters.zero ?
            forcing.rmrveg[1, category] : zero(FT)
        for layer in 1:N_SOIL_LAYERS
            litres[1] += cover * ltresveg[1, category, layer]
            socres[1] += cover * scresveg[1, category, layer]
        end
        soilresp[1] += cover * (hetrsveg[1, category] + root_respiration)
        humic_factor =
            category <= N_PFTS ?
            parameters.humicfac[parameters.sort[category]] :
            parameters.humicfac_bg
        for layer in 1:N_SOIL_LAYERS
            litter_step =
                ltresveg[1, category, layer] * parameters.deltat /
                parameters.rate_to_step
            soil_step =
                scresveg[1, category, layer] * parameters.deltat /
                parameters.rate_to_step
            humification = humic_factor * litter_step
            raw_litter =
                state.litrmass[1, category, layer] -
                litter_step * (one(FT) + humic_factor)
            raw_soil =
                state.soilcmas[1, category, layer] +
                FT(parameters.spinfast) * (humification - soil_step)
            state.litrmass[1, category, layer] =
                raw_litter < parameters.zero ? zero(FT) : raw_litter
            state.soilcmas[1, category, layer] =
                raw_soil < parameters.zero ? zero(FT) : raw_soil
            litter_clamp[1, category, layer] = max(zero(FT), -raw_litter)
            soil_clamp[1, category, layer] = max(zero(FT), -raw_soil)
            humtrsvg[1, category, layer] =
                humification * parameters.rate_to_step / parameters.deltat
            humiftrs[1] += cover * humtrsvg[1, category, layer]
        end
    end
    hetrores[1] = litres[1] + socres[1]
    soilresp .*= parameters.deltat / parameters.rate_to_step
    return nothing
end

function _update_pools!(state, parameters, forcing, ltresveg, scresveg)
    FT = eltype(state.litrmass)
    audit = _empty_audit(FT)
    _update_pools_cached!(audit, state, parameters, forcing, ltresveg, scresveg)
    return (
        audit.hetrsveg,
        audit.litres,
        audit.socres,
        audit.hetrores,
        audit.soilresp,
        audit.humtrsvg,
        audit.humiftrs,
        audit.litter_clamp_correction,
        audit.soil_clamp_correction,
    )
end

function _tridiag_cached!(a, b, c, r, u, work, n)
    bet = b[1]
    u[1] = r[1] / bet
    for k in 2:n
        work[k] = c[k - 1] / bet
        bet = b[k] - a[k] * work[k]
        u[k] = (r[k] - a[k] * u[k - 1]) / bet
    end
    for k in (n - 1):-1:1
        u[k] -= work[k + 1] * u[k + 1]
    end
    return nothing
end

# -----------------------------------------------------------------------------
# Vertical mixing and turbation
# -----------------------------------------------------------------------------

"""
    _solve_mixing!(values, coefficients, depth, parameters, mixing, n)

Advance one vertically diffused pool column with cache-owned tridiagonal work.

The function mutates the first `n` entries of `values` and overwrites the
tridiagonal arrays in `mixing`. `coefficients` are nonnegative diffusivities
[m² yr⁻¹], and `depth` is the source turbation coordinate [m].

# Returns
`nothing`.

Called from [`_mix_column_cached!`](@ref).
"""
function _solve_mixing!(values, coefficients, depth, parameters, mixing, n)
    FT = eltype(values)
    a = mixing.lower_diagonal
    b = mixing.diagonal
    c = mixing.upper_diagonal
    r = mixing.right_hand_side
    solution = mixing.solution
    for layer in 2:(n - 1)
        dz = depth[layer] - depth[layer - 1]
        term = coefficients[layer] * parameters.deltat / dz^2
        a[layer] = -term
        b[layer] = FT(2) * (one(FT) + term)
        c[layer] = -term
        r[layer] =
            term * values[layer - 1] +
            FT(2) * (one(FT) - term) * values[layer] +
            term * values[layer + 1]
    end
    _tridiag_cached!(a, b, c, r, solution, mixing.tridiagonal_work, n)
    for layer in 1:n
        values[layer] = solution[layer]
    end
    return nothing
end

"""
    _mix_column_cached!(litter, soil, parameters, active_layer, mixing)

Mix one litter and soil column while conserving each column total.

The function selects cryoturbation or bioturbation from `active_layer`, mutates
`litter` and `soil` [kg C m⁻²], and overwrites `mixing`. The final correction
restores source-column carbon totals after the tridiagonal solves.

# Returns
`nothing`.

Called from [`_turbate!`](@ref).
"""
function _mix_column_cached!(litter, soil, parameters, active_layer, mixing)
    FT = eltype(litter)
    permeable = 0
    for layer in 1:N_SOIL_LAYERS
        parameters.isand[1, layer] in (-3, -4) && break
        permeable = layer
    end
    permeable == 0 && return nothing
    n = permeable + 2
    depth = mixing.depth
    litter_intermediate = mixing.litter_intermediate
    soil_intermediate = mixing.soil_intermediate
    litter_diffusivity = mixing.litter_diffusivity
    soil_diffusivity = mixing.soil_diffusivity
    fill!(depth, zero(FT))
    fill!(litter_intermediate, zero(FT))
    fill!(soil_intermediate, zero(FT))
    fill!(litter_diffusivity, zero(FT))
    fill!(soil_diffusivity, zero(FT))
    fill!(mixing.lower_diagonal, zero(FT))
    fill!(mixing.diagonal, one(FT))
    fill!(mixing.upper_diagonal, zero(FT))
    fill!(mixing.right_hand_side, zero(FT))
    fill!(mixing.solution, zero(FT))
    fill!(mixing.tridiagonal_work, zero(FT))
    for layer in 1:permeable
        depth[layer + 1] = parameters.zbotw[1, layer]
        litter_intermediate[layer + 1] = litter[layer]
        soil_intermediate[layer + 1] = soil[layer]
    end
    depth[n] =
        n <= N_SOIL_LAYERS ? parameters.zbotw[1, n] :
        parameters.zbotw[1, N_SOIL_LAYERS]
    diffusivity =
        active_layer <= one(FT) ? parameters.cryodiffus : parameters.biodiffus
    turbation_bottom = 1
    for layer in 1:n
        coefficient, in_turbation_range = if active_layer <= one(FT)
            if depth[layer] <= active_layer
                (diffusivity, true)
            elseif depth[layer] <= parameters.kterm * active_layer
                (
                    diffusivity * (
                        one(FT) -
                        (depth[layer] - active_layer) /
                        ((parameters.kterm - one(FT)) * active_layer)
                    ),
                    true,
                )
            else
                (zero(FT), false)
            end
        elseif depth[layer] <= FT(0.1)
            (diffusivity, true)
        elseif depth[layer] <= FT(0.3)
            (diffusivity * (one(FT) - (depth[layer] - FT(0.1)) / FT(0.2)), true)
        else
            (zero(FT), false)
        end
        litter_diffusivity[layer] = coefficient
        soil_diffusivity[layer] = coefficient * FT(parameters.spinfast)
        in_turbation_range && (turbation_bottom = layer)
    end
    _solve_mixing!(
        soil_intermediate,
        soil_diffusivity,
        depth,
        parameters,
        mixing,
        n,
    )
    _solve_mixing!(
        litter_intermediate,
        litter_diffusivity,
        depth,
        parameters,
        mixing,
        n,
    )
    previous_litter = sum(litter)
    previous_soil = sum(soil)
    for layer in 1:permeable
        litter[layer] = litter_intermediate[layer + 1]
        soil[layer] = soil_intermediate[layer + 1]
    end
    soil_correction = (previous_soil - sum(soil)) / FT(turbation_bottom)
    litter_correction = (previous_litter - sum(litter)) / FT(turbation_bottom)
    for layer in 1:turbation_bottom
        soil[layer] += soil_correction
        litter[layer] += litter_correction
    end
    return nothing
end

function _mix_column!(litter, soil, parameters, active_layer)
    FT = eltype(litter)
    return _mix_column_cached!(
        litter,
        soil,
        parameters,
        active_layer,
        _classic_cache(FT).mixing,
    )
end

"""
    _turbate!(state, parameters, forcing, mixing)

Apply conservative vertical mixing to every active carbon category.

When `parameters.turbation_on` is true, the function mutates `state` in place,
reads active-layer depth from `forcing`, and reuses `mixing`. Categories with
no positive soil carbon are unchanged.

# Returns
`nothing`.

Called from [`advance_stage_b!`](@ref).
"""
function _turbate!(state, parameters, forcing, mixing)
    parameters.turbation_on || return nothing
    for category in 1:N_CATEGORIES
        soil_column = view(state.soilcmas, 1, category, :)
        sum(soil_column) > parameters.zero || continue
        _mix_column_cached!(
            view(state.litrmass, 1, category, :),
            soil_column,
            parameters,
            forcing.max_annual_active_layer[1],
            mixing,
        )
    end
    return nothing
end

function _turbate!(state, parameters, forcing)
    FT = eltype(state.litrmass)
    return _turbate!(state, parameters, forcing, _classic_cache(FT).mixing)
end

# -----------------------------------------------------------------------------
# Public transition and callback seams
# -----------------------------------------------------------------------------

"""
    advance_stage_b!(cache, state, parameters, forcing)

Apply one allocation-free Stage B transition into reusable internal storage.

The function leaves `state`, `parameters`, and `forcing` unchanged. It mutates
all state, phase, audit, and turbation arrays owned by `cache`, preserving the
source order: pre-respiration transfers, respiration and pool update,
post-respiration transfers, then turbation. Positive transfer deltas add carbon;
positive respiration rates remove carbon.

# Arguments
- `cache`: Reusable transition and turbation storage mutated in place.
- `state`: Carbon pools at the start of the day [kg C m⁻²].
- `parameters`: CLASSIC Stage B parameters with matching precision.
- `forcing`: Ordered external forcing for the current day.

# Returns
The cache-owned `CLASSICTransition`. Its arrays are overwritten by the next
call using the same cache.

# Examples
```julia
using ClimaLand.Soil.Biogeochemistry.CLASSIC

function demo_inputs(::Type{FT} = Float64) where {FT}
    layer_shape = (1, N_SOIL_LAYERS)
    pool_shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
    depths = collect(range(FT(0.1); step = FT(0.1), length = N_SOIL_LAYERS))
    parameters = CLASSICParameters(;
        thpor = fill(FT(0.5), layer_shape),
        psisat = fill(FT(4), layer_shape),
        bi = ones(FT, layer_shape),
        isand = zeros(Int32, layer_shape),
        zbotw = reshape(copy(depths), layer_shape),
        zbot = depths,
        delzw = fill(FT(0.1), layer_shape),
        sort = Int32[1, 2, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14],
        bsratelt = ones(FT, N_PARAMETER_PFTS),
        bsratesc = ones(FT, N_PARAMETER_PFTS),
        humicfac = fill(FT(0.5), N_PARAMETER_PFTS),
        bsratelt_g = one(FT),
        bsratesc_g = one(FT),
        humicfac_bg = FT(0.5),
        tanhq10 = FT[2.16, 0.67, 0.075, 28.1],
        deltat = one(FT),
        tfrez = FT(273.16),
        zero = FT(1e-20),
        tcrit = -one(FT),
        frozered = FT(0.1),
        r_depthredu = FT(8.3),
        cryodiffus = zero(FT),
        biodiffus = zero(FT),
        kterm = FT(3),
        spinfast = Int32(1),
        turbation_on = false,
    )
    transfer = StageBTransfer(
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
    )
    forcing = CLASSICForcing(;
        tbar = fill(FT(288.16), layer_shape),
        thliq = fill(FT(0.25), layer_shape),
        thice = zeros(FT, layer_shape),
        fcancmx = zeros(FT, 1, N_PFTS),
        fg = ones(FT, 1),
        rmrveg = zeros(FT, 1, N_PFTS),
        rmr = zeros(FT, 1),
        max_annual_active_layer = fill(FT(2), 1),
        competition = transfer,
        land_use = transfer,
        harvest = transfer,
        turnover = transfer,
        mortality = transfer,
        disturbance = transfer,
    )
    state = CLASSICState(
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
    )
    return (; state, parameters, forcing)
end
inputs = demo_inputs()
cache = CLASSIC._classic_cache(Float64)
transition = CLASSIC.advance_stage_b!(
    cache,
    inputs.state,
    inputs.parameters,
    inputs.forcing,
)
transition.state.litrmass == inputs.state.litrmass
```


See also [`advance_stage_b`](@ref) and [`advance!`](@ref).
"""
function advance_stage_b!(
    cache::CLASSICCache{FT},
    state::CLASSICState{FT},
    parameters::CLASSICParameters{FT},
    forcing::CLASSICForcing{FT},
) where {FT}
    _validate_parameters(parameters)
    _validate_forcing(forcing)
    transition = cache.transition
    next_state = transition.state
    phases = transition.phases
    audit = transition.audit
    _copy_state!(next_state, state)
    _apply_transfer!(next_state, forcing.competition)
    _apply_transfer!(next_state, forcing.land_use)
    _apply_transfer!(next_state, forcing.harvest)
    _copy_state!(phases.after_pre_transfers, next_state)
    _respiration!(
        audit.ltresveg,
        audit.scresveg,
        next_state,
        parameters,
        forcing,
    )
    _update_pools_cached!(
        audit,
        next_state,
        parameters,
        forcing,
        audit.ltresveg,
        audit.scresveg,
    )
    _copy_state!(phases.after_pool_update, next_state)
    _apply_transfer!(next_state, forcing.turnover)
    _apply_transfer!(next_state, forcing.mortality)
    _apply_transfer!(next_state, forcing.disturbance)
    _copy_state!(phases.before_turbation, next_state)
    _turbate!(next_state, parameters, forcing, cache.mixing)
    for index in eachindex(next_state.litrmass)
        audit.turbation_litter_delta[index] =
            next_state.litrmass[index] - phases.before_turbation.litrmass[index]
        audit.turbation_soil_delta[index] =
            next_state.soilcmas[index] - phases.before_turbation.soilcmas[index]
    end
    return transition
end

"""
    advance_stage_b(state, parameters, forcing)

Apply one CLASSIC v2.0 mineral-soil Stage B transition in source order.
The input state is not mutated.

# Arguments
- `state`: Owned state at the start of the day [kg C m⁻²].
- `parameters`: Stage B parameters with the same floating-point precision.
- `forcing`: Ordered external forcing for the day.

# Returns
A newly allocated `CLASSICTransition` containing state, phases, and audits.

# Examples
```julia
using ClimaLand.Soil.Biogeochemistry.CLASSIC

function demo_inputs(::Type{FT} = Float64) where {FT}
    layer_shape = (1, N_SOIL_LAYERS)
    pool_shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
    depths = collect(range(FT(0.1); step = FT(0.1), length = N_SOIL_LAYERS))
    parameters = CLASSICParameters(;
        thpor = fill(FT(0.5), layer_shape),
        psisat = fill(FT(4), layer_shape),
        bi = ones(FT, layer_shape),
        isand = zeros(Int32, layer_shape),
        zbotw = reshape(copy(depths), layer_shape),
        zbot = depths,
        delzw = fill(FT(0.1), layer_shape),
        sort = Int32[1, 2, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14],
        bsratelt = ones(FT, N_PARAMETER_PFTS),
        bsratesc = ones(FT, N_PARAMETER_PFTS),
        humicfac = fill(FT(0.5), N_PARAMETER_PFTS),
        bsratelt_g = one(FT),
        bsratesc_g = one(FT),
        humicfac_bg = FT(0.5),
        tanhq10 = FT[2.16, 0.67, 0.075, 28.1],
        deltat = one(FT),
        tfrez = FT(273.16),
        zero = FT(1e-20),
        tcrit = -one(FT),
        frozered = FT(0.1),
        r_depthredu = FT(8.3),
        cryodiffus = zero(FT),
        biodiffus = zero(FT),
        kterm = FT(3),
        spinfast = Int32(1),
        turbation_on = false,
    )
    transfer = StageBTransfer(
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
    )
    forcing = CLASSICForcing(;
        tbar = fill(FT(288.16), layer_shape),
        thliq = fill(FT(0.25), layer_shape),
        thice = zeros(FT, layer_shape),
        fcancmx = zeros(FT, 1, N_PFTS),
        fg = ones(FT, 1),
        rmrveg = zeros(FT, 1, N_PFTS),
        rmr = zeros(FT, 1),
        max_annual_active_layer = fill(FT(2), 1),
        competition = transfer,
        land_use = transfer,
        harvest = transfer,
        turnover = transfer,
        mortality = transfer,
        disturbance = transfer,
    )
    state = CLASSICState(
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
    )
    return (; state, parameters, forcing)
end
inputs = demo_inputs()
transition = advance_stage_b(
    inputs.state,
    inputs.parameters,
    inputs.forcing,
)
transition.state.litrmass == inputs.state.litrmass
```

See also [`advance!`](@ref) and [`CLASSICTransition`](@ref).

"""
function advance_stage_b(
    state::CLASSICState{FT},
    parameters::CLASSICParameters{FT},
    forcing::CLASSICForcing{FT},
) where {FT}
    return advance_stage_b!(_classic_cache(FT), state, parameters, forcing)
end


"""
    advance!(model, Y, time)

Apply one allocation-free CLASSIC day to the model prognostic state.
The method selects forcing from `model.drivers` and mutates `Y` in place.

# Arguments
- `model`: Standalone model owning the reusable transition cache.
- `Y`: ClimaLand prognostic state mutated in place.
- `time`: End time of the discrete daily transition [simulation time].

# Returns
The cache-owned `CLASSICTransition`; copy fields before the next call if they
must be retained.

# Examples
```julia
using ClimaLand.Soil.Biogeochemistry.CLASSIC

function demo_inputs(::Type{FT} = Float64) where {FT}
    layer_shape = (1, N_SOIL_LAYERS)
    pool_shape = (1, N_CATEGORIES, N_SOIL_LAYERS)
    depths = collect(range(FT(0.1); step = FT(0.1), length = N_SOIL_LAYERS))
    parameters = CLASSICParameters(;
        thpor = fill(FT(0.5), layer_shape),
        psisat = fill(FT(4), layer_shape),
        bi = ones(FT, layer_shape),
        isand = zeros(Int32, layer_shape),
        zbotw = reshape(copy(depths), layer_shape),
        zbot = depths,
        delzw = fill(FT(0.1), layer_shape),
        sort = Int32[1, 2, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14],
        bsratelt = ones(FT, N_PARAMETER_PFTS),
        bsratesc = ones(FT, N_PARAMETER_PFTS),
        humicfac = fill(FT(0.5), N_PARAMETER_PFTS),
        bsratelt_g = one(FT),
        bsratesc_g = one(FT),
        humicfac_bg = FT(0.5),
        tanhq10 = FT[2.16, 0.67, 0.075, 28.1],
        deltat = one(FT),
        tfrez = FT(273.16),
        zero = FT(1e-20),
        tcrit = -one(FT),
        frozered = FT(0.1),
        r_depthredu = FT(8.3),
        cryodiffus = zero(FT),
        biodiffus = zero(FT),
        kterm = FT(3),
        spinfast = Int32(1),
        turbation_on = false,
    )
    transfer = StageBTransfer(
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
    )
    forcing = CLASSICForcing(;
        tbar = fill(FT(288.16), layer_shape),
        thliq = fill(FT(0.25), layer_shape),
        thice = zeros(FT, layer_shape),
        fcancmx = zeros(FT, 1, N_PFTS),
        fg = ones(FT, 1),
        rmrveg = zeros(FT, 1, N_PFTS),
        rmr = zeros(FT, 1),
        max_annual_active_layer = fill(FT(2), 1),
        competition = transfer,
        land_use = transfer,
        harvest = transfer,
        turnover = transfer,
        mortality = transfer,
        disturbance = transfer,
    )
    state = CLASSICState(
        zeros(FT, pool_shape),
        zeros(FT, pool_shape),
    )
    return (; state, parameters, forcing)
end
import ClimaLand
inputs = demo_inputs()
model = CLASSICSoilModel(
    inputs.parameters;
    drivers = ConstantForcingProvider(inputs.forcing),
)
Y, _, _ = ClimaLand.initialize(model)
transition = advance!(model, Y, model.callback_period)
state_from_prognostic(Y).litrmass == transition.state.litrmass
```

See also [`CLASSICSoilModel`](@ref) and [`state_from_prognostic`](@ref).

"""
function advance!(model::CLASSICSoilModel, Y, time)
    forcing = forcing_at(model.drivers, time)
    state_from_prognostic!(model.cache.input_state, Y)
    transition = advance_stage_b!(
        model.cache,
        model.cache.input_state,
        model.parameters,
        forcing,
    )
    set_prognostic_state!(Y, transition.state)
    return transition
end

"""
    DailyAdvance{M}

Adapt a `CLASSICSoilModel` to the integrator callback interface.
`M` is the concrete model type.

# Fields
- `model`: Standalone CLASSIC model advanced by each callback invocation.
"""
struct DailyAdvance{M}
    model::M
end

"""
    (advance::DailyAdvance)(integrator)

Advance `integrator.u` through the CLASSIC transition ending at `integrator.t`.
The call mutates the prognostic state and the model-owned cache.

# Returns
The cache-owned `CLASSICTransition` returned by [`advance!`](@ref).
"""
function (advance::DailyAdvance)(integrator)
    return advance!(advance.model, integrator.u, integrator.t)
end

"""
    Land.get_model_callbacks(model::CLASSICSoilModel; t0, Δt)

Return the daily discrete callback required by a standalone CLASSIC model.

# Arguments
- `model`: Standalone CLASSIC model that owns the callback cache.

# Keyword Arguments
- `t0`: Simulation start time.
- `Δt`: Integrator step size [s].

# Returns
A one-element tuple containing the interval-based daily callback.

See also [`advance!`](@ref).
"""
function Land.get_model_callbacks(model::CLASSICSoilModel; t0, Δt)
    callback = Land.IntervalBasedCallback(
        model.callback_period,
        t0,
        Δt,
        DailyAdvance(model),
    )
    return (callback,)
end
end
