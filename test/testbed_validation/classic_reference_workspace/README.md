# CLASSIC v2.0 reference workspace

This directory versions only the lightweight controls for GitHub issue #96.
Official archives, extracted inputs, containers, builds, and runs belong under
`$WORK/classic-v2-reference`, outside this Git checkout.

## Workspace policy

`manifest.toml` separates the workspace into two classes:

- `immutable/archives`: the five byte-for-byte Zenodo files. Existing files
  are never overwritten, and every use is gated by the published size and MD5.
- `replaceable/*`: extractions, caches, builds, runs, download staging, and
  fixture staging. These can be regenerated from verified immutable archives.

The manifest pins three version-specific Zenodo records, the CLASSIC v2.0 tag
commit, publication dates, record and embedded licenses, exact file sizes,
checksums, and download URLs. Its 8 GB free-space floor covers twice the
3,675,678,481 compressed bytes; production runs may require more space.

## Setup

From the repository root, select a Julia executable and run:

```bash
WORKSPACE="$WORK/classic-v2-reference"
TOOL=test/testbed_validation/classic_reference_workspace/classic_workspace.jl
MANIFEST=test/testbed_validation/classic_reference_workspace/manifest.toml

julia --startup-file=no "$TOOL" check "$MANIFEST" "$WORKSPACE"
julia --startup-file=no "$TOOL" init "$MANIFEST" "$WORKSPACE"
julia --startup-file=no "$TOOL" fetch "$MANIFEST" "$WORKSPACE"
julia --startup-file=no "$TOOL" verify "$MANIFEST" "$WORKSPACE"
```

`check` requires Linux, `$WORK`, at least 8 GB free, a writable allocation,
Apptainer, tar, and md5sum. It resolves existing ancestors before testing
containment, so a symlink cannot redirect the workspace into the repository or
out of the allocation. The write check creates and removes one temporary probe
file in `$WORK`.

`init` creates only the declared directory layout. `fetch` is the sole
network-mutating command; it is explicit, stages each file under
`replaceable/staging`, checks bytes and MD5, and then atomically moves it into
`immutable/archives`. It refuses to replace an existing immutable file.

Resource IDs can restrict `status`, `fetch`, or `verify`:

```bash
julia --startup-file=no "$TOOL" verify "$MANIFEST" "$WORKSPACE" source container
```

An absent, truncated, or checksum-mismatched file makes `verify` nonzero.
`status` reports the same states without making missing archives an error.

## Official quick-start layout

Do not edit or unpack archives in place. Recreate the official layout under a
replaceable extraction directory, preserving the verified archives as the
audit authority:

```text
replaceable/extracted/CLASSIC/
replaceable/extracted/CLASSIC/tools/apptainerContainerRecipe/CLASSIC_container.sif
replaceable/extracted/CLASSIC/inputFiles/CO2/
replaceable/extracted/CLASSIC/inputFiles/meteorology/
replaceable/extracted/CLASSIC/inputFiles/FLUXNETsites_obs/
```

The published quick start requires `apptainer exec --no-mount bind-paths` and
binds the extracted CLASSIC source and a replaceable run directory into the
container. Reproduction and instrumentation are later issues; this bootstrap
only establishes the verified inputs and execution prerequisites.

## Tests

The tests use tiny synthetic files and do not contact Zenodo:

```bash
julia --startup-file=no \
  test/testbed_validation/classic_reference_workspace/runtests.jl
```

They cover invalid manifest rejection, allocation and symlink boundaries,
missing/size/checksum states, CLI exit codes, atomic staging, and immutable-file
protection.

## Authorities

- [CLASSIC v2.0 source](https://zenodo.org/records/18188101)
- [CLASSIC v2.0 Apptainer container and quick start](https://zenodo.org/records/18201505)
- [CLASSIC v2.0 Benchmarking Collection](https://zenodo.org/records/18202323)
- [CLASSIC v2.0 tag](https://gitlab.com/cccma/classic/-/tags/CLASSICv2.0)

See `LICENSES.md` before extracting, redistributing, or committing any derived
fixture.
