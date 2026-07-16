# Native CASA-C reconstruction

`native_casa_c_reconstruction.jl` implements issue 28 as a four-stage native
ClimaLand run:

1. 100 repeats of the 1901 prespin forcing.
2. 499 repeats of 1901–1920 with the accelerated parameter table.
3. Passive-soil carbon restoration by a factor of 10, followed by 499 repeats
   of 1901–1920 with the normal parameter table.
4. The 1901–2014 historical forcing.

The 4,263 CSV rows are represented as independent surface points in their
original order. This preserves a direct row-by-row mapping between native
checkpoints and each fresh-Fortran `casa_final.csv`. Meteorological data are
read on demand from the original gridded NetCDF files; six soil layers are
root-weighted with the pinned Fortran layer thicknesses and root profile.
The carbon-only diagnostic plant N and P bookkeeping also preserves the
Fortran update order: plant P is derived from the preceding day's N before N
is refreshed from the current carbon pools. Each standalone stage resets
plant P to the parameter-table initial value, matching the Fortran
initialization that reads only carbon pools from the preceding checkpoint.
The exported structural-litter diagnostic includes the CWD-to-soil transfer
reported by the Fortran driver; this is a reporting convention and does not
add a second transfer to the native carbon equations.

Run from the repository root:

```sh
julia --startup-file=no --project=test \
  test/testbed_validation/native_casa_c_reconstruction.jl \
  ../biogeochem_testbed \
  ../INPUT_GSWP3_CLM5dev110_hist \
  ../casa_c_reconstruction_issue22/archive_predecessor \
  ../native_casa_c_reconstruction_issue28
```

The output contains a native checkpoint and workflow manifest for every
stage, the complete native historical state stream, and
`reconstruction_report.toml`. The report keeps three questions separate:

- checkpoint parity against the fresh Fortran run;
- annual and first/last-five-year daily parity against fresh Fortran;
- the same historical comparisons against the published archive products.

It also records the measured maximum absolute and relative errors for every
carbon stock and the six reported carbon flux/input variables (`cgpp`, `cnpp`,
`cresp`, `cLitInptMet`, `cLitInptStruc`, and `cpassInpt`), plus an
area-weighted carbon budget for each stage. The published archive comparison
is never used to relabel a fresh-Fortran implementation difference as a
provenance difference.

The measured prespin boundary tolerance is 0.005 g C m⁻² absolute plus 0.1%
relative. At that tolerance all ten carbon pools match across all 4,263
points; the largest measured prespin absolute difference is 0.0009178004
g C m⁻² in slow soil carbon.

The full-grid validation gives the following measured acceptance result at
the same mixed tolerance:

- Prespin, accelerated-spin, and normal-spin boundaries match all 42,630
  point-pool values. The historical boundary has six failures: one metabolic
  litter, one structural litter, three leaf, and one microbial-soil value.
  The largest failing historical boundary difference is 0.0153911 g C m⁻²
  in leaf carbon (0.5275% relative).
- All six annual fresh-Fortran flux diagnostics match. Across stocks and
  fluxes together, 113 of 7,289,730 annual values fail; they are confined to
  leaf, structural-litter, and microbial-soil carbon.
- The fresh-Fortran daily windows have 6 failures among 116,699,625 values
  for 1901–1905 and 1,249 among 116,699,625 for 2010–2014. The largest litter
  input differences occur as adjacent-day swaps around abrupt turnover
  transitions, while their annual means match.
- Every stage carbon budget closes at `budget_rtol = 5e-12`. The final
  historical replay has a relative residual of 1.25e-14.

Published-archive differences remain in their own report tables because the
archive adds postprocessing differences beyond the fresh Fortran run.

The tiny automated acceptance case exercises the same public `run_case`
contract with two points and two days per stage. The full command above is the
scientific acceptance run and intentionally remains separate from CI.
