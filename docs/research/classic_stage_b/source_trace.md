# Stage B source trace and numerical contract

## Pinned authority

| Artifact | Pinned value |
|---|---|
| Source record | Zenodo 18188101 |
| Source archive SHA-256 | `8b7a9b7bc50c4b63bdb4aad9e5037406b919100616684a2c1c8c738b6ebe7ef8` |
| Tag | `CLASSICv2.0` |
| Commit | `7dd82c9a48a7c8beb6455a229888c90ba20d8eff` |
| Fresh local executable SHA-256 | `20bd7e0b19815f9971a7c9b6afd90d7ddf30223b20be5154e80382298e292b19` |
| Fresh DE-Hai parameter namelist SHA-256 | `9f3ff5bdbf8e10e5825f4a07e57028cdd376690f7c7bcf765734ea1ab47e16ce` |
| Fresh DE-Hai job-options SHA-256 | `f775e4085d7393a9f6b2ad04e99cdeae0999a51f07e9cb4a4575cf381aa96a06` |

These values are recorded in
`test/testbed_validation/classic_reference_workspace/de_hai/execution_receipt.toml`.
The source uses default `real`, and the released offline Makefile compiles with
`-fdefault-real-8`; Stage B parity is therefore Float64-first.

## Vertical geometry provenance

`ctemDriver.F90:195--197` distinguishes `zbot[ignd]`, the total bottom depth
of every model layer, from tile-specific `zbotw[ilg,ignd]` and
`delzw[ilg,ignd]`. `modelStateDrivers.f90:954--961` reads `DELZ` from the
initialization and forms `zbot` by cumulative summation.
`soilProperties.f90:117--131` derives the permeable thickness `delzw` and
permeable bottom depth `zbotw`, assigning zero thickness below permeable soil.
A truthful Julia mesh therefore uses `static.zbot`; `static.zbotw` and
`static.delzw` remain parameter fields for the active permeable column.

## Verified call-order locations

Line numbers below refer to the pinned v2.0 files.

| Source | Lines | Verified fact |
|---|---:|---|
| `src/base/mainCore.F90` | 2126--2158 | Daily averages are finalized when `ncount == nday`, then `ctem` is called |
| `src/base/ctemUtilities.f90` | 182--300 | Physics-step accumulation of `tbar`, `thliq`, and `thice` |
| `src/base/ctemUtilities.f90` | 122--153 | Daily arithmetic means are formed before CTEM |
| `src/base/ctemDriver.F90` | 774--821 | Competition runs before land use and respiration |
| `src/base/ctemDriver.F90` | 837--887 | Land use, then timber harvest |
| `src/base/ctemDriver.F90` | 957--961 | `fc` and `fg` are computed after those mutations |
| `src/base/ctemDriver.F90` | 1000--1007 | `heterotrophicRespiration` call and exact argument order |
| `src/base/ctemDriver.F90` | 1018--1026 | `updatePoolsHetResp` immediately follows |
| `src/base/ctemDriver.F90` | 1049--1120 | Allocation/phenology/turnover calculation and litter-pool transfer |
| `src/base/ctemDriver.F90` | 1122--1188 | Mortality and its pool transfer |
| `src/base/ctemDriver.F90` | 1189--1226 | Disturbance/fire and litter mutation |
| `src/base/ctemDriver.F90` | 1241--1252 | Carbon and tracer turbation calls |
| `src/base/ctemDriver.F90` | 1261--1279, 1395--1417 | Carbon preparation and balance audits after turbation |

## Respiration numerical contract

The mineral path is in
`src/base/heterotrophicRespirationMod.f90:119--285,340--366`.

For each tile/layer, CLASSIC derives matric potential from the daily liquid and
ice fractions and static hydraulic properties. It then uses piecewise litter
and SOM moisture scalars, each finally clamped to `[0.2, 1.0]`. Litter in the
surface layer is not inhibited by saturated mineral soil; deeper litter uses
the SOM wetness response.

The temperature-dependent Q10 is

```text
q10 = tanhq10[1] + tanhq10[2] *
      tanh(tanhq10[3] * (tanhq10[4] - (tbar - TFREZ)))
temperature_factor = q10 ^ (0.1 * (tbar - TFREZ - 15))
```

When `tbar - TFREZ <= tcrit`, the factor is multiplied by `frozered`. When
the turbation switch is on, both litter and SOM respiration are additionally
multiplied by `exp(-zbotw / r_depthredu)`; otherwise that factor is exactly 1.

For a vegetated PFT `j`, the rates are

```text
ltresveg = litter_moisture * litrmass * bsratelt[sort[j]] *
           2.64 * litter_temperature_factor * depth_factor
scresveg = soil_moisture * soilcmas * bsratesc[sort[j]] *
           2.64 * soil_temperature_factor * depth_factor
```

Bare ground uses `bsratelt_g` and `bsratesc_g`. Rates are positive carbon
losses in `umol CO2 m-2 s-1`. The hard-coded `2.64` conversion and the precise
operation order are part of the parity contract.

## Pool-update numerical contract

The mineral path is in
`src/base/heterotrophicRespirationMod.f90:698--876,878--893`.
For each owned category/layer:

```text
litter_resp_step = ltresveg * deltat / 963.62
soil_resp_step   = scresveg * deltat / 963.62
humification     = humic_factor * litter_resp_step

litrmass = max(0,
    litrmass - litter_resp_step - humification)
soilcmas = max(0,
    soilcmas + spinfast * (humification - soil_resp_step))
humtrsvg = humification * 963.62 / deltat
```

`humic_factor` is `humicfac[sort[j]]` for PFTs and `humicfac_bg` for bare
ground. It is a ratio to litter respiration, not a fraction of the total litter
loss. Humification is an internal positive transfer: it leaves litter and
enters SOM. `spinfast` accelerates the SOM gain/loss term but not the litter
pool loss.

With `spinfast == 1` and no nonnegative clamp, the unweighted per-category
column budget is

```text
delta(sum(litter + soilC)) =
    -sum(litter_resp_step) - sum(soil_resp_step)
```

For general `spinfast`, the expected update is

```text
delta(total) = -Lresp - spinfast * Sresp
               + (spinfast - 1) * humification
```

Instrumentation must report the positive correction introduced by each
nonnegative clamp separately; otherwise a depleted-pool branch looks like a
carbon-budget error.

The routine's `humtrsvg` declaration and assignment both establish units of
`umol CO2 m-2 s-1`. Any fixture schema labeling it `kg C m-2 step-1` is
incorrect; the timestep quantity is the local `hutrstep`, not `humtrsvg`.

## Turbation numerical contract

The complete routine is `src/base/soilCProcesses.f90:25--288`.

- It runs only for mineral tiles (`peatlandType == 'None'`).
- The permeable column ends before the first `isand == -3` or `-4`.
- It loops over `j = 1:iccp1`; product slot `iccp2` does not move.
- It skips a category unless total SOM is greater than `zero`.
- `actlyr <= 1 m` selects cryoturbation. Its coefficient is constant to the
  active-layer depth and decreases linearly to zero at `kterm * actlyr`.
- `actlyr > 1 m` selects bioturbation. Its coefficient is constant through
  0.1 m and decreases linearly to zero at 0.3 m.
- `spinfast` multiplies SOM diffusivity; it never multiplies litter
  diffusivity.
- A Crank-Nicolson tridiagonal solve uses `termr = D * deltat / dzm^2` and zero
  values at the surface and bottom boundary interfaces.
- After solving, any column-sum difference is spread uniformly across layers
  `1:turblyrbot`, separately for litter and SOM.

The corrective redistribution means post-turbation column sums should equal
pre-turbation sums to floating precision, but individual layers can receive a
small uniform correction. Julia must reproduce that correction and its order,
not replace the algorithm with a nominally conservative alternative during
initial parity.

## Parameter inventory

| Parameter | Unit/meaning | Fresh local value |
|---|---|---|
| `deltat` | CTEM step, days | `1.0` (compiled constant) |
| `TFREZ` | freezing point, K | `273.16` (compiled constant) |
| `zero` | presence threshold | `1e-20` (compiled constant) |
| `tanhq10` | Q10 coefficients | `[2.16, 0.67, 0.075, 28.1]` |
| `bsratelt` | PFT litter base rates, `kg C kgC-1 yr-1` | 15-entry namelist vector; use `sort` |
| `bsratesc` | PFT SOM base rates, same unit | 15-entry namelist vector; use `sort` |
| `bsratelt_g` | bare litter base rate | `0.5605` |
| `bsratesc_g` | bare SOM base rate | `0.02258` |
| `r_depthredu` | respiration depth e-folding scale, m | `8.3` |
| `tcrit` | frozen inhibition threshold, degC | `-1.0` |
| `frozered` | frozen respiration multiplier | `0.1` |
| `humicfac` | PFT humification/respiration ratio | 15-entry namelist vector; use `sort` |
| `humicfac_bg` | bare humification/respiration ratio | `0.45` |
| `cryodiffus` | cryoturbation diffusivity, `m2 d-1` | `1.26873e-6` |
| `biodiffus` | bioturbation diffusivity, `m2 d-1` | `3.57059e-7` |
| `kterm` | cryoturbation cutoff multiplier | `3.0` |
| `spinfast` | SOM acceleration factor | `1` in the fresh parity run |
| `turbationON` | respiration-depth and movement switch | `.true.` in the fresh parity run |

The generated namelist, not `model_parameters.json` alone, is the run-time
parameter authority. All parameter arrays and switches must be bundled with
their hashes for another oracle generation.

## External-process source facts

| Process | Source fact establishing the boundary |
|---|---|
| Competition | `competitionMod.f90:478--494` declares litter, SOM, and cover `intent(inout)`; the call is before respiration |
| Land use | `landuseChangeMod.f90:182--194` declares litter, SOM, vegetation, and cover `intent(inout)`; lines 1212--1223 create paper/furniture in `iccp2`, layer 1 |
| Timber harvest | `tiledDisturbance.f90:24--34` accepts litter and SOM `inout`; its call is before respiration |
| Vegetation turnover | `turnoverMod.f90:412--435` adds leaf/stem/reproduction to layer 1 and distributes roots by `rmatctem` |
| Mortality | `mortality.f90:440--459` adds stem/leaf litter to layer 1 and distributes roots by `rmatctem` |
| Fire/disturbance | `disturbance.f90:19--48` has litter but no SOM state argument; lines 1013--1053 add killed biomass and subtract burned litter |
| Product decay | `heterotrophicRespirationMod.f90:265--287` computes `iccp2` respiration without area weighting; `updatePoolsHetResp` mutates it, but `soilCProcesses.f90:111--113` explicitly excludes it from movement |

`disturbance` reports `fFireCsoil` from litter below layer 1
(`disturbance.f90:952--963`). Despite its name, it is not combustion of
`soilcmas`; no SOM pool is passed to that routine.

## Remaining ambiguity and required measurement

The scientific boundary itself is closed. Two extraction details must be
measured rather than inferred:

1. The instrumentation must demonstrate that its ordinary outputs match the
   corresponding uninstrumented fresh local oracle before snapshots are used.
2. Transfer deltas around disabled processes are expected to be exact zero in
   the released DE-Hai configuration (`PFTCompetition`, `lnduseon`,
   `timberHarvest`, and `dofire` are false). Pathway fixtures with a minimally
   derived configuration are still required to exercise and validate nonzero
   transfers.

Neither point changes ownership or order. Published CBC mismatch provenance
remains separate and does not weaken the fresh local Fortran oracle contract.
