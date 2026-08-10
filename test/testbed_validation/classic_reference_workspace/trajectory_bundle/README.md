# CLASSIC Stage B trajectory bundle

This directory defines the version-1 interchange contract for GitHub issue #102.
It is a replay reader and fail-closed validator, not accepted reference evidence.
The tests build synthetic bundles only; a real DE-Hai bundle remains blocked on
the completed issue-#101 call-snapshot extraction and its nonperturbation proof.

## Boundary and chronology

The bundle owns only mineral-soil
`litrmass[:, 1:iccp1, :]` and `soilcmas[:, 1:iccp1, :]`: all PFTs plus bare
ground at native tile and soil-layer resolution. The `iccp2` land-use product
pool, peat, moss, and tracers remain external to Stage B.

The DE-Hai schema pins 1 tile, 12 PFTs, 13 PFT-plus-bare categories, 20 soil
layers, 15 parameter-vector positions, and 4 Q10 coefficients.

`initial.*` is the state at the beginning of the first daily transition,
before competition. It occurs exactly once. Each chronological step then
provides drivers in this application order:

1. competition litter/SOM deltas;
2. land-use litter/SOM deltas;
3. timber-harvest litter/SOM deltas;
4. cover and daily-mean soil conditions for `heterotrophicRespiration`;
5. root-respiration inputs for the `updatePoolsHetResp` audit;
6. turnover/reproduction litter/SOM deltas;
7. mortality litter/SOM deltas;
8. disturbance/fire litter/SOM deltas;
9. maximum annual active-layer depth for `turbation`.

Every external delta is `after - before`, positive into the owned pool, in
`kg C m-2 step-1`. Explicit SOM delta fields are retained for the three
post-respiration processes even though they are zero in CLASSIC v2.0. The
turnover field includes reproduction; the disturbance field includes fire.

`reference.*` arrays are comparison evidence at precise application points.
They are structurally separate from `drivers` and cannot recurrently replace
Julia state. `audit.*` arrays are diagnostics and conservation evidence, not
forcing.

## Time and sampling

The manifest gives every step a `time_start`, `time_end`, and `duration_days`.
Timestamps use the declared ISO-8601 format and UTC time standard. Validation
requires one-day, strictly ordered, contiguous bounds. Each schema field also
has machine-readable `sampling` and `application_phase` values:

- `beginning`: the initial state;
- `interval_mean`: daily arithmetic means or daily rates;
- `interval_sum`: a pool change accumulated over the transition;
- `instantaneous`: the value at its named call/application point;
- `end`: state after turbation at `time_end`;
- `constant`: static geometry, masks, mappings, and parameters.

`tbar`, `thliq`, and `thice` are arithmetic means over the preceding
CLASS physics day, not instantaneous end-of-day values.

## Representation and validation

`schema.toml` separates `static_data`, `initial_state`, `drivers`,
`reference_state`, and `audit_diagnostics`. All real-valued scientific
payloads are required to be Float64 because the accepted local CLASSIC
executable uses `-fdefault-real-8`. Source Fortran INTEGER arguments
(`isand`, `sort`, `spinfast`, `mineral_mask`, and `turbation_on`) remain
int32. Payloads are little-endian, Fortran-column-major arrays.

`validate_bundle` rejects missing or extra fields, missing provenance hashes,
role/unit/dtype/sampling/application-phase mismatches, incompatible dimension
names or exact extents, malformed or noncontiguous time bounds, changed
payload hashes, and lexical or symlink path escapes. Provenance independently
binds the source archive/tree, commit, executable, namelist, job options,
initial condition, instrumentation patch, and schema.

`open_replay` validates first and returns:

- static data and parameters;
- the initial state once;
- chronological steps whose drivers, reference states, and audits are separate
  dictionaries.

## Acceptance remains fail-closed

`verify_replay_acceptance` never accepts the synthetic fixtures. A real bundle
must set `evidence_status = "complete"`, match the pinned CLASSIC v2.0
Zenodo archive and commit, contain one real issue-#101 snapshot per contiguous
step, report no recurrent state replacement, pass replay and nonperturbation
checks, and bind the instrumentation, nonperturbation, and snapshot-index
receipts by SHA-256.

The oracle authority is the pinned fresh local Fortran run. The known mismatch
between that run and the published CBC files is separate provenance evidence
and is not used to weaken or silently substitute the replay oracle.

Run the isolated tests with:

```bash
julia --startup-file=no \
  test/testbed_validation/classic_reference_workspace/trajectory_bundle/runtests.jl
```

No generated CLASSIC source, executable, output, snapshot payload, or real
trajectory bundle belongs in Git. Real replaceable artifacts remain under
`$CLASSIC_REFERENCE_ROOT/replaceable`.
