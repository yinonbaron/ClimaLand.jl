# CORPSE soil carbon

`CORPSESoilModel` implements the carbon-only CORPSE configuration from the
soil biogeochemical testbed. It is an explicit standalone ClimaLand model with
the fixed rhizosphere and bulk cohorts used by the reference experiment.

## State and units

All stocks use kg C m⁻². Coarse woody debris is one surface stock. The
soil-rhizosphere, soil-bulk, litter-rhizosphere, and litter-bulk cohorts each
have nine named scalar states:

| State group | Number | Meaning |
|---|---:|---|
| unprotected flavors | 3 | labile, recalcitrant, dead microbial substrate |
| protected flavors | 3 | aggregate/mineral protected substrate |
| live microbial carbon | 1 | decomposer biomass |
| cumulative CO₂ | 1 | reference respiration bookkeeping |
| original carbon | 1 | reference carbon/volume bookkeeping |

Cumulative CO₂ and original carbon are retained because the Fortran cohort
type carries them across days. They are not active ecosystem carbon stocks.
The general Fortran cohort insertion, culling, and merging machinery is not
used: the testbed has exactly two cohorts per layer.

## Drivers and litter routing

The prescribed drivers are soil temperature, liquid and frozen saturation,
labile and recalcitrant leaf litter, labile and recalcitrant root litter,
requested labile exudate, and wood input to CWD. Carbon inputs use
kg C m⁻² s⁻¹.

For testbed `litter_option = 1`, leaf, root, and transformed CWD all enter the
soil pool. Thirty percent enters the rhizosphere cohort and the rest enters
the bulk cohort. Exudate is limited by available labile litter, removed from
that litter input, and added entirely to the rhizosphere. `litter_option = 2`
instead sends leaf litter to the fixed litter-layer cohort.

## Environmental response

For substrate flavor ``j``, the centered Arrhenius rate is

```math
V_j(T) = V_{j,ref}\exp\left[
\frac{E_{a,j}}{R}\left(\frac{1}{293.15}-\frac{1}{T}\right)
\right].
```

The moisture multiplier is

```math
f_W = \max\left[f_{W,min},
(\theta_l^3+0.001)
\max\left(\theta_{air}^{2.5}, f_{anaerobic,min}\right)\right].
```

Unprotected decomposition then uses the microbial reverse
Michaelis--Menten expression

```math
R_j = V_j f_W
\frac{C_j C_{mic} f_{enz}}{K_{C,j}\sum_k C_k+C_{mic}f_{enz}}.
```

In the legacy formulation, loss in one day is capped at the available source
pool. The simultaneous formulation uses the same environmental and kinetic
responses as instantaneous rates without a timestep-dependent cap.

## Temporal formulations

The model defaults to the exact ordered daily map:

```julia
model = CORPSESoilModel{FT}(;
    parameters,
    drivers,
    domain,
    temporal_mode = LegacyDaily(),
)
```

Its calculation order follows `corpse_soil_carbon.f90`:

1. add litter and its minimum microbial share;
2. add capped exudate to the rhizosphere;
3. decompose unprotected carbon;
4. decompose protected carbon;
5. update microbes from the already modified substrate pools;
6. route microbial turnover to dead-microbial carbon and CO₂;
7. turn over protected carbon and form new protected carbon from the already
   modified unprotected pools.

The protected formation rate is the product of the configured protection
rate, flavor multiplier, and mineral protection capacity. The pinned setup
sets protected decomposition to zero and uses non-microbial protection.

ClimaLand exposes the exact daily map as

```math
\dot C = \frac{\Phi_{day}(C)-C}{86400}.
```

A ClimaTimeSteppers Forward Euler step with `dt = 86400` seconds therefore
applies one reference day exactly. Timestep-independent continuous rates are
selected with `temporal_mode = ContinuousRate()`.

In `ContinuousRate`, every process uses the same current state. For substrate
flavor ``j``, the cohort ODE is

```math
\begin{aligned}
\dot U_j &= I_j - R_{U,j} - F_j + T_{P,j}
           + \delta_{j,dead}\eta_T T_M,\\
\dot P_j &= F_j - R_{P,j} - T_{P,j},\\
\dot M &= I_M + \sum_j \epsilon_j(R_{U,j}+R_{P,j}) - T_M,\\
\dot C_{CO_2} &= \sum_j(1-\epsilon_j)(R_{U,j}+R_{P,j})
                 +(1-\eta_T)T_M.
\end{aligned}
```

Here ``U`` and ``P`` are unprotected and protected substrate, ``M`` is live
microbial carbon, ``F`` is protection, and ``T_P`` and ``T_M`` are protected
and microbial turnover. Litter is split between substrate and the reference
minimum-microbial share as an instantaneous input; exudate enters unprotected
labile carbon. CWD decay is likewise a continuous first-order loss. Protection,
decomposition, turnover, litter addition, and exudation do not observe one
another's within-call results.

This is a genuine ODE, so `dt` is chosen for numerical accuracy and stability,
not to define the process equations. No generic positivity limiter is applied.
Forward Euler convergence tests halve `dt` from 3600 to 450 seconds. For the
committed representative state, the refined one-day active-pool solution is
about `1.06e-5` relative L1 from `LegacyDaily`; the remaining distance is the
intentional simultaneous-versus-ordered formulation difference. Across the
pinned 365-day productive-cell forcing, a 900-second Forward Euler integration
has maximum pool and daily-respiration differences of `0.194 g C m^-2` and
`0.00119 g C m^-2`, respectively, from the Fortran daily-map output.

## Spatial parameters and accelerators

`CORPSESoilModel` accepts either one `CORPSESoilModelParameters` value or a
surface `ClimaCore.Fields.Field` of those point values. This supports gridded
mineral-protection capacity, layer geometry, rhizosphere fraction, litter
routing, CWD, and kinetic parameters. Field axes must equal
`domain.space.surface`. Both temporal formulations are compile-time dispatch
choices. Their fixed-cohort point kernels are broadcast without scalar field
indexing, so they execute on ClimaLand's active CPU or GPU backend.

## Carbon conservation

Decomposition is split among microbial uptake, heterotrophic respiration,
and internal transfers. Protection and microbial turnover are internal. The
active-stock budget is

```math
\Delta C_{active} + R_h = I_{leaf}+I_{root}+I_{CWD}.
```

Exudate is a transfer from the supplied labile litter input and is not counted
again as an external input.

## Validation status

The committed reproducibility probe compiles the pinned Fortran
`corpse_soil_carbon.f90`, reads `corpse_params_12.18d.2017.nml`, and advances a
nonzero cohort by one day. All nine Julia `Float32` states match the Fortran
values exactly; daily CO₂ is within two Float32 ULP. Float32 and Float64
kernel tests also check inference, zero allocation, and carbon conservation.

The authoritative exact-parity integration fixture is a fresh, pinned Fortran run for
productive GSWP3 cell 11060. Across 365 sequential days, all seven aggregate
soil pools agree within `2e-6` g C m⁻² absolute error.
Daily soil CO₂ differs by less than `2e-8` g C m⁻². The moisture multiplier
differs by less than `4e-18`.

`ContinuousRate` is tested separately against that same fixture because a
simultaneous ODE cannot be algebraically identical to the ordered, capped
daily map. It retains the reference parameters, state definitions, litter and
exudate routing, environmental responses, and annual-to-second rate
conversion, and the measured differences above are regression-gated.

The local `corpse_pool_flux_2000-2010_mean.nc` remains informational. It uses
an older 4,299-cell CLM4.5/CRU-NCEP experiment whose meteorology and exact CASA
restart are not published here; the available 4,263-cell CLM5/GSWP3 inputs are
not a scientifically valid substitute. The validation provenance records the
source-history, control, restart, forcing, and postprocessing attempts that
led to selection of the fresh reference.

## Diagnostics and restart

Every fixed-cohort prognostic field is a registered ClimaLand diagnostic using
the `corpse_soil_` prefix, including active pools, cumulative CO₂, and the
original-carbon bookkeeping states. Heterotrophic respiration and all six
external/coupling inputs are registered separately. Native ClimaLand HDF5
checkpoints round-trip all 37 fields, so the bookkeeping state required by
later ordered updates is not reconstructed or discarded.
