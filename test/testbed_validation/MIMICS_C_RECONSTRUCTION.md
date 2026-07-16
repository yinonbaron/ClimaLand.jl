# MIMICS-C archive reconstruction

`mimics_c_reconstruction.jl` runs the complete 4,263-point MIMICS
carbon-only CLM5/GSWP3 chain and compares both its CASA plant and MIMICS soil
histories with the published MIMICS-C archive. Large drivers, references, and
run outputs remain outside this repository.

The bounded matrix in `mimics_c_reconstruction.toml` contains the last public
source revision before archive creation and the committed pre-Q10 KO4 table
named by the archive metadata. The current source and JAMES KO4 table are
excluded from the production matrix because their temperature-sensitive
desorption fields postdate the archive. They remain useful for the separate
current-reader smoke validation.

The four controls are generated and hash-pinned by
`candidate_reconstruction.toml`. The committed README supports repeated spin
simulations when needed, and the committed `STEP_2bof4` control supplies the
second restart boundary. The `HIST2` and `HIST3` controls are not attempted:
they select carbon-nitrogen KO6 settings and provide no evidence for a
carbon-only KO4 continuation.

Run the archive-predecessor case from the ClimaLand checkout:

```sh
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/mimics_c_reconstruction.jl run-case \
  ../biogeochem_testbed .. ../mimics_c_reconstruction_issue23 \
  archive_predecessor
```

To execute the bounded matrix in evidence order, stopping at the first exact
match and otherwise recording the best mismatch and blocker, use:

```sh
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/mimics_c_reconstruction.jl search \
  ../biogeochem_testbed .. ../mimics_c_reconstruction_issue23
```

The runner records the compiler and source revision, every materialized
control and input hash, CASA and MIMICS restart hashes and area-weighted carbon
at every boundary, all output hashes, logs, status, and elapsed time. A stage
is reused only when its executable, control, inputs, and outputs still match.

`reconstruction_report.toml` records the documented global MIMICS
spin-convergence checks at the last two equivalent 20-year-cycle endpoints.
It compares both CASA and MIMICS annual histories for 1901--2014 and daily
histories for 1901--1905 and 2010--2014. Comparisons use zero absolute and
relative tolerance and include coordinates, masks, variables, units, finite
values, missing values, and sign changes while ignoring non-scientific global
creation metadata. The archive is checked against its manifest byte count and
MD5 before use, and each atomically extracted comparison member has its own
recorded MD5.

If execution completed but reporting was interrupted, regenerate only the
report:

```sh
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/mimics_c_reconstruction.jl report-case \
  .. ../mimics_c_reconstruction_issue23 archive_predecessor
```

## Result

The bounded evidence matrix is exhausted. The archive-predecessor case
completed all four stages for 4,263 active grid points with GNU Fortran
16.1.0, but it does not exactly reconstruct the archive. The best mismatch is
21,942,324 scientific values at zero absolute and relative tolerance, with no
metadata mismatches.

Both spin phases miss the documented convergence checks. The first spin has
an absolute global carbon change of 0.0105290 Pg C, 97.2555% of active cells
below 1 g C m-2, and 98.1938% below 0.1%. The continuation has an absolute
global carbon change of 0.0133436 Pg C, 97.5839% below 1 g C m-2, and 99.0852%
below 0.1%. Thus both pass the fractional-change check but fail the strict
global and 1 g C m-2 checks.

The annual comparison fails 11 CASA variables across 224,153 values and 11
MIMICS variables across 469,593 values. The retained daily windows fail
6,667,873 CASA values and 14,580,704 MIMICS values. Coordinates, masks,
variable sets, types, critical attributes, finite values, and missing values
have no metadata mismatch. Applying the in-process annual reduction to the
archive's retained daily windows reproduces every archived NCO 4.7.5 annual
value exactly for both models, so the annual differences are not reduction
artifacts.

The remaining blocker is that the archive compiler/toolchain is unpublished.
GNU Fortran 8.1.0, recorded by the source Makefile, is explicitly represented
as a blocked candidate because it is unavailable on the current macOS ARM
host; the exact archive predecessor and pre-Q10 KO4 setup completed with GNU
Fortran 16.1.0. Post-archive Q10 source and unsupported carbon-nitrogen history
continuations remain excluded. Tolerances were not changed in response to the
result.

The completed search report has SHA-256
`e9d7a658f406bb6beccc86df7bcb05012f3dd76da6f4a70c29fee91cf144fc7d`;
the reconstruction report has SHA-256
`093f99cdc05629554f2582c6e0274f3871707d56006138c38ee071775da68012`.
