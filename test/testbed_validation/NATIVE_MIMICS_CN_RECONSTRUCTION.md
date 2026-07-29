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
tendencies. `ContinuousRate` retains the native SI calculation. The traced
cell-1715 separation near `417.827` g leaf C is the minimum-LAI turnover gate.
A tested `1e-5` g guard band merely moved the first flip and introduced
incorrect decisions in other cells, so no LAI deadband is used.

The remaining smooth drift originated earlier in CASA respiration.
At the end of every C or C-N timestep, Fortran `casa_pdummy` reconstructs leaf
P as `N / (N:P)`. On the next day, `casa_rplant` calculates the effective P:N
ratio as that reconstructed P divided by `N + 1e-10 g`. The earlier Julia
translation used the exact reciprocal table ratio and omitted both the
denominator offset and the ordered reconstruction division. The first visible
effect in a high-precision cell-1715 trace was an approximately `3e-14` g/day
NPP difference on day 49. Although locally negligible, repeated forcing
eventually put the two states on opposite sides of the minimum-LAI gate.

The legacy kernel now evaluates exactly
`(N / (N:P)) / (N + 1e-10 g)`. The operation order is intentional: replacing
the first division with multiplication by a precomputed reciprocal restores a
small long-run drift. At stage entry, the validation helper temporarily
supplies the restart P:N value as `P / N`; the legacy kernel then applies the
single Fortran denominator offset. Passing `P / (N + 1e-10 g)` into that
kernel would apply the offset twice. After the first timestep, the configured
N:P ratio is restored, matching the daily `casa_pdummy` reconstruction.

An independent exchange-flux experiment prescribed every full-precision
Fortran CASA-to-MIMICS carbon and nitrogen flux to the Julia soil module for
all 35 active selected cells. The Julia MIMICS states then matched Fortran to
`4.44e-16 kg m⁻²`. This established that the vegetation/coupling fluxes were
sufficient to reproduce the reference soil trajectory, but it did not prove
that every MIMICS boundary operation was already identical.

After correcting the leaf P:N arithmetic, the remaining long-spin residual was
traced to the mineral-N boundary between MIMICS and the next day's CASA
N-supply gate. On selected cell 9679, the mineral pool reached
`-1.62219647e-4` g N m⁻² on spin day 37,847. Fortran calculates leaching from
the signed pool, so its negative leaching flux moves the pool back toward zero.
The Julia translation used `max(0, Nmin)` and omitted that flux. The missing
`2.22219e-7` g N m⁻² leaching adjustment changed the following day's mineral
pool and moved the CASA N-supply fraction from `0.4068642584` to
`0.4068565852`. That in turn changed the labile-GPP fraction from
`0.3929997979` to `0.3930048820`, creating the first material labile-C
separation.

The legacy MIMICS-CN kernel now applies the leaching rate directly to signed
mineral N, matching the Fortran update. This behavior is intentionally limited
to reproducing the ordered legacy map; it should not be interpreted as a
physical export from a negative pool. After the correction, neither labile C
nor mineral N differed from Fortran by more than `1e-8` g m⁻² anywhere in a
15-cycle daily trace, and the complete 499-cycle selected-cell spin boundary
passed.

The complete chained selected-cell acceptance run also passes: prespin, spin,
spin continuation, and historical boundaries have zero failed values; the
fresh-Fortran annual and both retained daily-window comparisons pass; and both
elemental budgets close. Maximum boundary absolute errors range from
`4.91e-7` to `2.05e-6` in the reference variables' stored units. The largest
daily-window error is `9.61e-4`; the largest annual error is `0.0500` g C m⁻²
for physical SOM, a relative error of `5.22e-6`.

Initializing all 37 Julia cells from an exact Fortran stage restart remains a
useful diagnostic. With the ordered P:N calculation, the first-day cell-9679
NPP and plant-N uptake differ from the high-precision Fortran trace by only
`8.7e-19` and `1.4e-20` g m⁻² day⁻¹, respectively. The chained comparison
reports measured errors explicitly; its tolerances are 0.1% relative plus
`0.005` in the reference variable's stored units, not 10%.

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

Global historical output uses 30-day compressed NetCDF chunks to reduce disk
use without changing recorded values. If fresh yearly daily files were not
retained, `run_gridded_case(...; compare_fresh = false)` records that
comparison as unavailable while still requiring fresh Fortran stage-boundary
comparisons and the preserved annual/daily archive comparison.

The automated synthetic case exercises the same four-stage CTS and checkpoint
seam with two pinned fixture points. The full 4,263-cell scientific run remains
outside ordinary package tests.
