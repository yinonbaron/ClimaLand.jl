# CLASSIC Stage B call snapshots

This directory defines the fail-closed interchange boundary for GitHub issue
#101. A call snapshot records the CLASSIC values surrounding the daily mineral
soil-carbon sequence:

1. `heterotrophicRespiration`
2. `updatePoolsHetResp`
3. post-respiration external transfers
4. `turbation`

The owned state is `litrmass[:, 1:iccp1, :]` and
`soilcmas[:, 1:iccp1, :]`: PFTs followed by bare ground, retaining native tile
and soil-layer dimensions. The `iccp2` land-use product pool, moss, peat, and
tracer pools are outside Stage B. A serialized Fortran post-state has role
`reference_state`; it is comparison evidence and must never be replayed as
forcing.

## Storage contract

Each snapshot is a directory containing `manifest.toml` and one raw binary
payload per field. Payloads use the CLASSIC element precision, canonical
little-endian IEEE representation, and Fortran column-major order. The manifest
records every dtype, shape, role, phase, unit, byte count, and SHA-256. The
reader verifies the complete snapshot before returning any field, so a missing,
truncated, reordered, or modified payload fails closed.

`schema.toml` declares the required Stage B fields. `schema.jl` rejects missing,
extra, misclassified, wrong-dtype, wrong-shape, wrong-extent, or wrong-unit
fields. The evidence gate additionally requires:

- one snapshot labelled `ordinary`;
- one snapshot labelled `frozen_soil`;
- source and instrumentation hashes shared by both snapshots;
- an exact, zero-failure comparison of all 57 overlapping ordinary CLASSIC
  output files against the accepted pristine local run.

Run the synthetic contract tests with:

```bash
JULIA_DEPOT_PATH=/tmp/classic-stage-b-depot \
  julia --project=.buildkite --startup-file=no \
  test/testbed_validation/classic_reference_workspace/stage_b_snapshots/runtests.jl
```

## Completed instrumentation evidence

The reproducible generated patch writes transition-start `pre.*` pools before
competition, land use, or harvest and measures each pre-respiration delta around
the actual process call. Disabled branches explicitly finalize their delta
buffers as zero. The bound DE-Hai job options prove that `PFTCompetition`,
`lnduseon`, `timberHarvest`, `dofire`, and `prescribedFire` are all false.

The patch was applied only to a disposable v5 CLASSIC source copy; the pristine
extracted source remained unchanged. The canonical schema seals 66 fields.
`static.zbot` is the total 20-layer bottom-depth coordinate; `static.zbotw` and
`static.delzw` are the tile-specific permeable bottom depth and thickness and
may legitimately be zero below permeable soil.

The instrumented v5 run passed exact local-pristine comparison for all 57
output files and all 4,749 daily records. Its independently inspectable sparse
events are the ordinary transition at NetCDF index 1 (`2000-01-01`) and the
frozen-soil transition at index 357 (`2000-12-22`). Soil temperature is
bit-exact across all layers. Converting recorded volumetric ice with
`static.delzw` to `mrsfl` uses a fixed ceiling of eight ULP; the observed maxima
are zero and eight ULP respectively. The same run retained a gap-free, bounded
366-event daily capture for the complete 2000 leap-year seasonal cycle.

The execution receipt binds the source and container archives, SIF image, GNU
Fortran toolchain and flags, executable, instrumentation patch, job options and
the disabled process switches, parameter namelist, initialization, meteorology,
and CO2 inputs. The completed receipt is
`$CLASSIC_REFERENCE_ROOT/replaceable/runs/issue-101-stage-b-instrumented-v5-promotable/stage_b_snapshots/complete_receipt.toml`
with SHA-256
`6c4acb8e2e280238794492b20d8dfdbc97cc3d35eb78c96b97a204184e944b9e`.

The promoted v4 receipt remains internally valid evidence for its historical
65-field schema, including proof that the literal-zero pre-process branches were
disabled. It is superseded for current work because it lacks total-layer
`static.zbot` and therefore does not satisfy the 66-field canonical schema. The
earlier v3 evidence was never promoted.

No generated patch, CLASSIC source copy, binary, NetCDF output, or snapshot
payload belongs in Git. Those artifacts remain under
`$WORK/classic-v2-reference/replaceable`.

## Source evidence

`heterotrophicRespirationMod.f90` declares `humtrsvg` in
`umol CO2 m-2 s-1` and converts the per-step humification amount back to that
rate. `ctemDriver.F90` calls respiration and pool update before later turnover,
mortality, disturbance, and turbation. `soilCProcesses.f90` treats turbation as
a conservative vertical redistribution. These declarations determine the
units, ordering, and state/reference roles enforced here.
