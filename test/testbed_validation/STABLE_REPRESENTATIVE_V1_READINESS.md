# Stable Representative Validation v1 readiness

Audit updated: 2026-08-07.

All six canonical Linux artifacts are published and bound: one shared
Representative forcing bundle and one pinned Fortran-reference bundle for each
of CORPSE, MIMICS-C, MIMICS-CN, CASA-C, and CASA-CN. The public unsharded
entry point remains:

```sh
julia --startup-file=no --project=test \
  test/testbed_validation/validation_runner.jl \
  --scope representative --models all --reference pinned \
  --output validation-output
```

The GitHub Actions workflow uses the same runner but creates 40 independent
single-model jobs: five models crossed with eight deterministic cell shards.
Its required aggregation job reconstructs the standard all-model report and
fails closed on incomplete, duplicate, overlapping, inconsistent, or failed
shard evidence. The exact CI topology and operator checklist are documented in
[`REPRESENTATIVE_VALIDATION_CI.md`](REPRESENTATIVE_VALIDATION_CI.md).

## Acceptance status

| Criterion | Status | Evidence or remaining proof |
| --- | --- | --- |
| Pinned references | Ready | The forcing and all five model references have immutable Linux artifact bindings. |
| Deterministic shard runner | Ready | One-based index/count controls preserve unsharded defaults and partition the exact ordered Scope Manifest. |
| Fail-closed aggregation | Ready locally | Synthetic parity and malformed/missing/duplicate/inconsistent report contracts are repository-tested. |
| Forty-job Actions workflow | Implemented, external proof pending | The 5-by-8 matrix, model-specific staging, unique report artifacts, and required aggregate job are configured. |
| Runtime budget | Provisional | Conservative shard timeouts remain until a clean GitHub-hosted run measures every shard. |

## Linux baseline measurements

The following successful single-model Representative runs establish the
unsharded baseline. They do not predict GitHub Actions matrix wall time.

| Model | Result | Wall time (s) |
| --- | ---: | ---: |
| CASA-C | 80/80 | 1082.496 |
| CASA-CN | 80/80 | 2743.260 |
| CORPSE | 78/80 and 2 reviewed gaps | 7877.423 |
| MIMICS-C | 80/80 | 2025.416 |
| MIMICS-CN | 80/80 | 11281.390 |

The current workflow retains a 7,200-second runner deadline, a 180-minute job
timeout, and a provisional warning at 3,600 seconds for every shard. These
limits intentionally include substantial margin until CI supplies observed
per-shard distributions.

## Remaining external verification

Repository implementation cannot prove GitHub-hosted scheduling or runtime.
A clean Actions run must still demonstrate all 40 matrix jobs plus aggregation,
record the run URL and commit, verify aggregate coverage and provenance, record
per-shard timings, and exercise retained diagnostics for a deliberately missing
or invalid shard. Until that evidence is recorded, the workflow is implemented
but not declared operationally verified. See the unchecked proof list in
[`REPRESENTATIVE_VALIDATION_CI.md`](REPRESENTATIVE_VALIDATION_CI.md).
