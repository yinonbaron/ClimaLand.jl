# Stable Representative Validation v1 readiness

Audit updated: 2026-08-10.

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
| Fail-closed aggregation | Ready | Synthetic parity and malformed, missing, duplicate, overlapping, incompatible, timed-out, and scientifically failed report contracts are repository-tested. |
| Forty-job Actions workflow | Operationally verified | All 40 model-shard jobs and the required aggregate passed in public GitHub-hosted runs. |
| Runtime budget | Measured | Warning and hard-timeout limits include measured setup, validation, transfer, and aggregation headroom. |

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

## GitHub-hosted proof

The first complete public proof was
[Actions run 31325476183](https://github.com/yinonbaron/ClimaLand.jl/actions/runs/31325476183)
at commit `63c1252ee89ec11e61e859d2fe7154a95366b8c8`. The latest confirmation was
[Actions run 31376673882](https://github.com/yinonbaron/ClimaLand.jl/actions/runs/31376673882)
at commit `7a8bbabaa54ef03879018d25fdfb06e772c5f419`. Both runs completed all
40 model-shard jobs and the required fail-closed aggregate.

The aggregate reproduced the accepted unsharded scientific result: CASA-C,
CASA-CN, MIMICS-C, and MIMICS-CN each compared 80 of 80 cells; CORPSE compared
78 eligible cells and retained the two reviewed gaps at cells 51 and 3442. The
scope, forcing, reference, comparison schema, Comparison Policy, eligibility,
and scientific outcomes matched the pinned unsharded evidence.

The first proof measured the following GitHub-hosted critical paths. The full
per-shard distribution and artifact identities are recorded in
[`REPRESENTATIVE_VALIDATION_CI.md`](REPRESENTATIVE_VALIDATION_CI.md).

| Measurement | Result |
| --- | ---: |
| Complete workflow wall time | 4,681 s |
| Matrix phase wall time | 4,319 s |
| Peak concurrent shard jobs | 37 of 40 requested |
| Setup before validation | 63--357 s; 338 s median |
| Pinned-artifact staging | 1--5 s; 4 s median |
| Compact-report upload | 0--1 s; 1 s median |
| Aggregate job wall time | 356 s |
| Aggregate computation | 16 s |

| Model | Slowest scientific shard (s) |
| --- | ---: |
| CORPSE | 1689.554 |
| MIMICS-C | 613.640 |
| MIMICS-CN | 3030.433 |
| CASA-C | 454.284 |
| CASA-CN | 1299.150 |

These measurements set the warning at 4,200 seconds, the Validation Runner
deadline at 4,800 seconds, the shard-job timeout at 100 minutes, and the
aggregate-job timeout at 30 minutes. The warning remains diagnostic and does
not alter scientific acceptance. Repository tests prove that missing,
duplicate, overlapping, incompatible, timed-out, corrupt, or scientifically
failed shard evidence prevents the aggregate from passing while retaining a
diagnostic report.

## Unrelated repository checks

At the latest proof commit, the general package workflow still reported a
pre-existing CanopyModel SurfaceFluxes Jacobian mismatch in unchanged canopy
code. The personal fork's CLA workflow also failed before checking contributors
because its CliMA organization secrets were unavailable. Neither failure is in
the Representative soil-biogeochemistry validation path: the dedicated
40-shard workflow and aggregate passed, as did the relevant soil and
biogeochemistry test groups. These unrelated failures remain visible rather
than being skipped or weakening the scientific gate.
