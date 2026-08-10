# Stage B interface inventory

This inventory classifies every argument of the three Stage B Fortran seams.
`B` identifies a value active in the mineral-soil cut. `C` and `D` identify
arguments present in the upstream routine but deliberately excluded until
later stages. Static dimensions, configuration, and parameters are not dynamic
fields; every dynamic B field is classified as owned state, external forcing,
reference state, or audit diagnostic.

## Dimensions and indexing

| Name | CLASSIC v2.0 meaning | Fresh offline oracle |
|---|---|---|
| `tile` | Gathered land element `i = il1:il2`; a grid-cell/mosaic-tile pair, not an area-aggregated site | `il1 = 1`, `il2 = ilg`; site runs use one tile |
| `pft` | CTEM PFT `j = 1:icc` | `icc = 12` |
| `bare` | `j = iccp1 = icc + 1` | slot 13 |
| `product` | `j = iccp2 = icc + 2`; paper/furniture product state | slot 14, excluded from owned state |
| `pft_or_bare` | `j = 1:iccp1` | 13 separately retained categories |
| `layer` | Native soil layer `k = 1:ignd`, top to bottom | `ignd = 20` |
| `parameter_pft` | PFT parameter-vector position selected by `sort(j)` | length `kk = l2max * ican = 15` |

For the released 12-PFT setup, `modelpft = [1,1,0,1,1,1,1,1,0,1,1,1,1,1,0]`.
Consequently `sort` maps the 12 CTEM PFTs to parameter positions
`[1,2,4,5,6,7,8,10,11,12,13,14]`; unused parameter positions are never a
state dimension.

Pool values are carbon densities on their PFT or bare-ground subarea, not
already multiplied by cover. Tile aggregates multiply PFT pools/fluxes by
`fcancmx` and the bare pool/flux by `fg`. Product pools are the exception:
CLASSIC treats `iccp2` as grid averaged and does not area-weight its decay.

Array storage in extracted snapshots must retain Fortran column-major ordering
and explicit dimension labels. Missing PFTs and inactive layers remain present;
they are masked by cover or soil flags rather than squeezed out. The mesh
coordinate is `zbot[layer]`, the cumulative bottom depth of every total layer.
`zbotw[tile,layer]` and `delzw[tile,layer]` instead describe the permeable
portion of each layer and can be zero below the tile-specific soil depth.

## Units and sign conventions

| Quantity | Unit | Positive direction |
|---|---|---|
| `litrmass`, `soilcmas` | `kg C m-2` | Carbon stored in the pool |
| External pool delta | `kg C m-2 step-1` | Carbon added to the owned pool (`after - before`) |
| `ltresveg`, `scresveg`, `humtrsvg` | `umol CO2 m-2 s-1` | Respiration leaves the ecosystem; humification moves litter to SOM |
| Aggregated `litres`, `socres`, `hetrores` | `umol CO2 m-2 s-1` | Carbon leaves the ecosystem |
| `soilresp` after `updatePoolsHetResp` | `kg C m-2 step-1` | Carbon leaves litter/SOM/root respiration combined |
| `tbar` | `K` | Absolute temperature |
| `thliq`, `thice`, `thpor` | `m3 m-3` | Volumetric fraction |
| `psisat`, `zbot`, `zbotw`, `delzw`, `maxAnnualActLyr` | `m` | Positive magnitudes/depths below the surface as stored by CLASSIC |
| `fcancmx`, `fg`, moisture/Q10/depth scalars | `1` | Dimensionless |
| `rmrveg`, `rmr` | `umol CO2 m-2 s-1` | Root respiratory carbon loss |

The exact Fortran conversion from a respiration rate to a one-day pool loss is
`rate * deltat / 963.62`. The translation must use the literal `963.62`, not a
newly recomputed molar conversion. `deltat = 1.0` day in this discrete kernel.

## `heterotrophicRespiration`

| Argument | Scope | Role | Shape/unit | Stage B meaning |
|---|---|---|---|---|
| `il1`, `il2`, `ilg` | B | Static dimension | integer | Active tile range and allocated leading extent |
| `peatlandType` | B/C | Static configuration/mask | `tile`, character | B requires `'None'`; other values select C peat paths |
| `mossPresent` | C | Excluded configuration | `tile`, character | Not consumed by the mineral cut |
| `fcancmx` | B | External forcing | `tile,pft`, `1` | Cover after competition/LUC and before respiration |
| `litrmass` | B | Owned state | `tile,pft_or_bare,layer`, `kg C m-2` | Pre-respiration litter; `iccp2` slice is excluded external product state |
| `soilcmas` | B | Owned state | same | Pre-respiration SOM; `iccp2` slice is excluded external product state |
| `delzw` | C | Static geometry, B-inert | `tile,layer`, `m` | Used by peat respiration, not mineral equations |
| `thpor` | B | Static soil parameter | `tile,layer`, `m3 m-3` | Total porosity |
| `tbar` | B | External forcing | `tile,layer`, `K` | Daily-mean soil temperature |
| `psisat` | B | Static soil parameter | `tile,layer`, `m` | Saturated matric potential |
| `thliq` | B | External forcing | `tile,layer`, `m3 m-3` | Daily-mean liquid water content |
| `sort` | B | Static mapping | `pft`, integer | Maps state PFT index to parameter-vector index |
| `bi` | B | Static soil parameter | `tile,layer`, `1` | Brooks-Corey/Clapp-Hornberger exponent |
| `isand` | B | Static layer mask | `tile,layer`, integer | `-3` bedrock, `-4` ice sheet/glacier; other values are permeable soil for this kernel |
| `thice` | B | External forcing | `tile,layer`, `m3 m-3` | Daily-mean frozen water content |
| `fg` | B | External forcing | `tile`, `1` | Bare fraction, exactly `1 - sum(fcancmx)` at the call point |
| `litrmsmoss`, `upMossSoilC` | C | Excluded state | layered carbon pools | Moss pools are not B forcing or state |
| `peatdep`, `wtable` | C | Excluded forcing/state | `tile`, `m` | Peat pathway only |
| `zbotw` | B | Static permeable geometry | `tile,layer`, `m` | Permeable layer-bottom depth; controls depth attenuation when turbation is enabled |
| `useTracer` | D | Excluded configuration | character | B uses `'None'` |
| `tracerLitrMass`, `tracerSoilCMass`, `tracerMossLitrMass` | D | Excluded state | tracer pools | Never part of B state |
| `ltresveg` | B | Audit diagnostic | `tile,pft_or_product,layer`, `umol CO2 m-2 s-1` | Per-category/layer litter respiration; only `1:iccp1` belongs to B audit |
| `scresveg` | B | Audit diagnostic | same | Per-category/layer SOM respiration |
| `litresmoss`, `socres_peat`, `socres_moss`, `resoxic`, `resanoxic` | C | Excluded diagnostic | C fluxes | Not B forcing |
| tracer respiration outputs | D | Excluded diagnostic | tracer fluxes | Not B forcing |

`ltresveg` and `scresveg` are outputs of this routine and inputs to
`updatePoolsHetResp`. They remain audit/translation intermediates: trajectory
forcing must not serialize them as externally prescribed values and bypass the
Julia respiration calculation.

## `updatePoolsHetResp`

| Argument | Scope | Role | Shape/unit | Stage B meaning |
|---|---|---|---|---|
| `il1`, `il2`, `ilg` | B | Static dimension | integer | Tile range |
| `fcancmx`, `fg` | B | External forcing | cover fractions | Same application-point cover used by respiration |
| `ltresveg`, `scresveg` | B | Audit diagnostic | layered rates | Outputs of the immediately preceding owned kernel |
| `peatlandType`, `mossPresent` | B/C | Static mask/configuration | character | Mineral B requires no peat/moss |
| peat/moss rate inputs | C | Excluded diagnostic | rates | Not B forcing |
| `sort` | B | Static mapping | `pft`, integer | Parameter lookup |
| `spinfast` | B | Static run parameter | integer | Normal parity is 1; scales SOM mutation and SOM diffusivity, not litter respiration |
| `rmrveg` | B | External forcing | `tile,pft`, `umol CO2 m-2 s-1` | External root respiration used only in `soilresp` audit |
| `rmr` | B | External forcing | `tile`, same unit | Tile root respiration argument; present but not read by this routine's B equations |
| `leapnow` | C | Excluded calendar forcing | logical | Only moss litterfall uses it |
| `useTracer`, tracer rate inputs | D | Excluded configuration/diagnostic | tracer | Not B |
| `litrmass`, `soilcmas` | B | Owned state | `tile,pft_or_bare,layer`, `kg C m-2` | Mutated in place; product slice excluded from B even though Fortran also mutates it |
| moss/peat carbon pools | C | Excluded state | carbon pools | Not B |
| tracer pools | D | Excluded state | tracer pools | Not B |
| `hetrsveg` | B | Audit diagnostic | `tile,pft_or_bare`, `umol CO2 m-2 s-1` | Layer-summed litter + SOM respiration on each subarea |
| `litres`, `socres`, `hetrores` | B | Audit diagnostic | `tile`, `umol CO2 m-2 s-1` | Cover-weighted tile litter, SOM, and total heterotrophic respiration |
| `humtrsvg` | B | Audit diagnostic | `tile,pft_or_product,layer`, `umol CO2 m-2 s-1` | Positive internal litter-to-SOM transfer; only `1:iccp1` is B |
| `soilresp` | B | Audit diagnostic | `tile`, `kg C m-2 step-1` | Cover-weighted heterotrophic + root respiration after unit conversion |
| `humiftrs` | B | Audit diagnostic | `tile`, `umol CO2 m-2 s-1` | Cover-weighted humification rate |
| moss/peat timestep outputs | C | Excluded diagnostic | C pathway outputs | Not B |

`rmr` is declared and passed but is not referenced in the routine body. It is
recorded only if exact full-call argument capture is required; it cannot affect
Stage B state or diagnostics in v2.0.

## `turbation`

| Argument | Scope | Role | Shape/unit | Stage B meaning |
|---|---|---|---|---|
| `il1`, `il2` | B | Static dimension | integer | Tile range; `ilg` is module-global in this routine |
| `zbotw` | B | Static permeable geometry | `tile,layer`, `m` | Permeable bottom depth used by the turbation solver; total mesh geometry remains `zbot` |
| `isand` | B | Static layer mask | `tile,layer`, integer | First `-3`/`-4` terminates the permeable column |
| `actlyr` (`maxAnnualActLyr`) | B | External forcing | `tile`, `m` | Slowly evolving maximum active-layer depth at this daily call |
| `spinfast` | B | Static run parameter | integer | Multiplies SOM diffusivity only |
| `peatlandType` | B/C | Static mask | `tile`, character | Turbation runs only where value is `'None'` |
| `litter`, `soilC` | B | Owned state | `tile,pft_or_bare,layer`, `kg C m-2` | Mutated vertically; routine loops only through `iccp1`, so product slot never moves |

The routine has no flux output. Instrumentation must therefore record its
pre/post reference state, derive the per-layer turbation delta as an audit
diagnostic, and record before/after column sums. Turbation is skipped for a
tile with no permeable layer, and for a category whose total SOM is not greater
than `zero`; the code assumes meaningful litter movement only accompanies a
positive SOM pool.

## External transfer inventory and exact application points

| Dynamic field | Role | Shape/unit | Capture definition |
|---|---|---|---|
| `competition_delta_litter`, `competition_delta_soil` | External forcing | `tile,pft_or_bare,layer`, `kg C m-2 step-1` | Owned slices immediately after minus immediately before `competition` |
| `land_use_delta_litter`, `land_use_delta_soil` | External forcing | same | Difference around `luc`, excluding `iccp2` |
| `harvest_delta_litter`, `harvest_delta_soil` | External forcing | same | Difference around `harvestTile`, excluding `iccp2` |
| `fcancmx`, `fg` | External forcing | tile/PFT fractions | Capture after the three pre-respiration processes and the driver's `fg` calculation |
| `turnover_delta_litter`, `turnover_delta_soil` | External forcing | owned shape, `kg C m-2 step-1` | Difference around `updatePoolsTurnover`; SOM delta is explicitly zero in v2.0 |
| `mortality_delta_litter`, `mortality_delta_soil` | External forcing | same | Difference around `updatePoolsMortality`; SOM delta is explicitly zero |
| `disturbance_delta_litter`, `disturbance_delta_soil` | External forcing | same | Difference around `disturbance`; SOM delta is explicitly zero |

Capture differences rather than reconstructing transfers from vegetation
diagnostics. This preserves Fortran clamping, redistribution, root-layer
placement, fire loss, and enabled/disabled branches without bringing the
external process implementation into Stage B.

`post_pool_update_*`, `pre_turbation_*`, and final Fortran `post_*` arrays are
reference state in serialized oracle data. They are compared with the Julia
state at the corresponding phase and are never read as trajectory forcing.

## Masks and branch semantics

- Mineral Stage B requires `peatlandType == 'None'`; peat and Sphagnum paths
  are C scope.
- A PFT respiration flux is computed only if `fcancmx > 0`; a bare respiration
  flux is computed only if `fg > zero`, with `zero = 1e-20`.
- For bedrock (`isand == -3`) and ice/glacier (`isand == -4`), the respiration
  moisture scalars are set to 0.2. Respiration is not independently masked to
  zero there, so state in such a layer still matters and must not be dropped.
- `updatePoolsHetResp` loops over every PFT, bare, product, and layer. Inactive
  entries receive zero initialized respiration, then the resulting pool is
  clamped nonnegative.
- Turbation operates only on the contiguous permeable prefix before the first
  `-3`/`-4`, only on mineral tiles, and only for `j = 1:iccp1` with positive
  total SOM.
- Cryoturbation is selected when `actlyr <= 1 m`; bioturbation is selected
  otherwise. This is a branch selection, not two summed fluxes.

## Sampling and time semantics

`accumulateForCTEM` samples soil temperature and liquid/ice water at each
short CLASS physics step. `dayEndCTEMPreparation` divides their sums by
`nday`, then the daily `ctem`/`ctemDriver` call executes. Therefore `tbar`,
`thliq`, and `thice` at this boundary are arithmetic daily means over the
preceding physics interval, not instantaneous end-of-day state.

Each trajectory record must carry explicit `time_start`, `time_end`, and
`deltat_days = 1`. The external transfer phases belong to the daily transition
ending at `time_end`; their order is defined by the call sequence, not by
assigning different sub-daily timestamps. The resulting post-state is valid
after turbation at `time_end` and is the next record's pre-step state.
