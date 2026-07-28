# Native MIMICS-CN reconstruction

`native_mimics_cn_reconstruction.jl` implements issue 31 with the exact
MIMICS setup selected by issue 43. Every stage uses the unchanged
`pftlookup_LIDET-MIM-REV_CN_desorb2xKO4_micCN_FI30.csv` table (SHA-256
`52d12f43e484caec0580198f72fc85f814ccc9c2e9799165859076640c84bb3b`):

1. 100 repeats of 1901 using the derived boreal-N-fix CASA prespin table.
2. 499 repeats of the 1901--1920 forcing cycle.
3. A second 499-repeat 1901--1920 spin initialized from the paired checkpoint.
4. The complete 1901--2014 historical forcing.

The 4,263 cells remain in pinned CSV order. Each stage advances with native
ClimaTimeSteppers Forward Euler and writes a complete native ClimaLand
checkpoint. Acceptance uses the complete Julia checkpoint chain: each
post-prespin checkpoint is quantized to the paired Fortran restart format and
then passed to the next Julia stage. The optional
`reference_stage_initialization = true` mode instead loads each paired
fresh-Fortran predecessor restart; it is a diagnostic for isolating one-stage
errors and is not an acceptance run.

CASA-carried plant, CWD, and mineral-N pools in the reference restart use six
decimal places in grams (`f18.6`), while the fourteen MIMICS organic C/N pools
use ten decimal places in their native kg m⁻² representation (`f18.10`).
After reading the restart, Fortran `casa_init` resets the labile-C pool to zero;
the Julia restart loader does the same. MIMICS owns the single ecosystem
mineral-N stock. The historical stream also records the working DIN returned
by the ordered 24-hour MIMICS map.

The legacy NetCDF reader declares GPP, N deposition, air and soil temperature,
liquid moisture, and frozen moisture input arrays as `real(4)`. It then widens
those values into the double-precision model arrays. The native validation
workflow reproduces that handoff by converting each raw driver to `Float32`
and back to `Float64` before unit conversion, root-weighted aggregation, or
annual-NPP accumulation. This is compatibility behavior for comparison with
the Fortran trajectory; the ClimaLand state and process calculations remain
`Float64`. The legacy carbon map exposes this rounded GPP as its diagnostic and
uses it in the nitrogen-supply calculation, so the process, diagnostic, and
budget paths all consume the same value.

Before the global run, validate the same four stages against a fresh Fortran
run on the 37 stratified selected cells:

```sh
julia --startup-file=no --project=test \
  test/testbed_validation/selected_mimics_cn_validation.jl \
  ../biogeochem_testbed \
  ../mimics_cn_reconstruction_issue25/bundled_ko4_fi30 \
  ../mimics_cn_reconstruction_issue25/bundled_ko4_fi30/build/casaclm_mimics-cn_corpse \
  /tmp/mimics-cn-selected \
  /tmp/native-mimics-cn-selected
```

The selected run packs the noncontiguous global cells into a 37 by 1 Fortran
grid without changing forcing values, retains all fresh historical output, and
compares stage boundaries plus the annual and two daily windows. It deliberately
does not replace or loosen the separately measured global archive comparison.

CASA has discontinuous branches at the PFT LAI bounds: leaf turnover stops at
the minimum and leaf allocation stops at the maximum. The Fortran daily model
evaluates LAI as `SLA [m² g⁻¹] * leaf C [g m⁻²]`; the original Julia port
evaluated the algebraically equivalent SI expression
`SLA [m² kg⁻¹] * leaf C [kg m⁻²]`. Their different floating-point operation
orders can place a state on opposite sides of either comparison.

`LegacyDaily` therefore evaluates the complete CASA carbon and nitrogen map in
the legacy gram/day order, including LAI, before converting the result to SI
tendencies. `ContinuousRate` retains the native SI calculation. This corrects
the process-equation mismatch but does not make the two integrations bitwise
identical: Fortran retains gram-valued state and applies the daily map directly,
while ClimaTimeSteppers retains kilogram-valued state and reconstructs the
update from a per-second tendency.

A 20-cycle high-precision trace of selected cell 1715 found the first discrete
branch mismatch on day 102,749. Immediately beforehand, accumulated smooth
rounding was only `3.77e-5` g leaf C; Fortran was `2.99e-5` g above the
minimum-LAI threshold and Julia was `7.81e-6` g below it. The different
senescence decision created a `0.593` g leaf-C separation in one day. A
`1e-5` g LAI guard band postponed the first flip but produced thousands of
later incorrect branch decisions, so it was rejected and no LAI deadband is
used.

Initializing all 37 Julia cells from the exact Fortran spin-continuation
restart remains a useful diagnostic: every 1901--1905 daily comparison passes
at `atol = 0.005` and `rtol = 0.001`, confirming the daily process equations
independently of the full chained acceptance test. The chained comparison
reports its measured errors explicitly; these tolerances are 0.1% relative,
not 10%.

The independently chained selected-cell run does not currently satisfy that
acceptance threshold. Prespin passes, but the first long-spin boundary has one
failing labile-C value and one failing mineral-N value. The continuation and
historical boundaries pass, but the 1901--2014 fresh-Fortran comparison still
fails: the annual comparison has seven leaf-N, two litter-metabolic-N, and one
leaf-C failures, and the retained daily windows contain branch-sensitive leaf,
litter-input, NPP, uptake, and DIN failures. The largest daily leaf-C
difference is `0.889` g m⁻². Carbon and nitrogen budgets both close. Therefore
this selected-cell result is recorded as a failed validation, and it must not
be used to authorize the global run.

Correct restart units also remain essential: applying the MIMICS `f18.10`
format after converting its pools to grams makes that handoff 1000 times too
precise. The Fortran reader's `real(4)` meteorological handoff is retained
because feeding wider values introduces a difference on the first prespin day.

The Fortran `casa_nuptake` routine also adds `1e-10 g N m-2 day-1` to
`Nminuptake` after summing the three plant-pool demands. That value is removed
from ecosystem mineral N through `Nupland`, but it is not allocated to a plant
pool. `LegacyDaily` preserves this active-land compatibility floor; inactive
ice/water points and `ContinuousRate` keep zero additional uptake. The
nitrogen budget reports the resulting legacy numerical sink in its adjustment
term instead of treating it as plant growth. Fortran includes the floor in the
denominator of `fracNalloc` and then reconstructs each pool uptake as
`Nminuptake * fracNalloc`; the Julia legacy path retains that arithmetic order
so long spin-ups do not accumulate a different rounding trajectory.

The maximum plant N:C guard in `casa_Nrequire` uses a separate `1e-10 g C
m-2` denominator offset. Plant pools use kg C m-2 in ClimaLand, so the native
kernel converts the offset to `1e-13 kg C m-2` before applying the guard. A
direct threshold regression protects this unit conversion independently of the
full selected-cell workflow. No N:C threshold deadband is used.

MIMICS-CN initializes the wood lignin:N ratio from the plant C:N table and
keeps that value fixed; `mimics_coeffplant` subsequently updates only leaf and
fine-root ratios. The plant minimum-N:C table is a separate input and its
decimal representation is not guaranteed to be the exact reciprocal of the
initial C:N value. The native parameter set therefore stores the fixed wood
lignin:N value explicitly. For selected PFT 7, this preserves the Fortran value
`150 * 0.4 = 60` instead of deriving `59.99999700000015` from the rounded
minimum N:C entry. Although the resulting first-day litter-quality difference
is only about `3.5e-9`, repeated spinup amplifies it. Leaf and fine-root
lignin:N remain dynamic and retain the Fortran maximum-C:N cap.

Run from the repository root after the issue-43 Fortran reference completes:

```sh
julia --startup-file=no --project=test \
  test/testbed_validation/native_mimics_cn_reconstruction.jl \
  ../biogeochem_testbed \
  ../INPUT_GSWP3_CLM5dev110_hist \
  ../mimics_cn_reconstruction_issue25/bundled_ko4_fi30 \
  ../native_mimics_cn_reconstruction_issue31
```

Boundary comparisons cover CASA plant C/N, CWD C/N, ecosystem mineral N, and
all seven MIMICS organic C/N pools. The Fortran restart CSV does not store
working DIN, so the report records that limitation explicitly and compares DIN
through annual output and the retained 1901--1905 and 2010--2014 daily
windows.

The historical comparison keeps fresh-Fortran and published-archive metrics
and tolerances in separate namespaces. It includes plant C/N, every organic
MIMICS pool, DIN, litter inputs, respiration, physical protection, microbial
overflow, mineralization, immobilization, plant uptake, leaching, and gaseous
loss. The fresh comparison accepts issue 43's storage-aware
`fresh_reference` directory (reduced annual files plus retained yearly daily
files), with the complete historical stage as a fallback. Stage carbon and
nitrogen budgets include the bounded-state adjustment needed to distinguish
numerical clamping from external inputs or losses.

The automated synthetic case exercises the same four-stage CTS and checkpoint
seam with two pinned fixture points. The full 4,263-cell scientific run remains
outside ordinary package tests.
