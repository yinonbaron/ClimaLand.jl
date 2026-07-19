# CASA-CN archive reconstruction

`casa_cn_reconstruction.jl` implements issue 24 as one resumable, full-grid
Fortran workflow from reconstructed prespin inputs through the 1901--2014
history:

1. 100 repeats of the 1901 prespin forcing with the high-confidence
   boreal-N-fix CASA candidate and KO6/FI30 MIMICS parser candidate.
2. 499 repeats of 1901--1920 with the accelerated CASA table.
3. Passive-carbon and passive-nitrogen restoration by a factor of 10, followed
   by 499 repeats of 1901--1920 with the normal CASA table.
4. The complete 1901--2014 historical forcing.

The MIMICS candidate is staged because the legacy executable parses that
table in CASA mode even though CASA owns the active soil calculation. The
prespin candidates remain explicitly labelled as derived candidates and are
hash-linked to `candidate_reconstruction.toml`.

The bounded source matrix selects
`82c57f8aa1179865d9752b617493ef06f45c3266`, the latest public source commit
before the archive's 2022-05-10 creation timestamp. GNU Fortran 8.1.0 is
recorded by the source Makefile but is unavailable on the macOS ARM host; the
runnable attempt records the installed compiler and build flags separately.

Run the bounded search from the ClimaLand checkout:

```sh
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/casa_cn_reconstruction.jl search \
  ../biogeochem_testbed .. ../casa_cn_reconstruction_issue24
```

The runner records carbon and nitrogen restart hashes and area-weighted pool
totals at every boundary. Its accelerated-spin transformation multiplies
`casapool%csoil(PASS)` and `casapool%nsoil(PASS)` by 10, while verifying that
every unaffected restart column is byte-for-byte unchanged. Both long spins
report the documented carbon convergence metrics and the corresponding
organic-plus-mineral nitrogen changes. The normal spin writes only its initial,
9,960-year, and terminal 9,980-year checkpoints; the last two preserve the
documented convergence calculation without retaining unused intermediate
NetCDF output.

Exact scientific comparisons cover the annual 1901--2014 history and the
published 1901--1905 and 2010--2014 daily windows. Named report groups require
plant C/N states, organic C/N pools, CWD nitrogen, mineral-N stock and losses,
litter inputs, productivity, and respiration. Root exudation is zero in the
published setup and is audited directly for all 18 PFTs in both normal and
accelerated parameter tables because the legacy NetCDF schema has no separate
exudation variable.

To keep the full run within bounded local storage, each historical daily year
is reduced and compared with the verified annual archive as soon as the next
year begins. The per-year comparison record is written atomically and included
in stage output hashes; daily NetCDF files are retained only for the two
published five-year windows. Resume therefore reuses a historical stage only
when all 114 annual comparison fragments, ten retained daily files, controls,
inputs, executable, and restart outputs still match their recorded hashes.

If execution completed but report generation was interrupted, regenerate the
report without rerunning the model:

```sh
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/casa_cn_reconstruction.jl report-case \
  .. ../casa_cn_reconstruction_issue24 archive_predecessor
```

## Result

The initial full-grid reconstruction followed the retained instruction to
multiply passive SOC by 10 while leaving passive nitrogen unchanged. That run
missed the archive's 1901 passive-soil nitrogen stock by 17.06948% and ended
the normal spin with a passive-pool C:N ratio of 19.68326. The archive ratio is
16.34456, localizing the discrepancy to the undocumented treatment of passive
nitrogen at the accelerated-spin restart boundary.

A controlled rerun multiplied both passive carbon and passive nitrogen by 10.
The executable, source revision, forcing, scientific controls, parameter
tables, and every other restart field were unchanged. The 9,980-year normal
spin and complete 1901--2014 history then reproduced every annual global pool
stock to within 0.028% of the archive. The largest discrepancy was 0.0274406%
for passive soil carbon in 1901.

| Global annual-mean stock | Carbon-only gap (1901) | C+N gap (1901) | C+N gap (2014) |
|---|---:|---:|---:|
| Passive soil nitrogen | -17.06948% | +0.02462% | +0.02449% |
| Total modeled nitrogen | -4.42701% | +0.00682% | +0.00660% |
| Total modeled carbon | -0.24175% | +0.00576% | +0.00546% |

The corrected terminal passive-pool C:N ratio is 16.34502. This establishes
that the archived workflow effectively restored passive nitrogen together with
passive carbon, despite documenting only passive-SOC restoration. Comparison
tolerances remain exactly zero; the result is a scientific reconstruction,
not a claim of bitwise identity.

The canonical workflow rerun exercised the exact annual comparison and both
retained daily windows. It reduced the report failure count from 284,242,354
for carbon-only restoration to 132,978,805 for C+N restoration. The corrected
count comprises 4,169,929 annual value mismatches, 128,808,875 daily value
mismatches, and the unchanged accelerated-spin convergence failure. There are
no metadata mismatches and no tolerance was introduced.

| Exact annual comparison group | Failure count |
|---|---:|
| Plant states | 670,459 |
| Organic pools | 1,453,341 |
| Mineral nitrogen | 1,008,602 |
| Major fluxes | 1,037,527 |
| CWD nitrogen audit | 460,534 |

The CWD-nitrogen group overlaps the organic-pool and major-flux groups and is
therefore not added again when calculating the unique total. All ten retained
daily years were also compared: 1901--1905 and 2010--2014.

The corrected normal spin passes all three documented carbon convergence
checks: its final-cycle global change is 0.000525011 Pg, 99.226% of active
cells change by less than 1 g C m-2, and 98.733% change by less than 0.1%.
Its corresponding nitrogen change is 0.0000345591 Pg. The accelerated spin is
unchanged and still misses two carbon convergence thresholds.

| Boundary | Restart SHA-256 | Carbon (Pg) | Nitrogen (Pg) |
|---|---|---:|---:|
| Prespin | `8e2d425d658ceaee81d717468eef99782bc8cdc9b926a1f57550ab14a887ab78` | 1.22721649 | 0.06148815 |
| Accelerated spin | `1aeb30c064e59a80ea486a3f696ebca86ff3994e64e316e449aa2d32afda2275` | 1.02662923 | 0.04425553 |
| Normal spin | `0dff9a0c37accff0580a3768ba65f5e3b7aa651667fee27aa9508e634b5197cc` | 1.23567468 | 0.05706307 |
| Historical | `df49c09bc4f351db42549557c61e6f8a44478948eef31e8462930b3eb0896d5b` | 1.27068924 | 0.05807925 |

The remaining exact-reproduction blocker is GNU Fortran 8.1.0, which is named
by the legacy Makefile but unavailable on this macOS ARM host. The archive does
not record its compiler. The runnable reconstruction uses source
`82c57f8aa1179865d9752b617493ef06f45c3266` with GNU Fortran 16.1.0.

The reconstruction report SHA-256 is
`3139f93b7e43cd244f04f467dff774bf4c406260b37946a39d245dc847e73408`;
the search report SHA-256 is
`e40f7b077fe36887c30546a57180bcce0609f867a16487321ce877f238f81d3b`.

The counterfactual restart, terminal spin checkpoint, per-pool comparison, and
full annual global time series remain outside this repository under
`../casa_cn_reconstruction_issue24/passive_cn_counterfactual`.
