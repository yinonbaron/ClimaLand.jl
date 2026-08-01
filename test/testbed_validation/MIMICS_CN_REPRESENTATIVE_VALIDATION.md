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

The ephemeral fresh-reference adapter now performs those two steps as one
MIMICS-CN worker: it runs the pinned shared Fortran executable, reduces the
80-cell output, runs the existing selected-cell Julia comparison with the
frozen policy, and writes the standard `comparison.toml`. Configure
`FreshReferenceAdapter.commands` with `mimics_cn_forcing_root` and
`mimics_cn_reference_template` before passing its build, worker, and preflight
commands to `run_fresh_reference`. The other four model workers remain
fail-closed.

The worker checks every fresh Fortran stage boundary and every selected daily
historical value. Julia checks every prognostic state step, plus every
diagnostic step. At the first nonfinite evidence it writes
`nonfinite_results.toml` with the exact side, cell, stage, no-leap date, and
variable, then stops before comparison. Fresh-reference orchestration converts
those records into unreviewed `eligibility_gap_proposals.toml`; it never edits
the frozen Scope Manifest. Ordinary scientific comparison failures remain
failures and preserve their complete output directory.

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

After a successful local proof run, verify and record the exact output with:

```sh
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/mimics_cn_proof_run.jl \
  VALIDATION_OUTPUT REDUCED_ORACLE \
  VALIDATION_OUTPUT/mimics_cn_local_candidate.toml
```

This fails unless the four stage, historical, carbon-budget, and
nitrogen-budget checks passed; coverage and reviewed Eligibility Gaps exactly
match the 80-cell Scope Manifest; and the oracle/comparison hashes agree with
both worker receipts. The resulting manifest records the exact oracle,
comparison, receipt, and Scope Manifest SHA-256 values. It is explicitly
`canonical = false`, `publishable = false`, and is not a
`publication_candidate.toml`; promotion still requires a separate canonical
Linux/GNU Fortran run through `reference_publication.jl`.
