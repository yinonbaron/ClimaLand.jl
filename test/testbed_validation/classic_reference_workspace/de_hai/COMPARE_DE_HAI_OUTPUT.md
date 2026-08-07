# Compare pristine DE-Hai output

This comparison is intentionally exact. It applies no scientific tolerance,
offset, parameter, or restart adjustment. It compares every modeled NetCDF
file present on both sides over the complete published raw time coordinate.
Reference-only, candidate-only, and explicitly excluded non-modeled files are
always printed.

From the repository root, extract the verified published output into a
replaceable directory:

```bash
REFERENCE_ARCHIVE="$WORK/classic-v2-reference/immutable/archives/zenodo-18202323/Benchmark_CLASSIC_output.tar.gz"
RUN_ID=issue-97-de-hai-pristine
REFERENCE_ROOT="$WORK/classic-v2-reference/replaceable/extracted/$RUN_ID/published"

mkdir -p "$REFERENCE_ROOT"
tar -xzf "$REFERENCE_ARCHIVE" -C "$REFERENCE_ROOT" \
  Benchmark_CLASSIC_output/DE-Hai/netCDF
```

Set `LOCAL_NETCDF` to the `netCDF` directory emitted by the unchanged local
DE-Hai workflow, then run:

```bash
JULIA=/work/yinonmb/software/Julia/julia-1.11.2/bin/julia
DEPOT=/tmp/issue97-compare-depot:/work/yinonmb/software/Julia/.julia
TOOL=test/testbed_validation/classic_reference_workspace/de_hai/compare_de_hai_output.jl
PUBLISHED_NETCDF="$REFERENCE_ROOT/Benchmark_CLASSIC_output/DE-Hai/netCDF"
RUN_ROOT="$WORK/classic-v2-reference/replaceable/runs/$RUN_ID"
LOCAL_NETCDF="$RUN_ROOT/outputFiles/DE-Hai/netCDF"
REPORT="$RUN_ROOT/comparison-report.txt"

set -o pipefail
JULIA_DEPOT_PATH="$DEPOT" "$JULIA" --startup-file=no --project=.buildkite \
  "$TOOL" "$PUBLISHED_NETCDF" "$LOCAL_NETCDF" | tee "$REPORT"
```

The command exits `0` only when at least one modeled file overlaps, both
modeled-file inventories are identical, every paired file has a valid
contiguous time overlap covering the complete published range, all required
dimensions and metadata agree, all coordinate and missing-value masks agree,
and every modeled value is exactly equal. It exits `1` for a comparison
failure and `2` for invalid invocation or an unreadable directory.

For each modeled file, the report prints both dimension maps, modeled-variable
inventories, overlapping raw time endpoints and record count, calendars,
coordinate dimension order and units, fill and missing-value encodings,
missing counts and mask mismatches, numerical failure counts, maximum absolute
and relative differences, and the first failing index. The published
`rsFile_modified.nc` is an initialization/restart payload and is named in the
excluded non-modeled inventory rather than treated as modeled output.

Run the synthetic boundary tests with:

```bash
JULIA_DEPOT_PATH="$DEPOT" "$JULIA" --startup-file=no --project=.buildkite \
  test/testbed_validation/classic_reference_workspace/de_hai/compare_de_hai_output_tests.jl
```
