# Issue 31 CASA–MIMICS-CN implementation status

**Status date:** 2026-07-29

**Comparison target:** fresh Fortran runs only

**Validation scope:** 800 uniformly sampled grid cells

## Executive summary

The Julia CASA–MIMICS-CN implementation now follows the ordered daily
calculations of the Fortran model closely enough to complete the full prespin,
two long-spin stages, and 1901–2014 historical simulation on 800 randomly
selected cells. Carbon and nitrogen budgets close for every stage.

The production changes are committed in:

- `4dfbf81a5` — native CASA–MIMICS-CN reconstruction and compatibility kernels;
- `780336b08` — leaf P:N operation order and signed mineral-N leaching.

The fresh Fortran prespin boundary matches on every compared value. Small
differences accumulate during the two 499-cycle spins. Most remain below the
comparison criterion, but a few cells cross CASA's discontinuous minimum-LAI
gate on different days. This shifts a leaf-turnover pulse by one or two days
and can create a daily leaf-C difference near 1 g C m⁻² even when the smooth
fluxes are nearly identical.

This remaining behavior is accepted for the current work. Exact long-spin
parity would require a discrete legacy state-transition path that keeps the
Fortran-unit state authoritative instead of converting the daily map through
SI tendencies.

## Parameters and sample

The issue-43 MIMICS parameter file used in every stage is:

`pftlookup_LIDET-MIM-REV_CN_desorb2xKO4_micCN_FI30.csv`

Its SHA-256 is
`52d12f43e484caec0580198f72fc85f814ccc9c2e9799165859076640c84bb3b`.

The normal spin and historical CASA parameter file is:

`pftlookup_igbp_updated4_exud0.csv`

Its SHA-256 is
`f27d11c1f936167c61d3c84241845937f6d29644b0b7861d7bd9a412d511cb13`.
The derived `pftlookup_igbp_updated4_borealNfix.candidate.csv` table is used
only for prespin.

The 800 cells were sampled uniformly without replacement from the 4,263-cell
grid with `Random.MersenneTwister` seed `31432026`, then restored to the
original grid order. Selection files and the complete Julia report are in
`../native_mimics_cn_random800_20260728`.

## Production-source changes

### CASA vegetation

[`src/standalone/Vegetation/casa.jl`](../../src/standalone/Vegetation/casa.jl)
now separates the native continuous-rate formulation from a `LegacyDaily`
compatibility path. The legacy path:

- evaluates carbon and nitrogen calculations in grams and days before
  returning SI tendencies;
- reproduces the Fortran `real(4)` driver handoff;
- evaluates LAI from SLA in m² g⁻¹ and leaf C in g m⁻²;
- preserves the ordered allocation, turnover, respiration, labile-C, and
  nitrogen-supply calculations;
- implements the Fortran uptake floors and denominator offsets;
- reconstructs leaf P:N in the `casa_pdummy`/`casa_rplant` operation order;
- retains the fixed initial wood lignin:N ratio used by MIMICS.

The ordinary `ContinuousRate` formulation remains timestep-independent and is
not changed to use the compatibility arithmetic.

### MIMICS soil

[`src/standalone/Soil/Biogeochemistry/mimics.jl`](../../src/standalone/Soil/Biogeochemistry/mimics.jl)
now preserves the legacy unit-conversion and hourly update order for the
coupled C-N map. It also:

- exposes the full carbon and nitrogen exchange diagnostics;
- handles zero microbial biomass without an undefined DIN partition;
- applies the ordered bounded pool updates;
- uses the signed mineral-N pool in legacy leaching, matching Fortran;
- returns the end-of-map working DIN separately from the ecosystem mineral-N
  stock.

### Integrated coupling

[`src/integrated/casa_biogeochemistry.jl`](../../src/integrated/casa_biogeochemistry.jl)
no longer applies the CASA-soil nitrogen-limitation override to the MIMICS
coupling path. MIMICS owns the ecosystem mineral-N stock and receives the
complete CASA litter and CWD carbon/nitrogen transfers.

An exchange-flux experiment prescribed the complete Fortran CASA-to-MIMICS
flux vector to Julia. The resulting Julia MIMICS pools matched Fortran to
`4.44e-16` kg m⁻², isolating the remaining long-run separation to the
vegetation trajectory and discrete coupling decisions rather than the soil
state update itself.

## Fresh Fortran comparison

The boundary criterion is
`0.005 + 0.001 × abs(reference)` in each reference variable's stored
gram-scale units.

| Boundary | Finite values outside criterion | Largest finite absolute difference | Nonfinite reference mismatch cells |
|---|---:|---:|---:|
| Prespin | 0 | `3.2449e-6` | 0 |
| Spin | 1 | `0.155674` g leaf C m⁻² | 0 |
| Spin continuation | 13 | `0.654036` g leaf C m⁻² | 9 |
| Historical | 3 | `0.582673` g leaf C m⁻² | 10 |

The largest spin-continuation difference is at cell 9764. The largest first
spin leaf difference is `0.155674` g C m⁻² at cell 9765, although that leaf
value remains within the relative component of the comparison criterion. The
single first-spin failure is labile C.

The nonfinite mismatches are PFT-16 cells for which the fresh Fortran run
produces NaNs after the long spin. They are recorded separately from finite
Julia–Fortran differences and should not be used to infer a finite error
magnitude.

The 800-cell fresh Fortran run retained stage-final CSV files but not daily or
annual NetCDF streams. Therefore this run establishes fresh-Fortran boundary
behavior and budget closure, not daily fresh-Fortran parity. Archived output
comparisons are outside the acceptance target described here.

## Remaining numerical difficulty

For PFT 1, the minimum-LAI turnover threshold is

`3 / 0.00718 = 417.82729805 g C m⁻²`.

Fortran stores CASA state in grams and directly applies its daily delta. Julia
computes the same ordered gram/day map, converts it to kg m⁻² s⁻¹, and lets
Forward Euler reconstruct the kg-valued state. The conversion can change a
daily flux by one floating-point unit. After millions of repeated forcing
days, that small difference can place the models on opposite sides of the
hard LAI comparison.

When this happens, one model suppresses leaf turnover while the other sends
the corresponding carbon and nitrogen to MIMICS litter. The leaf-pool error
and litter-input error balance, showing that this is a shifted turnover event
rather than a conservation failure.

The appropriate exact-parity solution is a dedicated `LegacyDaily` discrete
transition:

1. keep the legacy-unit C/N state authoritative;
2. apply each daily CASA and MIMICS next state directly in Fortran order;
3. synchronize SI fields only after the transition;
4. checkpoint and restore the authoritative state without routing the next
   transition through the SI mirror.

No LAI deadband is recommended. A deadband moves the first branch difference
and changes valid decisions in other cells instead of reproducing the Fortran
state transition.

## Current conclusion

The implemented vegetation, soil, and coupling corrections are retained. They
provide close fresh-Fortran agreement, complete budget closure, and a
well-isolated explanation for the remaining finite long-spin differences.
Exact bitwise reproduction across millions of daily steps remains future work;
it is not required for the present 800-cell comparison.
