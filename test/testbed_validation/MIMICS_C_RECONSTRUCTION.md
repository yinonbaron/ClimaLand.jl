# MIMICS-C archive reconstruction

`mimics_c_reconstruction.jl` runs the complete 4,263-point MIMICS
carbon-only CLM5/GSWP3 chain and compares both its CASA plant and MIMICS soil
histories with the published MIMICS-C archive. Large drivers, references, and
run outputs remain outside this repository.

The separate ephemeral fresh-reference adapter exposes MIMICS-C as a complete
Representative worker. It uses the shared verified Fortran executable for a
three-stage 80-cell carbon-only workflow, creates a reduced oracle inside the
isolated run directory, and runs the selected-cell Julia workflow once with
the frozen boundary and historical policies. Its normalized result is
`comparison.toml`; ordinary scientific mismatches fail and preserve the run.

Every fresh Fortran stage boundary and selected historical daily value is
checked for nonfinite output. Julia checks every prognostic and diagnostic
value after every native step. The first exact side, cell, stage, no-leap date,
and variable are written to `nonfinite_results.toml` for orchestration to turn
into an unreviewed Eligibility Gap proposal. The worker never edits the Scope
Manifest or pinned artifact bindings.

The bounded matrix in `mimics_c_reconstruction.toml` contains the last public
source revision before archive creation and the committed pre-Q10 KO4 table
named by the archive metadata. The current source and JAMES KO4 table are
excluded from the production matrix because their temperature-sensitive
desorption fields postdate the archive. They remain useful for the separate
current-reader smoke validation.

The three controls are generated and hash-pinned by
`candidate_reconstruction.toml`: a 100-year prespin, one 9,980-year spin, and
the 1901--2014 history initialized directly from that spin endpoint. The
public `STEP_2bof4` restart continuation is excluded because it was first
committed on 2021-08-27, after the archive was created on 2021-02-02. The
`HIST2` and `HIST3` controls are also excluded: they select carbon-nitrogen KO6
settings and provide no evidence for a carbon-only KO4 continuation.

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

The corrected three-stage archive-predecessor case completes for 4,263 active
grid points with GNU Fortran 16.1.0, but it does not exactly reconstruct the
archive. It has 8,824,261 scientific-value mismatches at zero absolute and
relative tolerance, down from 21,942,323 for the rejected continuation
workflow. The search score is one higher in each case because it also counts
the failed convergence criterion. CASA now matches exactly in all annual
outputs and both retained daily windows. The remaining differences are
MIMICS-only: nine annual variables across 267,381 values and 8,556,880 values
in the ten retained daily years. There are no metadata mismatches.

The earlier four-stage reconstruction completed both 9,980-year spins for all
4,263 points, but incorrectly initialized history from the second endpoint.
That run remains recorded as an attempted, rejected candidate rather than an
archive-era primary stage. A controlled 1901 rerun from the first spin endpoint
shows that this extra continuation caused the dominant `cLITs` difference:
the day-one global stock error falls from +2.782936 Pg C to -0.007861 Pg C,
while the archived and reconstructed litter inputs match exactly. It also
reduces the `cSOMc` error from +1.824668 Pg C to -0.555844 Pg C. No tested
continuation duration matches both pools: the closest `cLITs` endpoint leaves
a large `cSOMc` error, and the closest `cSOMc` endpoint leaves a large `cLITs`
error. The attempted durations, controls, and outcomes are recorded in
`provenance_attempts.toml`, together with the rejected four-stage report hash
that covers both CASA and MIMICS restart hashes at the continuation boundary.

The residual day-one `cSOMc` difference is spatially concentrated rather than
a continuing forcing error. Of 4,263 cells, 3,957 match exactly; barren or
sparsely vegetated PFT 16 accounts for -0.54417 Pg C of the -0.55584 Pg C
global residual. This points to an unrecorded archive-build or initialization
detail affecting that slow pool, not to the post-archive continuation.

The single retained spin has an absolute global carbon change of 0.0105290 Pg
C, 97.2555% of active cells below 1 g C m-2, and 98.1938% below 0.1%. It passes
the fractional-change check but narrowly fails the strict global and 1 g C
m-2 checks.

The remaining blocker is that the archive compiler/toolchain is unpublished.
GNU Fortran 8.1.0, recorded by the source Makefile, is explicitly represented
as a blocked candidate because it is unavailable on the current macOS ARM
host; the exact archive predecessor and pre-Q10 KO4 setup runs with GNU
Fortran 16.1.0. Post-archive Q10 source and unsupported carbon-nitrogen history
continuations remain excluded. Tolerances are not changed in response to the
result.

The reconstruction report has SHA-256
`0e34c90df103e08bcb49a5720647dcf560f66f6fb415f9af8b3484c5ace03ed1`.
The completed search report has SHA-256
`b10428ed8ecdc9edc3bb80f667908a5f24c8127459e0bbf3062b57b628fd2a0f`.
