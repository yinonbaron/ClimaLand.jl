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
organic-plus-mineral nitrogen changes.

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

The remaining exact-reproduction blocker is GNU Fortran 8.1.0, which is named
by the legacy Makefile but unavailable on this macOS ARM host. The archive does
not record its compiler. The runnable reconstruction uses source
`82c57f8aa1179865d9752b617493ef06f45c3266` with GNU Fortran 16.1.0.

The counterfactual restart, terminal spin checkpoint, per-pool comparison, and
full annual global time series remain outside this repository under
`../casa_cn_reconstruction_issue24/passive_cn_counterfactual`.
