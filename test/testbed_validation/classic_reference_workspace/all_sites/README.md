# CLASSIC 59-site reference campaign

This campaign prepares and runs every site shared by the released
`FLUXNETsites_12PFT` configurations and the published CLASSIC v2.0 benchmark.
The inventory check requires exactly 59 identical site names on both sides;
missing, extra, duplicated, or silently filtered sites stop the campaign.

Run it only in the verified external workspace:

```bash
export CLASSIC_REFERENCE_ROOT=/path/to/classic-v2-reference
export JULIA=julia
test/testbed_validation/classic_reference_workspace/all_sites/run_all_sites.sh \
    $CLASSIC_REFERENCE_ROOT
```

The runner refuses to replace an existing extraction, build, or run directory.
Use a new safe run ID to repeat the campaign.

## Evidence retained for each site

`replaceable/runs/<run-id>/site-evidence/<site>/` contains:

- the exact quoted CLASSIC command and complete model log;
- SHA-256 manifests for prepared inputs and the initial restart;
- SHA-256 manifests for the final restart and fresh local outputs;
- an exact values-and-metadata comparison against the published NetCDF files;
- a receipt that hashes the generated configuration, restart, command, log,
  output manifest, and comparison summary.

An execution or comparison error is recorded for that site and does not remove
other sites from the loop. The final summary is fail closed: it requires one
valid receipt for every site and a completed published comparison for every
fresh local run.

## Completed retained campaign

Run `issue-98-all-sites-pristine-20260809` completed all 59 fresh local
Fortran executions and retained 3,363 output files. The campaign summary is
`$CLASSIC_REFERENCE_ROOT/replaceable/runs/issue-98-all-sites-pristine-20260809/campaign-summary.toml`
with SHA-256
`e49baf594785cd756273c9a3a93b09628d5ae8ecb47e5d4e0796bed21c1e3678`.
The campaign-evidence manifest has SHA-256
`10db3b27ecf3f4c092f2397ea2568bcb8958bdc5f63344dbef98d7d9ff0f2fae`.
All local executions and comparisons completed without errors; the result is
59 fresh local oracles and 59 explicit published mismatches.

## Reference interpretation

The newly approved translation oracle is the **fresh local Fortran output**
generated from the pinned CLASSIC v2.0 source, released container, released
inputs, and checksummed generated configuration. The Zenodo output remains the
**published benchmark** and is compared without modification.

A completed campaign may therefore report `published_mismatches > 0` while all
59 local Fortran oracles are available. This does not claim or imply resolution
of issue #97. Missing inputs, failed model executions, or comparison errors make
the campaign incomplete and produce a nonzero exit status.
