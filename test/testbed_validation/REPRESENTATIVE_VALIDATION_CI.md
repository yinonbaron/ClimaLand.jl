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

## Timeouts and provisional budget

Each shard currently retains the conservative 7,200-second runner deadline and
180-minute Actions job timeout. A warning is emitted after 3,600 seconds. These
values are deliberately provisional until a clean public matrix run supplies
per-shard measurements; the warning is not a scientific failure.

The latest unsharded Linux baselines are:

| Model | Coverage | Wall time (s) |
| --- | ---: | ---: |
| CASA-C | 80/80 | 1082.496 |
| CASA-CN | 80/80 | 2743.260 |
| CORPSE | 78/80 plus 2 reviewed gaps | 7877.423 |
| MIMICS-C | 80/80 | 2025.416 |
| MIMICS-CN | 80/80 | 11281.390 |

These are baseline single-model runtimes, not estimates of matrix wall time.

## External proof checklist

Implementation and local contract tests do not establish GitHub-hosted runtime
behavior. Before declaring the 40-job workflow operational, record one public
Actions run and complete all of the following:

- [ ] Link the workflow run and tested commit SHA.
- [ ] Confirm that all 40 matrix jobs and the required aggregation job ran.
- [ ] Confirm exact coverage for every model and shard in the aggregate report.
- [ ] Confirm forcing, reference, policy, schema, and Scope Manifest provenance.
- [ ] Record every shard time, the slowest shard, and aggregate wall time.
- [ ] Revisit the 3,600-second warning and both timeout values from those data.
- [ ] Demonstrate that a missing, duplicate, corrupt, or scientifically failed
      shard causes the aggregate job to fail while retaining diagnostics.

Until that checklist is complete, CI runtime verification remains pending.
