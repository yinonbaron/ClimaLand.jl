# CASA-C Representative validation

The Representative scope is the regular-CI CASA-C comparison. It contains
exactly 80 real grid cells: all 37 Smoke anchors plus 43 deterministic,
PFT-stratified augmented Latin-hypercube selections. The selector uses pinned
forcing and static metadata, excludes inactive candidates, and records its
seed, transforms, weights, allocation, matching errors, candidate population,
and source hashes in `validation/scopes/representative.toml`.

The reduced forcing and CASA-C reference are local Julia artifacts declared in
`validation/Artifacts.toml`. Pinned mode resolves those artifacts and never
silently computes or substitutes a reference. The compact reference records
the exact forcing artifact tree hash, and the runner rejects a reference that
was generated from any other forcing artifact.

## Full-grid tolerance calibration

Representative cells are selected to cover the forcing and environmental
space, not to fit comparison thresholds. CASA-C fresh-Fortran boundary
tolerances therefore come from current Julia checkpoints compared with the
fresh Fortran oracle across all 4,263 cells, for every one of the ten carbon
pools at all four workflow boundaries. Older full-grid Julia summaries were
rejected because they predated the current numerical-parity implementation.
Published archive metrics were not used.

For each finite eligible pair, let

```text
x_i = abs(Fortran_i)
e_i = abs(Julia_i - Fortran_i)
a(r) = max(0, max_i(e_i - r*x_i))
```

The calibration chooses the smallest nonnegative `r` minimizing
`a(r) + r*mean(x)`. It then multiplies both observation-fitted coefficients by
1.05 and adds separately recorded, data-scale Float64 numerical padding to
the absolute coefficient. Every pair is rechecked
against `e_i <= atol + rtol*x_i`.

The committed calibration manifest records distributions, maxima, six
highest-error cells, active constraint cells and slopes, zero-reference
counts, exact source hashes, and the derived mixed absolute-relative policy.
All 170,520 stage-variable-cell pairs were finite and enclosed; no cell was
excluded. Eligible nonfinite values remain hard failures, and exclusions are
allowed only as reviewed scope-manifest gaps.

## Verified run

The public runner completed the pinned Representative CASA-C workflow with
80/80 coverage and no eligibility gaps in 381.321 seconds on the calibration
host:

```sh
julia --project=test test/testbed_validation/validation_runner.jl \
    --scope representative --models CASA-C --reference pinned --workers 1
```

Initialization, all four fresh-Fortran boundaries, the carbon budget, passive
pool restoration, and every checkpoint round trip passed. The underlying
current-Julia 4,263-cell calibration run completed in approximately 1 hour
57 minutes (7,040 filesystem-measured seconds) under concurrent calibration
load. The public runner enforces a 7,200-second process deadline; a timeout
exits with status 124 and records
`outcome = "timed_out"` in the standard report.
