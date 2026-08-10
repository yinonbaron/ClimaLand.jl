# CLASSIC Stage B process-stress matrix

This directory selects four process-stressing sites from all 59 released
CLASSIC v2 site configurations. All four selected canonical archives replay within the checked per-field
tolerances. The portable `canonical_archives.toml` records their root-relative
identifiers and hashes, and the checked matrix records the direct user approval
for scientific acceptance.

## Reproduce the selection

Run from the ClimaLand repository root on the machine holding the external
reference workspace:

```bash
JULIA_DEPOT_PATH=/tmp/classic-matrix-depot \
  CLASSIC_TOLERANCE_EVIDENCE_ROOT=/path/to/classic-reference/runs \
  julia \
  --project=.buildkite --startup-file=no \
  test/testbed_validation/classic_reference_workspace/process_stress_matrix/generate_matrix.jl \
  $CLASSIC_REFERENCE_ROOT
```

The generator requires identical 59-site inventories in the released
configuration tree, meteorological forcing tree, campaign run tree, and
campaign site list. Any absent, extra, empty, or symbolic-link input stops the
scan. It writes only derived metrics, paths, and SHA-256 receipts; the raw
FLUXNET forcing and prepared initialization files remain under `/work`.


The tolerance contract stores root-relative evidence identifiers and SHA-256
values, never machine-specific executable paths. Matrix, all-site report, and
real-archive CLIs require `CLASSIC_TOLERANCE_EVIDENCE_ROOT`; loading fails if it
is absent, symbolic, or if an identifier resolves outside that root. The
historical `/work` text above describes data placement only and is not
dereferenced by the tolerance loader.
## Measured definitions

The forcing contains 48 records per day. Temperature is used in degrees
Celsius. Precipitation is converted from kg m^-2 s^-1 to millimetres per record
with the inferred 1,800-second interval. A dry month has less than 30 mm and a
dry day has less than 1 mm. Freeze/thaw transitions are sign changes around
0 °C between consecutive daily-mean air temperatures. Mineral layers have
CLASSIC `SAND >= 0`; `SAND == -2` is organic soil and `SAND == -3` is bedrock.
Initial mineral liquid water is the mean `THLQ` over mineral layers.

The criteria and deterministic ranks are encoded in `generate_matrix.jl` and
repeated in `selection_matrix.toml`:

- tropical warm/wet: |latitude| <= 23.5°, mean temperature >= 20 °C,
  precipitation >= 1,500 mm/year, and dry-month fraction <= 0.25; rank by
  greatest precipitation, then smallest dry-month fraction;
- seasonal dry: mean temperature >= 15 °C, dry-month fraction >= 0.25, and
  maximum dry spell >= 30 days; rank by greatest dry-month fraction, then
  longest dry spell;
- wet mineral: |latitude| >= 23.5°, precipitation >= 1,000 mm/year,
  dry-month fraction <= 0.2, mineral-layer fraction >= 0.8, and initial
  mineral `THLQ` >= 0.25 m3/m3; rank by greatest initial mineral water, then
  greatest precipitation;
- cold/freeze-thaw: mean temperature <= 10 °C, minimum temperature <= -10 °C,
  subzero-day fraction >= 0.1, and at least 10 daily freeze/thaw transitions;
  rank by greatest transition count, then greatest subzero-day fraction.

Classes are selected in the order above and an already selected site is not
eligible for a later class.

## Selected matrix

| Process class | Site | Measured evidence |
|---|---|---|
| Tropical warm/wet | GF-Guy | 25.614 °C mean; 3,110.493 mm/year; 0.114 dry-month fraction |
| Seasonal dry | SD-Dem | 27.362 °C mean; 0.733 dry-month fraction; 234-day maximum dry spell |
| Wet mineral | US-MMS | 1,084.916 mm/year; 0.105 dry-month fraction; 100% mineral active layers; initial mineral `THLQ` 0.290 m3/m3 |
| Cold/freeze-thaw | CA-Cbo | 7.779 °C mean; -29.610 °C minimum; 0.263 subzero-day fraction; 844 transitions over 27 years |

`site_metrics.toml` retains the same derived metric set for all 59 sites so the
selection can be audited without exposing the forcing. `input_receipts.toml`
hashes each site's metadata, temperature forcing, precipitation forcing, and
prepared initialization. `selection_matrix.toml` binds those two files, the
immutable released source/input/container archives, and the completed #98
campaign summary.

## Scientific acceptance

The four canonical seasonal archives replay green with hash-bound, field-specific
state, flux, daily-budget, and accumulated-drift limits. The direct user
approval is recorded in `selection_matrix.toml`; its status is
`ready_for_acceptance` and `matrix_acceptance_ready` validates the durable
external receipt before returning true.
