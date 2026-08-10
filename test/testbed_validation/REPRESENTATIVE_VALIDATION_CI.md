# Representative validation in GitHub Actions

The dedicated Representative workflow divides the five model comparisons into
eight deterministic cell shards per model. Its matrix therefore creates 40
independent jobs:

| Model | Shards | Eligible Representative coverage |
| --- | ---: | ---: |
| CORPSE | 8 | 78 compared cells and 2 reviewed Eligibility Gaps |
| MIMICS-C | 8 | 80 compared cells |
| MIMICS-CN | 8 | 80 compared cells |
| CASA-C | 8 | 80 compared cells |
| CASA-CN | 8 | 80 compared cells |

Each job runs on its own `ubuntu-latest` virtual machine with one Julia thread,
one OpenBLAS thread, one model, and one shard. The matrix sets
`max-parallel: 40` and `fail-fast: false`, so all shards can provide evidence
even when one fails. Forty is a workflow ceiling, not reserved capacity;
GitHub may run fewer jobs simultaneously when the account's concurrent-job
allowance is in use elsewhere.

The workflow runs for every pull request and every push to `main`. Its
concurrency group cancels an older run for the same Git ref when a newer commit
arrives.

## Shard execution

The local unsharded command remains the simplest complete proof:

```sh
julia --startup-file=no --project=test \
  test/testbed_validation/validation_runner.jl \
  --scope representative --models all --reference pinned \
  --output validation-output
```

One CI-equivalent shard can be reproduced locally with:

```sh
julia --startup-file=no --project=test \
  test/testbed_validation/validation_runner.jl \
  --scope representative --models CASA-C --reference pinned \
  --shard-index 1 --shard-count 8 --workers 1 \
  --output validation-output
```

Shard indices are one-based. The runner assigns the ordered Representative
cell IDs by striding from the shard index through the immutable Scope Manifest.
Across indices 1 through 8, every scope cell is assigned exactly once. Omitting
both shard options preserves the original unsharded behavior; supplying only
one, selecting a non-Representative scope, selecting fresh references, or
selecting more than one model fails before scientific execution.

Each matrix job stages only `representative_forcing` and its model-specific
pinned reference. The Julia package and artifact cache uses one common key
rather than creating 40 shard-specific caches.

## Reports and aggregation

Every shard uploads its compact report under a unique immutable Actions
artifact name:

```text
representative-validation-shard-MODEL-SLUG-SHARD
```

Failure logs use
`representative-validation-failure-MODEL-SLUG-SHARD` and are retained for
seven days. Compact reports are retained for 30 days.

The required `Representative scientific validation` job runs after the matrix,
including after shard failures. It downloads the shard artifacts into separate
directories and invokes `aggregate_validation_shards.jl`. Keeping separate
directories is required because every artifact contains a file named
`validation_report.toml`.

Aggregation fails closed unless it receives exactly 40 reports with the
expected model/shard identities, disjoint exact cell coverage, consistent
scope, forcing, reference, policy, and schema provenance, and passing
scientific outcomes. The aggregate report is uploaded as
`representative-validation-report`, together with the five merged model
comparison reports referenced from it. The required job fails when the matrix,
artifact download, or aggregation failed.

To aggregate reports downloaded or produced under `shard-reports/` locally,
run:

```sh
julia --startup-file=no --project=test \
  test/testbed_validation/aggregate_validation_shards.jl \
  --input shard-reports --output validation-output \
  --shard-count 8 --models all
```

The standard aggregate is `validation-output/validation_report.toml`; merged
model evidence is under `validation-output/models/MODEL/`. An aggregation
error still writes a failed top-level report when an output path is available.
Start diagnosis with its `error` field, then inspect the uniquely named shard
failure-log artifact for the model and index named by that error.

## Timeouts and runtime budget

The proof run below used the provisional 3,600-second warning, 7,200-second
runner deadline, and 180-minute Actions job timeout. It measured a slowest
scientific timer of 3,030.433 seconds, a slowest validation-command step of
3,121 seconds, and a slowest complete shard job of 3,478 seconds.

Those measurements set the current warning to 4,200 seconds, the CI runner
deadline to 4,800 seconds, and the shard job timeout to 100 minutes. The
warning therefore has 1,079 seconds of headroom over the observed command
step, the runner deadline has 1,679 seconds over that command step, and the job
timeout has 2,522 seconds over the observed complete job. The
aggregation timeout is 30 minutes, compared with its observed 356-second job.
The warning remains diagnostic and is not a scientific failure.

The latest unsharded Linux baselines are:

| Model | Coverage | Wall time (s) |
| --- | ---: | ---: |
| CASA-C | 80/80 | 1082.496 |
| CASA-CN | 80/80 | 2743.260 |
| CORPSE | 78/80 plus 2 reviewed gaps | 7877.423 |
| MIMICS-C | 80/80 | 2025.416 |
| MIMICS-CN | 80/80 | 11281.390 |

These are baseline single-model runtimes, not estimates of matrix wall time.

## Verified public run

The first complete public proof is [Actions run 31325476183](https://github.com/yinonbaron/ClimaLand.jl/actions/runs/31325476183),
run on 2026-08-09 for commit
`63c1252ee89ec11e61e859d2fe7154a95366b8c8`. All 40 matrix jobs and the
required aggregation job passed. The run published 40 compact shard artifacts
and `representative-validation-report`; no detailed failure artifact was
needed.

The aggregate report passed with exact coverage:

| Model | Scope | Eligible | Compared | Reviewed gaps | Slowest shard (s) |
| --- | ---: | ---: | ---: | ---: | ---: |
| CORPSE | 80 | 78 | 78 | 2 | 1689.554 |
| MIMICS-C | 80 | 80 | 80 | 0 | 613.640 |
| MIMICS-CN | 80 | 80 | 80 | 0 | 3030.433 |
| CASA-C | 80 | 80 | 80 | 0 | 454.284 |
| CASA-CN | 80 | 80 | 80 | 0 | 1299.150 |

The reports' scientific timers for shards 1 through 8 were:

| Model | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| CORPSE | 1604.540 | 1653.500 | 1689.554 | 1306.651 | 1682.791 | 1665.822 | 1593.764 | 1685.818 |
| MIMICS-C | 612.667 | 592.095 | 613.640 | 613.203 | 600.011 | 612.832 | 609.293 | 453.354 |
| MIMICS-CN | 2982.996 | 2949.751 | 2791.660 | 2453.402 | 3030.433 | 2977.302 | 3025.420 | 2892.438 |
| CASA-C | 451.844 | 445.575 | 454.284 | 452.209 | 438.298 | 442.308 | 339.020 | 434.217 |
| CASA-CN | 1228.072 | 1299.150 | 1298.667 | 1282.556 | 1183.061 | 1270.645 | 970.406 | 961.269 |

GitHub-hosted timing for the run was:

| Measurement | Result |
| --- | ---: |
| Complete workflow wall time | 4,681 s (78 min 1 s) |
| Matrix phase wall time | 4,319 s (71 min 59 s) |
| Peak concurrent shard jobs | 37 of 40 |
| Per-job setup before validation command | 63--357 s; 338 s median |
| Pinned-artifact staging per shard | 1--5 s; 4 s median |
| Compact-report upload per shard | 0--1 s; 1 s median |
| Aggregation job wall time | 356 s (5 min 56 s) |
| Aggregate computation step | 16 s |

The matrix requested all 40 jobs. Peak overlap was 37 because the account's
concurrent-job allowance was shared with other workflows; queued jobs started
as capacity became available. The aggregation job spent 304 of its 356 seconds
installing dependencies. Downloading all compact shard artifacts completed in
less than the Actions timestamp resolution of one second.

Every report used pinned-reference mode and comparison schema
`representative-pinned-comparison-v1`. Aggregation confirmed consistent model,
scope, forcing, reference, policy, schema, and shard provenance. These are the
same pinned identities and Comparison Policies as the accepted unsharded
evidence. The aggregate also reproduced its passing scientific outcomes and
eligibility: all 80 cells were compared for four models, while CORPSE compared
78 and retained the same reviewed gaps at cells 51 and 3442.

In particular, the Scope Manifest SHA-256 was
`293190db2dda44f1babd13715a7e33027349df9e959a40dd60cc9d329671e9f4`,
the forcing artifact was
`40bfe53967c9fa3bd25d82d862f7e0e6d5196df3`, and the model reference
artifacts were:

| Model | Reference artifact |
| --- | --- |
| CORPSE | `1426e867e98d06206142ee2b9643ca6f80c27fd6` |
| MIMICS-C | `0ea35ac9cf7fbc833c1d67fce3642b340e9dd805` |
| MIMICS-CN | `d4c30559c61fcbb6a6ee23249f25c40bc722534c` |
| CASA-C | `701afc982e84c82c51c020b5f177cc4dee5e5a03` |
| CASA-CN | `a3a4bfca744162bd550cf27c1f9a581d735f1c4c` |

The applied policy evidence matched the unsharded baseline: CORPSE policy
SHA-256 was
`2e29a59cf00d6999e264ddf39548271a48d631becf65832e424378c2bde4ba69`;
MIMICS-C boundary and historical calibration SHA-256 values were
`f098e76a042cf4b280d8382030027a928d72e7b8642e74c163eab33793f9316e`
and `a96b26acf36c64597b2c2ad82869dabf73bd8ee09ff2747f9598c5ad542f4cb5`;
MIMICS-CN used
`f4824a4faa7343be90be814cc0eb50d757aa59d4e958723ee40073cc8afd4e7f`
and `4f41ed3b6f41d362c868880f820828f3b91296a4b6d410b60488f8c5db5642e7`;
and both CASA variants used policy SHA-256
`c1e9c3dfa7e2e291fb1e8887e4aefcf88ad70089f2fee934ff6c6f53ada8cbae`.

The fail-closed contract is exercised by
`validation_shard_aggregation_tests.jl`. It demonstrates that missing,
duplicate, overlapping, unreadable, malformed, incompatible,
provenance-inconsistent, timed-out, and scientifically failed shard evidence
fails aggregation while preserving a diagnostic report.

## External proof checklist

The 2026-08-09 public run and the fail-closed aggregation tests complete the
operational checklist:

- [x] Link the workflow run and tested commit SHA.
- [x] Confirm that all 40 matrix jobs and the required aggregation job ran.
- [x] Confirm exact coverage for every model and shard in the aggregate report.
- [x] Confirm forcing, reference, policy, schema, and Scope Manifest provenance.
- [x] Record every shard time, the slowest shard, and aggregate wall time.
- [x] Revise the 3,600-second warning and hard timeouts from those data.
- [x] Demonstrate that a missing, duplicate, overlapping, incompatible,
      timed-out, corrupt, or scientifically failed shard causes the aggregate
      job to fail while retaining diagnostics.
