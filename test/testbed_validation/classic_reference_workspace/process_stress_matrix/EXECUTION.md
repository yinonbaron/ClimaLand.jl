# Real four-site matrix execution

The matrix runner consumes only packed external issue #103 archives. It never
copies raw forcing or binary trajectory payloads into Git.

A common-root directory remains supported. Independent canonical archives are loaded from the checked portable manifest.
It stores root-relative archive and receipt identifiers plus verified SHA-256
pairs; `CLASSIC_STAGE_B_ARCHIVE_ROOT` supplies the external root. A common-root layout is:

```text
$CLASSIC_REFERENCE_ROOT/replaceable/runs/issue-103-all-sites-stage-b-v5/archives/
  GF-Guy.tar
  GF-Guy.receipt.toml
  SD-Dem.tar
  SD-Dem.receipt.toml
  US-MMS.tar
  US-MMS.receipt.toml
  CA-Cbo.tar
  CA-Cbo.receipt.toml
```

Each receipt must identify a complete, non-synthetic
`fresh_local_fortran`/`stage_b_v5` seasonal trajectory with at least 365 daily
steps and bind the archive, trajectory schema, embedded capture receipt, and
field-activity report by SHA-256. Archive extraction rejects absolute paths,
path traversal, links, special files, missing control files, and overwrite of
an existing destination. Its top-level allowlist is exactly
`manifest.toml`, `capture_receipt.toml`, `field_activity.toml`, `payloads`, and
`evidence`; any other top-level member rejects the archive before extraction.

Run from the repository root after all four real archives are present:

```bash
JULIA_DEPOT_PATH=/tmp/classic-matrix-depot \
  CLASSIC_STAGE_B_ARCHIVE_ROOT=/path/to/campaign-v8/archives \
  CLASSIC_TOLERANCE_EVIDENCE_ROOT=/path/to/classic-reference/runs \
  julia \
  --project=.buildkite --startup-file=no \
  test/testbed_validation/classic_reference_workspace/process_stress_matrix/run_real_matrix.jl \
  test/testbed_validation/classic_reference_workspace/process_stress_matrix/canonical_archives.toml \
  $CLASSIC_REFERENCE_ROOT/replaceable/runs/issue-106-process-matrix/receipt.toml
```

The adapter calls the accepted `CLASSIC.advance_stage_b` implementation and
carries Julia state between daily steps. Its receipt records maximum absolute
error independently for all six state checkpoints, all fifteen meaningful
flux/audit fields, carbon closure, and accumulated drift. A failed field is
localized to the first failing day and its schema-defined call snapshot.

The checked-in tolerance contract is derived field by field from the accepted
DE-Hai seasonal replay and the real canonical GF-Guy seasonal replay. Each
ceiling is ten times the
largest measured absolute error; fields measured exactly remain exact. The
receipt hashes of both measurements are retained. A later site exceeding one
of these ceilings is localized and leaves acceptance blocked rather than
silently broadening the tolerance.

All four selected canonical archives replay green. The checked manifest and
selection record direct user approval, and the durable external receipt binds
all state, flux, budget, drift, tolerance, schema, and archive hashes.
