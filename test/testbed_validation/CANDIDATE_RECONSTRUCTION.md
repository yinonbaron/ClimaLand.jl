# Testbed control and parameter reconstruction

This workflow reconstructs missing soil-testbed inputs as auditable derived
candidates. It does not label any generated file as an upstream original.
The source checkout must be at
`27ae1a0b673411642cd780ecad66d1c8f84e6a58`, and generated files must be
written outside that checkout.

## What is reconstructed

`candidate_reconstruction.toml` is the machine-readable derivation source of
truth. It pins the source and derived SHA-256 hash for every candidate, records
the evidence and rejected alternatives, and describes each mutation with an
expected before and after value.

The same specification pins SHA-256 hashes for every upstream parameter,
phenology, and perturbation file staged by reduced validation. The harness also
requires a clean pinned `SOURCE_CODE` directory, so a validation report cannot
silently combine the named commit with locally modified scientific inputs.
Grid, soil, and meteorology fixture files are likewise checked against both the
byte counts and SHA-256 hashes in `fixture.toml` before staging.

The parameter candidates are:

- `casa_boreal_nfix`: changes PFT 1 (evergreen needleleaf forest), field
  `nfixrate`, from `0.08` to `0.21`. The README calls this the boreal-N-fix
  change and says the new value equals the larch value; PFT 3 already has
  `0.21` in the nearest committed CASA table.
- `mimics_ko6_fi30`: changes `KO(1)` and `KO(2)` from `4` to `6` while
  retaining `FI(struc)=0.30`.
- `mimics_ko6_fi10`: makes the same two KO changes and changes
  `FI(struc)` from `0.30` to `0.10`. This is the bounded lower-confidence
  alternative because the README says the KO6 branch resembles the earlier
  desorb2 branch, whose recorded chemical input fraction is `0.10`, and the
  missing filename omits the later `FI30` suffix.
- `mimics_ko6_fi05`: makes the same two KO changes and changes
  `FI(struc)` from `0.30` to `0.05`. A legacy `EXAMPLE_GRID` table directly
  combines KO=6 with FI=0.05. It remains a medium-confidence candidate because
  that older table does not provide the complete current CN parameter contract.

The KO candidates start from the committed JAMES KO4 table. It is identical
to the older `KO4_push` table except for `desorpQ10=-1` and
`desorpTref=25`. Those two fields are required by the pinned Fortran reader;
the older table parses all preceding values and then stops at the missing
fields. Selecting the parser-complete committed table is therefore a source
compatibility choice, not another inferred scientific parameter change.

The control candidates cover the CASA carbon-only prespin, accelerated spin,
normal spin, and historical stages, and the MIMICS carbon-only prespin, two
long-spin stages, and historical stage. They are derived from the checked-in
CN families with explicit `isomModel` and `icycle=1` rules. Output paths are
changed from `OUTPUT_CN` to `OUTPUT_C`; CASA and MIMICS parameter paths are
changed only where the source prespin named one of the missing CN candidates.
Assertions whose before and after values are equal are retained in the report
so the model switch is explicit even when it was already correct.

## Generate and inspect candidates

From the ClimaLand checkout:

```sh
julia --startup-file=no \
  test/testbed_validation/candidate_reconstruction.jl generate \
  ../biogeochem_testbed /tmp/testbed-candidates
```

This creates candidate parameters and controls under the output directory and
writes `derivation_report.toml`. Generation stops if the source commit, a
source hash, an expected before value, or a derived hash differs. Absolute and
escaping paths are rejected, and the source and output roots may not overlap
in either direction. Existing symlinks are resolved before this check, so a
destination cannot alias back into the immutable source checkout.
Candidate bytes are written to a temporary file, hash-verified, and only then
atomically moved into place; a failed derivation leaves any prior valid
candidate intact.

The standalone reconstruction tests can be run without external data:

```sh
julia --startup-file=no \
  test/testbed_validation/candidate_reconstruction.jl self-test
```

## Validate with the pinned Fortran executable

```sh
julia --startup-file=no \
  test/testbed_validation/candidate_reconstruction.jl validate \
  ../biogeochem_testbed \
  test/testbed_validation/fixtures/casa_c_cell_11060 \
  /tmp/testbed-candidates /tmp/testbed-candidate-runs
```

Validation compiles or reuses the pinned executable through the resumable
reference harness. Twelve one-cell, one-year cases execute every generated
candidate independently: the CASA boreal-N-fix table, all three bounded MIMICS
KO6/FI alternatives, four CASA-C controls, and four MIMICS-C controls.
The validation-run and candidate-output roots must also be disjoint from the
upstream checkout and immutable fixture tree, including through symlink aliases.

For a control candidate, the reduced validation control is derived from that
exact generated `.lst`, not synthesized independently. Each of its 29 parsed
fields is replaced by an explicit one-cell validation value with asserted
before and after values. `control_reduction_report.toml` records the source and
derived hashes plus the complete field-level reduction diff. This preserves
evidence that the candidate itself parsed while keeping the runtime small.

Each of the twelve cases is run independently twice. Parsing and execution must complete, and
the CASA and MIMICS restart CSV hashes must be identical between repeats. The
result is written to `reduced_prespin_validation.toml`, including executable,
fixture, control, and output hashes. NetCDF file bytes are not used for this
repeatability gate because their global creation timestamp is intentionally
variable.

The reduced runs prove that the candidates are internally consistent with the
pinned reader and deterministic for the selected productive cell. They do not
prove that either inferred KO6 variant generated a published archive, nor do
they establish historical parity. The complete 4,263-cell reconstruction and
archive comparison remain the downstream CASA-C and MIMICS-C workflow tasks.
