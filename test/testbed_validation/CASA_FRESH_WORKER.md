# Representative CASA fresh worker

`casa_fresh_worker.jl` runs CASA-C or CASA-CN over the immutable 80-cell
Representative scope with an already-built, checksum-verified shared Fortran
executable. It does not build Fortran and it never updates pinned references,
scope manifests, or comparison policies.

```sh
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/casa_fresh_worker.jl \
  CASA-C SOURCE_ROOT REPRESENTATIVE_FORCING PINNED_ORACLE RUN_ROOT BUILD_ROOT
```

Use `CASA-CN` as the first argument for the carbon-nitrogen configuration.
`REPRESENTATIVE_FORCING` contains `fixture.toml`; `PINNED_ORACLE` is that
model's Representative reference template; and `BUILD_ROOT` contains the
shared executable plus `build_metadata.toml`.

The worker verifies the exact ordered 80-cell scope and fixture checksums,
runs the four Fortran stages, refreshes the reduced fresh-Fortran oracle, runs
the selected Julia workflow, and writes `fortran_output.toml`,
`julia_output.toml`, and `comparison.toml`. CASA-CN daily output is reduced
year-by-year while Fortran runs, retaining only 1901 and 2014 plus the reduced
annual file needed by the existing oracle logic.

Exit status is zero only when initialization, every stage boundary,
historical comparisons, passive-pool restoration, and applicable carbon and
nitrogen budgets pass. Scientific mismatch and structured nonfinite evidence
both return status 1. Nonfinite evidence is written to
`nonfinite_results.toml` with the exact cell, side, stage, date, and variable;
an unrelated infrastructure exception is not converted into scientific
evidence.
