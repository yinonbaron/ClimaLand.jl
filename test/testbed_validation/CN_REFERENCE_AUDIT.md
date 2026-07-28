# Carbon-nitrogen reference audit

This file pins the implementation boundary for Milestone 5 of the testbed
port. It records the exact source and archive targets before carbon-nitrogen
(CN) equations are added to the ClimaLand models.

## Pinned references

The source tree is `wwieder/biogeochem_testbed` commit
`27ae1a0b673411642cd780ecad66d1c8f84e6a58`. The following hashes are for
tracked source files at that commit; the local source checkout contains an
unrelated modified analysis notebook and an untracked temporary directory.

| File | MD5 | SHA-256 |
|---|---|---|
| `SOURCE_CODE/casa_cnp.f90` | `3481534ea17723d053b5666e3b9bd373` | `26e7f60b7dc3c3ab6094559c5cad0ad1a4aeb0de94b74f7bf8bd91501856a399` |
| `SOURCE_CODE/casa_nlim.f90` | `fe66137f3b47656cb8455395c89b2e62` | `157bf468e6c3ef90fcf34151a4cf33e91e1380e62701b2917987debef207362d` |
| `SOURCE_CODE/mimics_cycle_CN.f90` | `379af662796d8d5697a249602f6e5274` | `4042ee33bf355265490a1cc8e99b43a5aa05904d258ab6a4862acd2248dd4f20` |
| `SOURCE_CODE/mimics_variable_CN.f90` | `ceae1db57c96750ff4f86e7cf8b68643` | `f1e43b1068754c8ce4e23c2ab2cd69427c1ea6001bf148dbf09d33546e2d7725` |
| `SOURCE_CODE/mimics_inout_CN.f90` | `848e120fad8e14c75d8e965f5f8fd2b6` | `7399a09871834b94776fa64795cb4988ca31fd5e7975156e7cb70da673b18bf0` |
| `SOURCE_CODE/casaoffline_driver_clm_CN.f90` | `e8671cdb94e71315f58ad9cfc939a681` | `087699c624b29395ea7699e035f80c2c5f6c464261f58d039d4320fffc8dc359` |

The candidate historical controls and output archives are already recorded in
`experiments.toml`:

| Model | Control | Control MD5 | Output archive | Archive MD5 |
|---|---|---|---|---|
| CASA CN | `GRID_CN/CASACNP_mod5_GSWP3_JAMES/fcasacnp_clm_HIST_1901_2014_STEP_3of4.lst` | `6ffad3aff680ecbe45e2c9558caf4363` | `CASACNP_mod5_GSWP3_exudate0_cwdN.tar.gz` | `ffbf1ec50070d9d497d0521fb17e85e3` |
| MIMICS CN | `GRID_CN/MIMICS_mod5_GSWP3_KO4_push/fcasacnp_clm_HIST_1901_2014_STEP_3of4.lst` | `29e746c0b19aa19373f6215737016897` | `MIMICS_mod5_GSWP3_KO4_exudate0_cwdN.tar.gz` | `255b6f31ee01e0269f803144c83122e5` |

Both CN archives and the common driver archive are now present locally and
match the MD5 values above. Exact single-cell fixtures were extracted for
inactive cell 51 and productive cell 11060 under `fixtures/casa_cn_*` and
`fixtures/mimics_cn_*`; their manifests retain archive provenance and exact
round-trip hashes. Full historical
initialization remains unavailable because the CASA CN restart and the MIMICS
CN restart are absent from the repository and published archives. As in the
carbon-only milestone, archived daily transitions can still provide
input-output tests without claiming restart reconstruction.

The Fortran NetCDF reader stages `xcgpp`, `ndep`, `xtairk`, `xtsoil`,
`xmoist`, and `xfrznmoist` through explicit `real(4)` arrays before assigning
them to double-precision driver storage. Native trajectory comparisons must
therefore round each raw forcing value to `Float32` before widening it,
converting units, or computing root-weighted drivers. Skipping that handoff
creates a first-day GPP difference that can eventually flip CASA's
discontinuous LAI allocation or turnover branches.
The rounded GPP value is also the value reported by the legacy carbon map and
passed to its nitrogen-supply calculation; mixing the rounded process input
with an unrounded diagnostic breaks the carbon budget and changes the
nitrogen-limitation arithmetic.

## Prognostic ownership

CN mode adds the following surface-integrated stocks in kg N m⁻²:

- CASA plant: leaf, wood, and fine-root nitrogen;
- CASA litter: metabolic, structural, and coarse-woody-debris nitrogen;
- CASA soil: microbial, slow, and passive organic nitrogen;
- CASA soil: one mineral-N stock owned by the selected soil component;
- MIMICS: metabolic and structural litter N, r- and K-selected microbial N,
  available, chemically protected, and physically protected SOM N.

MIMICS `DIN` is not a second independent ecosystem mineral-N stock. At the
start of its 24-hour map, the Fortran code makes a configured fraction of the
CASA mineral-N stock available as MIMICS `DIN`. The end-minus-start DIN change
is converted back into the CASA mineral-N tendency, together with deposition,
fixation, gaseous loss, and plant uptake. The Julia port must retain a single
mineral-N owner and treat the MIMICS DIN value as working state inside the
ordered daily map.

## CASA CN daily order

For `icycle = 2` and the CASA soil model, `biogeochem` executes:

1. plant turnover/allocation coefficients (`casa_coeffplant`);
2. nutrient limitation and demand (`casa_xnp`);
3. environmental soil rates and transfer coefficients;
4. the mineral-N linear limitation ramp (`casa_xkN2`);
5. multiplication of CASA litter decomposition rates by that limitation;
6. plant mineral-N uptake (`casa_nuptake`);
7. plant C/N deltas (`casa_delplant`);
8. litter, soil-organic, and mineral-N deltas (`casa_delsoil`);
9. simultaneous pool application (`casa_cnpcycle`).

`casa_xkN2` also diagnoses new-soil-pool N:C ratios from mineral N and removes
the limitation when fine litter plus CWD exceeds the configured maximum. This
branch and its exact comparison order are part of parity.

The CASA soil point kernels and compile-time `CarbonNitrogen` state are now
implemented. Across the productive fixture's first year, 364 transitions
validate the three soil-organic N pools, mineral N, gross litter and soil
mineralization, immobilization, net mineralization, gaseous loss, and leaching.
The native SI model uses an explicit 0.002 kg N m⁻² loss threshold; leaving
the Fortran literal `2.0` unconverted suppresses both loss terms and is covered
by the native Forward Euler replay test.

The archived `nLitInptStruc` variable is not a valid CASA oracle. In
`casa_delsoil`, local `nwd2str` is added to this diagnostic without being
initialized. Metabolic litter N input agrees with reconstructed transitions;
structural and CWD N boundary inputs are recovered from consecutive archived
litter states for the replay test. Soil and mineral-N comparisons remain
independent of that reconstruction.

## MIMICS CN daily order

For `icycle = 2` and MIMICS, `biogeochem` executes:

1. MIMICS-compatible plant coefficients;
2. CASA plant nutrient demand and the same mineral-N limitation diagnostic;
3. plant mineral-N uptake;
4. plant, litter-quality, CWD C, and CWD N deltas
   (`mimics_delplant_CN`);
5. the 24 ordered hourly reverse-Michaelis--Menten CN updates
   (`mimics_soil_reverseMM_CN`);
6. application of CASA plant, CWD, and mineral-N deltas
   (`mimics_cncycle`);
7. carbon and nitrogen output accumulation.

`mimics_readbiome` initializes all three plant-organ lignin:N ratios from the
initial plant C:N table. In CN mode, `mimics_coeffplant` later replaces only
the leaf and fine-root entries with ratios calculated from current pools and
the maximum C:N limits; wood remains at its initialized value. Consequently,
the fixed wood ratio must not be reconstructed from the separate minimum-N:C
table, whose rounded decimal values need not be exact reciprocals of the
initial C:N entries.

Acceptance comparisons use Julia's complete prespin-to-history checkpoint
chain. A separate diagnostic can load the paired Fortran predecessor restart
before a stage to hold initial conditions fixed and test only that stage.

CASA's LAI gates are discontinuous. Fortran computes LAI from grams and
`m² g⁻¹`, while the original Julia path used kilograms and `m² kg⁻¹`. At an
exact maximum-LAI state, floating-point operation order can make Fortran retain
leaf allocation while Julia suppresses it. `LegacyDaily` now preserves the
Fortran gram/day calculation order for carbon, nitrogen, and LAI before
converting the resulting map to SI tendencies; `ContinuousRate` keeps SI
arithmetic.

That conversion cannot make the two long integrations bitwise identical:
Fortran stores the evolving pools in grams and applies the daily map directly,
whereas ClimaTimeSteppers stores kilograms and reconstructs the daily update
from a per-second tendency. A high-precision trace for selected cell 1715
first differs by one binary rounding unit in root N on day one. Smooth
differences remain below `4.1e-5` g through day 102,748, but on day 102,749
Fortran leaf C is `2.99e-5` g above the minimum-LAI threshold while Julia is
`7.81e-6` g below it. One different senescence decision then produces a
`0.593` g leaf-C separation. A tested LAI deadband only postponed this event
and created other incorrect branches, so no deadband is included. Selected
validation therefore reports the measured absolute and relative errors rather
than claiming bitwise long-spin identity.

The complete 37-cell Julia checkpoint chain confirms that this is a material
acceptance failure rather than a tolerance-labeling issue. At `atol = 0.005`
g m⁻² and `rtol = 0.001`, the first long-spin boundary fails for one labile-C
and one mineral-N value, and both fresh-Fortran historical daily windows fail.
The largest retained daily leaf-C difference is `0.889` g m⁻². Carbon and
nitrogen conservation still pass. No global run is authorized by this result.

The legacy DIN partition is undefined when both microbial C pools are zero:
it evaluates `MICr / (MICr + MICk)` and `MICk / (MICr + MICk)`. Fixed-width
restart output can round both sufficiently small pools to zero, causing a
`0 / 0` on the first continuation step. The Julia map defines microbial DIN
uptake as zero in this degenerate state. Its nonzero-biomass path is unchanged,
so archived daily-transition parity is retained.

The MIMICS branch deliberately does not multiply litter decomposition by the
CASA `xkNlimiting` scalar. Inside every hourly update it:

- computes C and N substrate losses from current pool C:N ratios;
- partitions available DIN between microbial groups by relative biomass;
- applies C growth efficiency and N use efficiency;
- enforces microbial C:N through overflow respiration and N spill;
- updates all seven organic C pools, seven organic N pools, and working DIN;
- recomputes the next hour from the updated state.

## Coarse-woody-debris nitrogen contract

The target archives include the `cwdN` configuration. In
`mimics_delplant_CN`, wood turnover adds N to the CASA CWD N pool. CWD N loss
is

```text
nwd2str = klitter_cwd * nlitter_cwd
```

and is included in MIMICS structural-litter N input. The source comments mark
this equation as scientifically uncertain, but it is the pinned archive
behavior and must be reproduced before considering alternatives.

## Conservation gates

Point and gridded tests must separately check:

```text
plant N + organic litter/soil N + mineral N
  = initial N + deposition + fixation
    - leaching - gaseous loss
```

Plant uptake and microbial immobilization are internal transfers and must
cancel exactly between component tendencies. MIMICS working DIN must not be
counted twice. CWD-to-structural N is also internal.

## Next executable steps

Completed: CASA plant-N demand, uptake, retranslocation, litterfall, and
plant-N states reproduce the productive companion fixture. CASA plant plus
CASA soil and CASA plant plus MIMICS both use one mineral-N owner and pass
integrated conservation tests. The MIMICS 24-hour ordered map, working DIN,
CWD-N, overflow, mineralization diagnostics, and standalone/integrated native
models are implemented; 364 productive-cell transitions reproduce the CN
archive.

Completed executable gates include CN diagnostics, full-state checkpoint
round trips, uniform and heterogeneous native spatial fields, and archive-grid
transition reports for both soil models. Each grid report covers 6,916 active
first-year transitions across 19 representative productive cells and records
one additional inactive driver-mask boundary cell. CASA-CN pool relative
errors are below `2.7e-7`; MIMICS-CN C/N pool relative errors are below
`1.2e-7`, with DIN and respiration absolute errors below `6.2e-10` kg m^-2.

The native integrated model now supplies root-weighted `EnergyHydrology`
temperature, volumetric liquid water, liquid saturation, and frozen saturation
without changing the pinned legacy daily parity maps. Integrated component
diagnostics and heterogeneous surface rooting depths now pass on a vertically
resolved `HybridBox`. Standalone and integrated full-state checkpoint round
trips pass. The integrated fallback preserves every prognostic field on
equivalent `ColumnGrid` domains and safely bypasses the `HybridBox` `LatPoint`
reader failure. Remaining native gates are CPU/GPU performance validation and
the repository CUDA job on a CUDA host.
