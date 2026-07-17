# CASA-CN archive reconstruction

`casa_cn_reconstruction.jl` implements issue 24 as one resumable, full-grid
Fortran workflow from reconstructed prespin inputs through the 1901--2014
history:

1. 100 repeats of the 1901 prespin forcing with the high-confidence
   boreal-N-fix CASA candidate and KO6/FI30 MIMICS parser candidate.
2. 499 repeats of 1901--1920 with the accelerated CASA table.
3. Passive-carbon restoration by a factor of 10, followed by 499 repeats of
   1901--1920 with the normal CASA table.
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
totals at every boundary. Its accelerated-spin transformation multiplies only
`casapool%csoil(PASS)` by 10; it verifies that
`casapool%nsoil(PASS)` and every unaffected restart column are byte-for-byte
unchanged. Both long spins report the documented carbon convergence metrics
and the corresponding organic-plus-mineral nitrogen changes.

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

The full-grid search exhausted the evidence-backed matrix without an exact
match. The best and only runnable case was `archive_predecessor` at source
`82c57f8aa1179865d9752b617493ef06f45c3266`, built with GNU Fortran 16.1.0.
It produced 284,242,354 exact mismatches across the annual history and retained
daily windows. The remaining source-compiler candidate is GNU Fortran 8.1.0,
which is named by the legacy Makefile but unavailable on this macOS ARM host;
the archive does not record its compiler.

Passive-carbon restoration, byte preservation of passive nitrogen and all
unaffected restart columns, and zero root exudation for all 18 PFTs verified.
Normal-spin carbon passed all three documented convergence checks. Accelerated
spin did not: its final-cycle global carbon change was 0.0146908 Pg (threshold
0.01 Pg), and 96.106% of active points changed by less than 1 g m-2 (threshold
98%); 98.616% changed by less than 0.1%, which passed. The corresponding final
cycle nitrogen changes were 0.000978709 Pg for accelerated spin and 0.00396726
Pg for normal spin.

| Boundary | Restart SHA-256 | Carbon (Pg) | Nitrogen (Pg) |
|---|---|---:|---:|
| Prespin | `8e2d425d658ceaee81d717468eef99782bc8cdc9b926a1f57550ab14a887ab78` | 1.22721649 | 0.06148815 |
| Accelerated spin | `1aeb30c064e59a80ea486a3f696ebca86ff3994e64e316e449aa2d32afda2275` | 1.02662923 | 0.04425553 |
| Normal spin | `dce3db0ada7cf464b6fbd638cf6044ede09be17a9d8cf7670181d10eaf9cbf45` | 1.23262904 | 0.05453322 |
| Historical | `625671cfb275b6605b962983bc0d7e4b4159246fbe0c4db5cb10ea0ad5818b65` | 1.26769213 | 0.05557501 |

Annual exact-mismatch counts were 1,457,236 for plant states, 3,168,240 for
organic pools, 2,211,418 for mineral nitrogen, 1,936,159 for major fluxes, and
589,888 for the overlapping CWD-nitrogen audit group. Every retained daily
year differed; per-year counts ranged from 27,350,424 (2014) to 27,764,170
(1905). No comparison tolerance was introduced.

The external search report SHA-256 is
`cb7d7266b8f9748aec42aede0f52fef62a86867dcb27555a65cb19c1098dccba`;
the reconstruction report SHA-256 is
`d51d9c830c728251c3495d25be98ba4931951d58ff8772c0ee25e9c3df366c59`.
Large run outputs remain outside this repository under
`../casa_cn_reconstruction_issue24`.
