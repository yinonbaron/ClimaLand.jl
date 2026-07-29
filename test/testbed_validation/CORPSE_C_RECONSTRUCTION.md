# Global Fortran CORPSE-C workflow

`corpse_c_reconstruction.jl` runs the complete 4,263-cell, carbon-only CORPSE
workflow with the pinned legacy Fortran testbed. Large forcing files and run
outputs remain outside this repository.

The workflow derives its four controls from the committed `EXAMPLE_GRID`
CORPSE family:

1. 100 repetitions of the 1901 CASA prespin;
2. 499 repetitions of 1901--1920 for a 9,980-year CORPSE spin;
3. a second 9,980-year spin initialized from the first endpoint;
4. the 1901--2014 historical transient.

The derivation changes the old 4,299-cell CLM4.5/CRU-NCEP paths to the
available 4,263-cell CLM5/GSWP3 grid, soil, forcing, and zero-exudation CASA
parameters. It also supplies the NetCDF output-interval line required by the
pinned current reader. Every changed control value and every static input hash
is recorded.

Run the workflow from the ClimaLand checkout:

```sh
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/corpse_c_reconstruction.jl run \
  ../biogeochem_testbed .. ../corpse_c_reconstruction_issue44
```

Before starting the global stages, the command reruns the existing 37-cell
complete CORPSE workflow and requires its artifact to match the pinned oracle.
That fresh rerun reproduced the oracle artifact byte-for-byte (zero observed
absolute and relative error), which is the recorded basis for the `1e-12`
absolute and relative selected-slice tolerances. Historical CASA annual means
are the one precision-specific exception: the global workflow reduces retained
Float32 daily output, while the oracle uses the Fortran annual accumulator.
Those values use a relative tolerance of two Float32 unit roundoffs
(`2.384185791015625e-7`); the observed maximum was
`1.0495810544742013e-7`.
The global workflow is resumable: a completed stage is reused only when its
executable, materialized control, inputs, and outputs retain their recorded
hashes.

The legacy CORPSE writer ignores the requested checkpoint interval and emits a
NetCDF file for every simulated spin year. The runner hashes all 9,980 files
into a stage manifest as they close, retains years 1, 9,960, and 9,980, and
removes the intermediate files. This preserves evidence for every output
without requiring roughly 46 GB for the two spin stages.

The historical control retains its daily-output semantics without keeping all
114 years of full-grid daily files. As each year completes, the runner writes
one full-grid annual-mean CASA file and one full-grid annual-mean CORPSE file.
For 1901--1905 and 2010--2014, every daily variable is also copied losslessly
for the 37 pinned representative cells. The temporary full-grid daily file is
then removed.

`reconstruction_report.toml` records:

- source, build, control, input, output, restart, log, and stage hashes;
- exact CASA and CORPSE restart handoffs;
- active- and inactive-cell non-finite-state counts and active-carbon plus
  cumulative-respiration conservation checks at every boundary and handoff;
- global and per-cell CORPSE convergence between the two spin endpoints;
- selected-cell boundary and historical comparisons with the pinned fresh
  Fortran oracle;
- annual and retained-daily output completeness.

If execution finished but report generation was interrupted, regenerate it
without rerunning Fortran:

```sh
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/corpse_c_reconstruction.jl report \
  ../corpse_c_reconstruction_issue44
```

The local 4,299-cell 2000--2010 CORPSE mean remains informational. Its exact
CLM4.5/CRU-NCEP forcing and CASA restart are unavailable, so results from the
4,263-cell GSWP3 workflow must not be presented as reproducing it.

## Recorded global run

The issue-44 run completed all four stages with a `complete` scientific status.
The prespin, first spin, continuation spin, and historical stages took 176 s,
23,121 s, 21,077 s, and 1,223 s, respectively. Both spin manifests account for
all 9,980 annual CORPSE outputs.

Every restart handoff was exact, every boundary was finite, all 4,263 cells
closed the full-workflow carbon ledger, and every selected-oracle comparison
passed. The full-workflow net residual was `-7.46e-6 Pg C` and the total
absolute residual was `2.76e-4 Pg C`, against `810,132 Pg C` of accounted
source carbon over the repeated-spin ledger. The final active stock was
`1,288.85 Pg C`. Between the two spin endpoints, the global active-carbon
change was `8.79 Pg C`; 95.59% of cells changed by less than 1 g C m-2 and
95.78% changed by less than 0.1%.

The retained historical archive contains both annual model outputs for all 114
years and both selected-cell daily outputs for all 10 requested years.
