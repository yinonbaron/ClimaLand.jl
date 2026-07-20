# MIMICS soil carbon and nitrogen

`MIMICSSoilModel` implements carbon-only and carbon-nitrogen MIMICS from the
soil biogeochemical testbed. It is a standalone ClimaLand soil
biogeochemistry model with explicit tendencies and a zero implicit tendency.

## State and units

The model uses eight surface-integrated carbon stocks.

| State | Testbed name | Meaning |
|---|---|---|
| `c_litter_metabolic` | LITm | metabolic litter |
| `c_litter_structural` | LITs | structural litter |
| `c_litter_cwd` | CWD | coarse woody debris |
| `c_microbe_r` | MICr | r-selected microbes |
| `c_microbe_k` | MICk | K-selected microbes |
| `c_soil_available` | SOMa | available soil carbon |
| `c_soil_chemical` | SOMc | chemically protected carbon |
| `c_soil_physical` | SOMp | physically protected carbon |

Native states use kg C m⁻². The seven MIMICS stocks are converted inside the
daily map to the legacy concentration unit mg C cm⁻³ using the configured
soil depth. CWD remains a surface stock, matching the testbed.

`CarbonNitrogen()` adds nitrogen counterparts for the seven MIMICS pools,
CWD N, and one ecosystem mineral-N stock. Native units are kg N m⁻². The DIN
value used during the 24-hour map is temporary working state initialized from
a configured fraction of mineral N; it is not a second prognostic stock.

## Drivers

The standalone model prescribes root-zone soil temperature, liquid and frozen
saturation, leaf/root metabolic and structural litter inputs, wood input to
CWD, litter metabolic fraction, and annual NPP. Litter inputs use
kg C m⁻² s⁻¹. Annual NPP uses kg C m⁻² yr⁻¹ and controls the bounded
microbial-turnover modifier.

The structural driver excludes CWD decomposition. MIMICS computes CWD loss,
adds its non-respired fraction to structural litter, and adds its respired
fraction to total heterotrophic respiration.

CN drivers additionally prescribe plant metabolic, structural, and wood N
inputs, deposition, fixation, and plant uptake. In a coupled model these are
replaced by live CASA plant fluxes, while MIMICS retains mineral-N ownership.

## Environmental response

The archived run uses the CORPSE moisture scalar

```math
f_W = \max\left(0.05,
\frac{\theta_l^3(1-\theta_l-\theta_f)^{2.5}}
{0.022600567942709}\right).
```

Temperature and moisture set six maximum reaction velocities:

```math
V_{max,j} = \exp(V_{s,j}T + V_{i,j})a_{v,j}V_{mod,j}f_W,
```

and temperature sets the six half-saturation constants:

```math
K_{m,j} = \frac{\exp(K_{s,j}T+K_{i,j})a_{k,j}}{K_{mod,j}}.
```

Clay modifies the SOMa half-saturation terms, microbial partitioning, and
desorption from SOMp.

## Temporal formulations

The carbon-only model defaults to the exact ordered daily map:

```julia
model = MIMICSSoilModel{FT}(;
    parameters,
    drivers,
    domain,
    temporal_mode = LegacyDaily(),
)
```

`ContinuousRate()` selects the timestep-independent simultaneous ODE. Both
modes use the same eight carbon states, drivers, parameters, auxiliary fields,
diagnostics, and restart layout. The carbon-nitrogen configuration currently
supports only `LegacyDaily()`.

### Ordered hourly map

Exact parity uses the reverse Michaelis--Menten equations. For example,
metabolic-litter uptake by r-selected microbes is

```math
F_{LITm,r} = \frac{MIC_r V_{max,r1} LIT_m}{K_{m,r1}+MIC_r}.
```

The denominator contains microbial biomass rather than substrate. Equivalent
fluxes are evaluated for structural litter and SOMa uptake by both microbial
groups. Microbial turnover is divided among SOMp, SOMc, and SOMa. SOMp
desorbs to SOMa, while both microbial groups oxidize SOMc to SOMa.

Each hour applies all fluxes to the current seven-pool state, then the next
hour recomputes fluxes from that updated state. Daily litter input is divided
equally among the 24 hourly updates. Heterotrophic respiration is accumulated
from the unused fraction of each substrate uptake.

The CN map moves substrate N in proportion to each source pool's current C:N,
partitions working DIN between microbial groups by biomass, applies four N-use
efficiencies, and enforces microbial C:N through carbon overflow or nitrogen
spill. Organic pools and working DIN are updated after every hour.

This sequential map is scientifically significant. Replacing it with one
daily derivative evaluation does not reproduce the Fortran input-output map.
ClimaLand therefore exposes the daily tendency as

```math
\dot C = \frac{\Phi_{24h}(C)-C}{86400}.
```

A native forward-Euler step with `dt = 86400` seconds applies exactly one
legacy MIMICS day.

### Simultaneous carbon rates

In `ContinuousRate`, decomposition, microbial turnover, litter protection,
desorption, oxidation, litter input, and CWD transfer all use the same current
state. Writing ``D_{rm}`` and ``D_{rs}`` for r-selected decomposition of
metabolic and structural litter, ``D_{ra}`` for r-selected SOMa decomposition,
and using analogous K-selected terms, the instantaneous pool equations are

```math
\begin{aligned}
\dot L_m &= (1-p_m)I_m-D_{rm}-D_{km},\\
\dot L_s &= (1-p_s)(I_s+F_{cwd})-D_{rs}-D_{ks},\\
\dot C_{cwd} &= I_{cwd}-D_{cwd},\\
\dot M_r &= \epsilon_{rm}(D_{rm}+D_{ra})+\epsilon_{rs}D_{rs}-T_r,\\
\dot M_k &= \epsilon_{km}(D_{km}+D_{ka})+\epsilon_{ks}D_{ks}-T_k,\\
\dot S_a &= T_{r,a}+T_{k,a}+F_d+F_o-D_{ra}-D_{ka},\\
\dot S_c &= p_s(I_s+F_{cwd})+T_{r,c}+T_{k,c}-F_o,\\
\dot S_p &= p_m I_m+T_{r,p}+T_{k,p}-F_d.
\end{aligned}
```

CWD decay is an instantaneous first-order loss; its non-respired fraction is
``F_{cwd}`` and enters structural litter in the same RHS evaluation. The
legacy MIMICS kinetic parameters remain expressed per hour, so the continuous
kernel converts their process fluxes to inverse seconds by dividing by 3600.
This is a unit conversion, not an integration timestep. No daily or hourly map,
partially updated pool, source-pool loss cap, or solver `dt` appears in the RHS.

`ContinuousRate` is a genuine ODE, so choose `dt` for numerical accuracy and
stability. No generic positivity limiter is applied. Forward Euler refinement
from 3600 to 450 seconds shows first-order convergence for the committed
representative state. Its refined one-day solution is
``2.2978\times10^{-8}`` relative L1 from `LegacyDaily`; that distance measures
the simultaneous-versus-ordered formulation and is gated independently of the
refinement test.

## Spatial parameters and accelerators

`MIMICSSoilModel` accepts either one `MIMICSSoilModelParameters` value or a
surface `ClimaCore.Fields.Field` of those point values. A parameter field can
therefore carry gridded clay, kinetic, CWD, and PFT-dependent settings. Its
axes must equal `domain.space.surface`. The point kernels are broadcast over
the field on ClimaLand's active CPU or GPU backend; no scalar field indexing is
used in the tendency path. Both temporal formulations are compile-time
dispatch choices and retain this broadcast path.

## Carbon conservation

Microbial uptake losses are split between microbial growth and respiration.
All microbial turnover, protection, oxidation, and desorption fluxes are
internal. The carbon budget in either temporal formulation is therefore

```math
\Delta C_{stocks} + R_h = I_{metabolic}+I_{structural}+I_{CWD}.
```

The test suite checks this identity for `Float32` and `Float64`.

For CN, plant uptake, CWD transfer, and microbial immobilization are internal.
The standalone budget includes prescribed litter inputs; in the coupled model
those inputs cancel against plant turnover. Gaseous loss and leaching are
explicit boundary losses.

## Validation

The committed productive-cell fixture is a source-exact slice of
`MIMICS_mod5_Conly_KO4.tar.gz`. Across 364 active daily transitions, the Julia
map reproduces all seven MIMICS pools within `2e-7` relative error. CWD is
reproduced from its companion CASA output, and total respiration agrees within
`2e-15` kg C m⁻² s⁻¹ absolute error. The remaining differences are the
rounding envelope from using archived `Float32` states as the next step's
inputs.

The same productive-cell forcing also regression-gates `ContinuousRate`
against the archived Fortran trajectory. With a 900-second Forward Euler step,
the maximum difference across 364 transitions is `0.000991 g C m^-2` for the
eight carbon pools and `3.59e-5 g C m^-2 day^-1` for daily heterotrophic
respiration. These are expected formulation and integration differences, not
parity tolerances; `LegacyDaily` remains the parity oracle.

The external grid-transition workflow extends this comparison to 20 cells
covering every productive archived PFT plus temperature, moisture, clay, and
inactive boundary extremes. Across 7,280 first-year transitions, maximum
relative pool error is ``1.14\times10^{-7}`` and maximum respiration-rate
error is ``3.27\times10^{-7}``. The inactive boundary retains its zero-state
check but is excluded from `fW`, because the archive writes zero outside the
active model while the standalone moisture kernel returns its physical
minimum. These values are measurements, not tolerance thresholds.

The parameter file found in the repository is recorded as a candidate because
the original archived control directory is unpublished. The output
relationships nevertheless reproduce the archive at its stored precision.

The productive MIMICS-CN fixture adds 364 checks of the seven organic-N pools,
working DIN, microbial overflow, litter and soil mineralization,
immobilization, and respiration. The pure ordered map and native 17-state
standalone model both have independent C and N conservation gates. Integrated
CASA-plant/MIMICS-soil tests cover equal-and-opposite litter, CWD-N, and plant
uptake transfers for both floating-point precisions.

## Diagnostics and restart

All carbon and nitrogen MIMICS/CWD states are registered under their component and field
names, from `mimics_soil_c_litter_metabolic` through
`mimics_soil_c_soil_physical`. Heterotrophic respiration and the metabolic,
structural, and coarse-woody-debris inputs are registered as SI-rate
diagnostics. Gaseous N loss and leaching are also registered. Standard
ClimaLand HDF5 checkpoints preserve the complete state for standalone and
coupled runs; the 17-state CN layout has a native checkpoint round-trip test.

Uniform and heterogeneous native spatial gates exercise the 17-state CN model.
The CN archive-grid workflow validates 6,916 active transitions across 19
representative productive cells. Maximum relative error across the seven C and
seven organic-N pools is below ``1.2\times10^{-7}``; working-DIN and respiration
absolute errors are below ``6.2\times10^{-10}`` kg m⁻². One additional
ice/water cell records the Fortran driver-mask boundary but is not treated as a
standalone MIMICS update. CUDA execution remains to be run on a CUDA host.
The carbon-nitrogen model retains the ordered daily formulation; simultaneous
nitrogen rates are outside the carbon-only `ContinuousRate` scope.
