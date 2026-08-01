# CORPSE Representative validation

The pinned CORPSE comparison runs the native four-stage `LegacyDaily` model on
the immutable 80-cell Representative scope. Cells 51 and 3442 are reviewed
Eligibility Gaps because their Fortran vegetation category is zero. Every one
of the other 78 cells must be compared; a nonfinite value is a hard failure.

## Oracle payload

The reference bundle has four roles:

- `boundaries`: an uncompressed POSIX tar archive containing the exact
  `casa_final.csv`, `corpse_final.csv`, `grid.csv`, and `stage_metadata.toml`
  files for each calibrated stage, plus `reconstruction_report.toml`;
- `boundaries_manifest`: `corpse-boundary-archive-v1`, declaring the fixed
  member set and SHA-256 of every member;
- `reduced_history`: the NetCDF oracle containing annual means, end-of-year
  states, annual carbon-flux totals, and the fixed daily samples;
- `reduced_history_manifest`: the existing
  `corpse-c-representative-fortran-reduced-v1` manifest.

The adapter verifies the outer bundle, both companion schemas, all archive
members, the Representative forcing compatibility identity, and the reviewed
gaps before the scientific executor starts. The executor applies the existing
`corpse-c-representative-fresh-fortran-v1` calibration without changing its
tolerances or reference values. The deterministic CASA/CORPSE boundary CSVs
and reduced NetCDF remain byte-pinned to that calibration. Reconstruction and
stage metadata are pinned by the immutable artifact and checked for their
schema, stage, grid, and source provenance, but are not compared to the old
byte hashes because they contain run-specific absolute paths and elapsed time.

Create the four payload files from a verified fresh Fortran run with:

```sh
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/generate_pinned_corpse_payload.jl \
  FORTRAN_REFERENCE_ROOT REDUCED_REFERENCE_NC DESTINATION
```

The public pinned comparison is:

```sh
julia --startup-file=no --project=test \
  test/testbed_validation/validation_runner.jl \
  --scope representative --models CORPSE --reference pinned \
  --workers 1 --output validation-output
```

Before the published artifact is bound, set
`CLIMALAND_VALIDATION_CORPSE_REFERENCE` to the generated reference bundle
directory to exercise the same pinned path locally.

The runner has a two-hour process deadline. It stores checkpoints, the compact
candidate reduced history, and TOML reports; it does not retain daily history.
