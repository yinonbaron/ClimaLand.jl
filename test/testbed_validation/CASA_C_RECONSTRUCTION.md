# CASA-C archive reconstruction

`casa_c_reconstruction.jl` runs the complete 4,263-point CASA carbon-only
CLM5/GSWP3 chain and compares it with the published CASA-C archive. Large
drivers, references, and run outputs remain outside this repository.

The bounded matrix in `casa_c_reconstruction.toml` contains the last public
source revision before archive creation. The later revision pinned by the
reference harness is explicitly excluded: it postdates the archive, and its
only Fortran changes are guarded by `icycle > 1`, so they cannot alter this
carbon-only (`icycle=1`) experiment. The case uses the four controls derived
and hash-pinned by `candidate_reconstruction.toml`; no stage count, parameter,
transformation, postprocessing choice, or tolerance is inferred beyond the
repository and archive evidence recorded in the matrix.
The source Makefile's GNU Fortran 8.1.0 toolchain and flags are recorded as
evidence; because the archive metadata does not identify its compiler, each
attempt also pins the compiler actually used in its build metadata.

Run the archive-predecessor case from the ClimaLand checkout:

```sh
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/casa_c_reconstruction.jl run-case \
  ../biogeochem_testbed .. ../casa_c_reconstruction_issue22 \
  archive_predecessor
```

To execute the bounded matrix in evidence order, stopping at the first exact
match and otherwise recording the best mismatch and blocker, use:

```sh
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/casa_c_reconstruction.jl search \
  ../biogeochem_testbed .. ../casa_c_reconstruction_issue22
```

The runner records the compiler and source revision, every materialized
control and input hash, all output hashes, logs, status, and elapsed time. A
completed stage is reused only when its executable, control, inputs, and
outputs still match. Recovery from a completed model run with an obsolete
output contract additionally requires the same executable, source, control,
and input fingerprint. Accelerated-spin output is restored with the tested
passive-carbon ×10 transformation before normal spin.

`reconstruction_report.toml` records hashes and area-weighted global carbon at
every restart boundary, the documented global spin-convergence checks for the
last two equivalent 20-year-cycle endpoints, exact annual comparisons for
1901–2014, and exact daily comparisons for 1901–1905 and 2010–2014.
Comparisons use zero absolute and relative tolerance and include coordinates,
masks, variables,
units, finite values, missing values, and sign changes while ignoring
non-scientific global creation metadata.
The archive is checked against its manifest byte count and MD5 before use,
and each atomically extracted comparison member has its own recorded MD5.

`search_report.toml` pins an exact match. If the evidence-backed source
revision does not match, it instead records the exhausted matrix, best
mismatch count, and blocker without changing tolerances.

## Result (2026-07-15)

The evidence-backed matrix is exhausted without an exact match. Commit
`630389decceaac88d7ab8e09339daa75f960ba32` completed prespin, accelerated
spin (9,980 model years), exact passive-carbon restoration, normal spin (9,980
model years), and 1901–2014 daily history for all 4,263 points.

Both spins pass the documented convergence checks at equivalent cycle
endpoints. Accelerated spin has a global change of 0.001266 Pg C, with 99.70%
of cells below 1 g C m-2 and 98.50% below 0.1%. Normal spin has a global
change of 0.000842 Pg C, with 99.70% and 98.64% below those thresholds.
Passive restoration has zero mismatches across all restart fields and rows.

At zero tolerance, the best case differs in 29,418,387 values. Twenty-four
annual variables differ; 21 variables differ in each 1901–1905 daily year and
24 differ in each 2010–2014 daily year. Coordinates, masks, variable sets,
types, units, and other critical metadata match. The remaining blocker is the
unpublished archive compiler/toolchain: the source Makefile records GNU
Fortran 8.1.0, while the reproducible run used GNU Fortran 16.1.0 because the
archive metadata does not identify or publish its compiler binary.

The reconstruction report SHA-256 is
`8367bad22fc35d3d2dedb10d51da33213c49be7d1ef5da4c7a8dc7b3067b1b72`;
the exhausted-search report SHA-256 is
`377a053bd8e10d02517b83ea73aca7240a2369c5a3935cb3dcbec2f391f1460e`.

If execution completed but reporting was interrupted, regenerate only the
report:

```sh
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/casa_c_reconstruction.jl report-case \
  .. ../casa_c_reconstruction_issue22 archive_predecessor
```
