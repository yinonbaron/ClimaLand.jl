# Pristine DE-Hai execution

`run_pristine.sh` implements the execution half of GitHub issue #97. It uses
the verified issue #96 archives to recreate the official CLASSIC v2.0 quick
start layout, runs the published container build and preparation commands, and
then invokes only DE-Hai through the documented direct-site container command.

The script does not edit the source, released site configuration, generated
job options, initialization, restart, forcing, or output descriptors. The
official preparation helper sees the full released 12-PFT site collection, but
no site other than DE-Hai is executed.

Run it from any directory with a new run identifier:

```bash
test/testbed_validation/classic_reference_workspace/de_hai/run_pristine.sh \
  "$WORK/classic-v2-reference" issue-97-de-hai-pristine
```

Set `JULIA` when Julia is not on `PATH`:

```bash
JULIA=/path/to/julia \
  test/testbed_validation/classic_reference_workspace/de_hai/run_pristine.sh \
  "$WORK/classic-v2-reference" issue-97-de-hai-pristine
```

The command refuses to replace any existing extraction, build-evidence, or run
directory. Its outputs are entirely below the replaceable workspace:

```text
replaceable/extracted/issue-97-de-hai-pristine/CLASSIC/
replaceable/extracted/issue-97-de-hai-pristine/published/Benchmark_CLASSIC_output/DE-Hai/
replaceable/builds/issue-97-de-hai-pristine/
replaceable/runs/issue-97-de-hai-pristine/
```

The build directory records exact shell commands, archive hashes, source tag
and commit evidence, host and container versions, container metadata, and
build logs. The run directory records preparation and execution logs, hashes
of the executable and all DE-Hai inputs, hashes of every modeled NetCDF output,
and a completion receipt. `execution_receipt.toml` records the measured facts
from the first issue #97 run while leaving the full evidence outside Git.
Comparison is a separate, fail-closed step; a successful execution receipt
alone is not parity evidence.

## Restart roles

The official run-preparation documentation distinguishes the initialization
from the restart output. `DE-Hai_init.nc` is generated from the released CDL
and read through `init_file`. `prep_jobopts.sh` copies it to `rsfile.nc`, which
the model overwrites only in prognostic fields through
`rs_file_to_overwrite`; that file is the terminal state for a future run.

The benchmark packages `rsFile_modified.nc` beside its raw modeled NetCDF
outputs. Its schema and global metadata identify it as a restart artifact, but
the released documentation does not explain the `_modified` filename. It must
therefore be treated as a terminal restart comparison artifact, not as input
forcing or a replacement for the released initialization. Its whole-file hash
differs from the local final restart, so a field-and-encoding comparison is
required before assigning scientific meaning to that difference.

Authorities:

- CLASSIC v2.0 tag: <https://gitlab.com/cccma/classic/-/tags/CLASSICv2.0>
- Official container and quick start: <https://zenodo.org/records/18201505>
- Benchmarking collection: <https://zenodo.org/records/18202323>
