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

## Ordered hourly map

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

## Spatial parameters and accelerators

`MIMICSSoilModel` accepts either one `MIMICSSoilModelParameters` value or a
surface `ClimaCore.Fields.Field` of those point values. A parameter field can
therefore carry gridded clay, kinetic, CWD, and PFT-dependent settings. Its
axes must equal `domain.space.surface`. The daily point map is broadcast over
the field on ClimaLand's active CPU or GPU backend; no scalar field indexing is
used in the tendency path.

## Carbon conservation

Microbial uptake losses are split between microbial growth and respiration.
All microbial turnover, protection, oxidation, and desorption fluxes are
internal. The combined daily budget is therefore

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
Timestep-independent continuous rates remain a post-parity task.
