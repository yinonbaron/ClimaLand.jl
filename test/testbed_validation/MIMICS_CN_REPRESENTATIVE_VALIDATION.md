# Representative MIMICS-CN validation

MIMICS-CN uses the shared 80-cell `representative` Scope Manifest and the
frozen boundary and historical calibrations. The reduced Fortran oracle
contains all four stage boundaries, annual reducers, 84 fixed daily samples
per variable and cell, and carbon and nitrogen budget residuals. It does not
contain the full daily Fortran history.

Generate the reduced oracle from a completed four-stage Fortran workflow:

```sh
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/generate_selected_mimics_cn_reference.jl \
  REPRESENTATIVE_FIXTURE_MANIFEST \
  test/testbed_validation/validation/scopes/representative.toml \
  FORTRAN_WORKFLOW_ROOT OUTPUT_ORACLE BUILD_METADATA
```

Run the public comparison with an unpublished candidate:

```sh
CLIMALAND_VALIDATION_MIMICS_CN_REFERENCE=OUTPUT_ORACLE \
  julia --startup-file=no --project=.buildkite \
  test/testbed_validation/validation_runner.jl \
  --scope representative --models MIMICS-CN --reference pinned \
  --workers 1 --output validation-output
```

The runner requires exact ordered Scope Manifest cell IDs and rejects every
nonfinite value for an eligible cell. A known nonfinite Fortran trajectory may
be omitted only by adding one reviewed, model-specific Eligibility Gap to the
Scope Manifest with the first nonfinite stage, date, and variable. The gap
removes that model-cell pair atomically from boundary, annual, daily, and
budget comparisons. The current Representative selection has no MIMICS-CN
Eligibility Gaps; its reduced oracle is finite for all 80 cells.

Set `CLIMALAND_RUN_MIMICS_CN_REPRESENTATIVE_VALIDATION=true` when running
`validation_runner_tests.jl` to enable the same long public-runner check. This
is opt-in locally because it executes the full four-stage scientific workflow.

The local macOS/gfortran candidate is suitable for scientific validation but
not for publication. Publication requires regenerating the same payload with
the canonical `x86_64-linux-gnu` Fortran toolchain, then staging it through
`reference_publication.jl`; ordinary local runs cannot claim canonical
provenance or update `Artifacts.toml`.
