# Soil Biogeochemical Testbed Port and Validation Specification

This directory is the reproducibility and validation boundary for porting
[`wwieder/biogeochem_testbed`](https://github.com/wwieder/biogeochem_testbed)
to native standalone ClimaLand models. It records the accepted architecture,
the exact external references, and the gates that must pass before a Julia
implementation is called a reproduction of the Fortran model.

Status on 2026-07-13: Milestone 5 carbon-nitrogen implementation and CPU
validation are complete; formal closure awaits the existing CUDA job. The
Milestone 1 reference harness, manifests, checksum
verification, isolated Fortran build, native NetCDF comparator, and
source-exact fixtures exist. The carbon-only `CASAPlantModel`, `CASASoilModel`,
`MIMICSSoilModel`, and fixed-cohort `CORPSESoilModel` are implemented as native
ClimaLand models with SI fields and ClimaTimeSteppers forward-Euler execution.
CASA and MIMICS reproduce 364 archived productive-cell input-output
transitions within their measured NetCDF `Float32` rounding envelopes. CORPSE
matches the pinned one-day Fortran probe and its fresh 365-day productive-cell
Fortran trajectory. CASA plant-to-soil litter coupling and initial model
documentation are also implemented. The plant, all three soil models, and
litter-quality coupling accept native surface fields of immutable point
parameters for heterogeneous PFT and soil maps.

The full CPU package test suite passes with the carbon-only and CN models
enabled.
All four models now have native ClimaLand diagnostics for every prognostic
carbon/bookkeeping state and the major budget and coupling fluxes. Evolved
states pass native HDF5 checkpoint round trips, and multi-cell `Plane` tests
exercise the same field tendencies on the active ClimaComms backend. Those
tests now include heterogeneous parameter fields and point-kernel equivalence.
They are included in the repository's existing full CUDA test job, but CUDA
execution still requires CI or a CUDA host. CASA and MIMICS archived-grid
transition validation now covers 20 representative cells and 7,280 first-year
transitions per model, with maximum pool relative errors below `1.8e-7`.
Milestones 1--4 are not formally closed until the CUDA run passes. Full CASA
and MIMICS
Fortran-to-archive initialization parity remains blocked by unpublished spinup
restarts, so their committed transition fixtures test input-output
relationships without claiming restart reconstruction. Both published CN
archives are locally checksum-verified, and exact inactive/productive CASA-CN
and MIMICS-CN fixtures are committed. CASA and MIMICS now have compile-time
`CarbonNitrogen` states, prescribed-N drivers, SI parameters, point-kernel
conservation tests, and native ClimaTimeSteppers execution. CASA soil has
3,640 archived daily flux/state checks and a one-year replay. MIMICS reproduces
364 archived productive-cell transitions for all C and organic-N pools,
working DIN, respiration, overflow, and mineralization diagnostics. CASA plant
CN is coupled to either soil model with one mineral-N owner and conserved
litter, CWD-N, and uptake transfers. CN diagnostic registration and native
checkpoint round trips cover every new state. Uniform and heterogeneous native
`Plane` gates exercise the CN field models. The CASA-CN and MIMICS-CN archive
workflows each validate 6,916 active first-year transitions selected from 19
productive cells; an additional ice/water cell records the driver-mask
boundary without applying a standalone soil update. CASA-CN pool relative
errors are below `2.7e-7`. MIMICS-CN C and N pool relative errors are below
`1.2e-7`; DIN and respiration absolute errors are below `6.2e-10` kg m^-2.
Milestone 6 now includes native root-weighted `EnergyHydrology` drivers for all
three soil BGC choices, heterogeneous surface rooting depth, integrated
component diagnostics, and full-state vertical-domain checkpoint round trips.
The checkpoint fallback restores CASA, MIMICS, and CORPSE states onto equivalent
`ColumnGrid` domains without asking ClimaCore to reconstruct the unsupported
grid, and also covers the `HybridBox` `LatPoint` reader failure. Standalone
full-state checkpoint gates remain green.
The post-parity CORPSE `ContinuousRate` mode is now implemented as a
timestep-independent simultaneous ODE. It preserves the fixed reference
cohorts, parameters, routing, and environmental responses while evaluating all
processes from one current state without daily loss caps. Forward Euler
convergence, native model execution, carbon conservation, and one-day and
365-day distance from the exact Fortran map are regression-tested. Dynamic
CORPSE cohorts remain a future post-parity task.

The reduced native prespin-to-history tracer is implemented in
`native_workflow.jl`. A `NativeStage` stores only a forcing-period length and
repeat count, so long spins reuse driver indices through `mod1` without
materializing repeated forcing. `run_workflow` advances every recorded day
through ClimaTimeSteppers Forward Euler, round-trips each stage through a
native HDF5 checkpoint, writes a checksummed TOML stage manifest, and streams
selected stages to a 365-day-calendar NetCDF file. Its forcing callback receives
the stage, forcing index, and current time but not the prognostic state; this
keeps all post-initialization state updates inside ClimaTimeSteppers. NetCDF
timestamps are local to the selected output stage, so a long prespin does not
shift the historical epoch. The required provenance block identifies the model
configuration, PFT, parameter table, and forcing artifact for each stage.

`fortran_initial_state` reads the pinned CASA carbon and nitrogen initialization
tables and applies the source MIMICS active/ice-water prespin rules. It returns
native SI named tuples for CASA or MIMICS in carbon-only or CN mode, suitable
for `run_workflow`. Ice/water pools, including mineral N, are zeroed, and grass
PFTs follow the Fortran nonwoody rule for plant wood and CWD. Ordinary tests
exercise productive PFT 7, grass PFT 16, and inactive PFT 17, then run reduced
prespin, spin, checkpoint/restart, and historical stages for CASA-C, CASA-CN,
MIMICS-C, and MIMICS-CN. Historical NetCDF contains every prognostic carbon,
nitrogen, mineral-N, and bookkeeping state.

The pinned CN source files, state ownership, daily calculation order, CWD-N
contract, and next fixture gates are detailed in
[`CN_REFERENCE_AUDIT.md`](CN_REFERENCE_AUDIT.md).

## Scientific and software objective

The port will provide four ClimaLand `AbstractModel` implementations:

- `CASAPlantModel`
- `CASASoilModel`
- `MIMICSSoilModel`
- `CORPSESoilModel`

Soil components subtype `AbstractSoilBiogeochemistryModel`, which currently
inherits ClimaLand's `AbstractImExModel`; carbon-pool tendencies are explicit
and use the default zero implicit tendency.

Accepted namespaces are:

- `ClimaLand.Vegetation.CASA`
- `ClimaLand.Soil.Biogeochemistry.CASA`
- `ClimaLand.Soil.Biogeochemistry.MIMICS`
- `ClimaLand.Soil.Biogeochemistry.CORPSE`

CASA plant must compose with any of the three soil models through one minimal
integrated plant-soil model following the current ClimaLand component and
driver architecture. Reference experiments use prescribed daily GPP,
meteorology, phenology, soil temperature, and soil moisture. The native
coupling obtains root-weighted temperature and liquid/frozen moisture from
ClimaLand `EnergyHydrology` fields while retaining prescribed GPP and
phenology.

The implementation must use ClimaCore fields, ClimaTimeSteppers, ClimaLand
diagnostics and restarts, and ClimaComms device abstractions. Physics code must
be allocation-free and backend-agnostic so the same equations run on CPU and
GPU.

Primary references:

- [Testbed repository](https://github.com/wwieder/biogeochem_testbed)
- `Manual_CASA_testbed.pdf` in that repository
- [Dataset DOI 10.5065/jqts-cg20](https://doi.org/10.5065/jqts-cg20)
- [ClimaLand documentation](https://clima.github.io/ClimaLand.jl/stable/)
- [ClimaLand multi-component tutorial](https://clima.github.io/ClimaLand.jl/stable/generated/standalone/Usage/LSM_single_column_tutorial/)

## Scope

Parity scope is:

- CASA plant carbon and CASA soil carbon;
- MIMICS carbon;
- CORPSE carbon;
- CASA plant/soil carbon-nitrogen;
- CASA plant plus MIMICS carbon-nitrogen, including the reference
  coarse-woody-debris nitrogen treatment;
- configurable root exudation, with zero as the accepted reference default.

Carbon-only modes are implemented before carbon-nitrogen modes. CASA and
MIMICS use compile-time `CarbonOnly` and `CarbonNitrogen` configurations so
nitrogen branches and fields compile away in carbon-only runs. CORPSE supports
only `CarbonOnly` during parity work.

The following are explicitly out of parity scope:

- phosphorus cycling;
- CORPSE nitrogen;
- direct coupling to existing canopy photosynthesis;
- direct coupling of heterotrophic respiration to `SoilCO2Model` transport;
- multiple or fractional PFT tiles at one surface point;
- arbitrary dynamic CORPSE cohort counts;
- a new generic positivity limiter.

Post-parity tasks, which must not be speculatively scaffolded, are:

- general dynamic CORPSE cohorts;
- native canopy/GPP coupling;
- `SoilCO2Model` CO2/O2 transport coupling;
- multiple or fractional PFTs;
- any scientifically defined production-mode positivity treatment.

## State, units, domains, and ownership

Native model units are `kg C m^-2`, `kg N m^-2`, seconds, and the corresponding
SI area rates. Legacy daily, annual, gram, and volumetric units are converted
only at parameter, fixture, input, and output boundaries.

The reference pools are column-integrated surface fields. The port must not
invent vertically resolved biogeochemical pools. With native soil physics,
PFT-specific root weighting maps subsurface temperature and moisture to these
surface fields. PFT tables are expanded into GPU-ready spatial parameter
fields during initialization; no host lookup or runtime PFT dispatch is
allowed in tendency kernels.

Every timestepped stock belongs in `Y` as a named scalar field. Instantaneous
fluxes, environmental scalars, partition fractions, and diagnostics belong in
`p`. Repeated tendency calls at identical `(Y, p, t)` must be deterministic.
The RHS must not allocate fields, rely on historical cache mutation, or read a
partially assembled `Y_t`.

The pinned Fortran type definitions and restart files, rather than only NetCDF
variable names, determine the exact state list. Expected major states are:

- CASA plant leaf, wood, fine-root, and labile pools;
- CASA metabolic litter, structural litter, coarse woody debris, microbial or
  fast SOM, slow SOM, and passive SOM;
- MIMICS metabolic and structural litter, r- and K-selected microbes, and
  available, chemically protected, and physically protected SOM;
- their nitrogen counterparts plus mineral N in CN modes;
- fixed CORPSE surface/soil stocks for labile, recalcitrant, dead-microbial,
  protected, and live-microbial carbon, including reference bookkeeping state
  when it affects later rates.

The selected soil model owns mineral N. Integrated plant uptake is computed
once and contributes equal and opposite plant-N and soil-mineral-N tendencies.
Litterfall, mineralization, immobilization, and all internal transfers must
cancel from combined budgets.

## Reference temporal semantics

Exact parity uses `LegacyDaily`, a pure ordered map
`Phi_day(Y, drivers)`. The Clima tendency is

```text
dY = (Phi_day(Y, drivers) - Y) / 86400
```

A native ClimaTimeSteppers Forward Euler step with `dt = 86400` seconds then
applies the same map:

```julia
forward_euler = CTS.ExplicitAlgorithm(
    CTS.ExplicitTableau(;
        a = zeros(Int, 1, 1),
        b = ones(Int, 1),
        c = zeros(Int, 1),
    ),
)
integrator = CTS.init(prob, forward_euler; dt = 86400)
CTS.step!(integrator)
CTS.solve!(integrator)
```

Reference runs use a 365-day calendar. Driver evaluation, calculation order,
and timestep-dependent caps must match the pinned Fortran experiment. This is
not presented as a timestep-independent continuous ODE.

Calculation order is especially important for CORPSE: litter/exudate addition,
unprotected decomposition, protected decomposition, microbe updates using
already modified pools, and protection updates using already modified pools
and microbes occur sequentially within one day.

The testbed configuration uses fixed rhizosphere and bulk CORPSE cohorts. The
Julia parity model represents these statically and preserves any
`originalLitterC`-like memory that affects subsequent rates. It does not port
general allocatable cohort insertion, culling, or merging.

The post-parity CORPSE `ContinuousRate` option uses those same fixed states and
scientific parameters but is a distinct simultaneous ODE. Decomposition,
protection, protected turnover, microbial turnover, CWD decay, litter, and
exudation are evaluated from the same current state as SI rates. It does not
contain a hidden timestep or source-pool loss cap. Numerical convergence is
therefore tested independently, while `LegacyDaily` remains the exact Fortran
oracle. With the pinned productive-cell forcing, 900-second Forward Euler has
maximum 365-day pool and daily-respiration differences of `0.194` and
`0.00119 g C m^-2`, respectively, from the ordered daily output.

## Safeguards and conservation

Reference safeguards are equations, not cleanup. Preserve source-pool loss
caps, CASA zeroing behavior, bounded environmental and N-limitation scalars,
root-exudation availability limits, and the pinned overflow,
immobilization, and litter-limit behavior.

Do not apply a generic post-hoc positivity limiter. It can alter receiving-pool
partitioning, mask an invalid timestep, and break stoichiometric conservation.

At every applicable scale, test identities of the form:

```text
Delta C stock = GPP or litter input - autotrophic respiration
                - heterotrophic respiration - exported C

Delta N stock = deposition + fixation - leaching
                - gaseous/exported N
```

Tests cover scalar kernels, one-day maps, individual surface points,
integrated plant-soil models, area-weighted global sums, and cumulative
long-run residuals. Tolerances are measured from pinned Fortran
self-reproduction and Julia one-step comparisons. They are never loosened to
make an unexplained mismatch pass.

## External data policy

Large archives and full extractions remain outside this repository. The
default local convention is an external directory selected by
`BIOGEOCHEM_TESTBED_DATA_DIR`; commands also accept an explicit data root.
Never place these files in a ClimaLand artifact or normal package installation.

Published Zenodo artifacts recorded in `experiments.toml` are:

| ID | File | Bytes | MD5 |
|---|---|---:|---|
| `drivers` | `INPUT_GSWP3_CLM5dev110_hist.tar.gz` | 13,399,060,965 | `7b2a438bf095e1133fdf966327167171` |
| `casa_c_output` | `CASACNP_mod5_GSWP3_Conly.tar.gz` | 1,475,682,110 | `6a6dc040f338772bc38116a29d865788` |
| `mimics_c_output` | `MIMICS_mod5_Conly_KO4.tar.gz` | 1,617,153,062 | `1be7b02d77da6f85134b85086c918331` |
| `casa_cn_output` | `CASACNP_mod5_GSWP3_exudate0_cwdN.tar.gz` | 1,922,634,553 | `ffbf1ec50070d9d497d0521fb17e85e3` |
| `mimics_cn_output` | `MIMICS_mod5_GSWP3_KO4_exudate0_cwdN.tar.gz` | 2,583,060,797 | `255b6f31ee01e0269f803144c83122e5` |

The local legacy CASA, MIMICS, and CORPSE 2000-2010 mean files and their
recorded MD5 checksums are also in the manifest. Downloads are never automatic:
they require an explicit user action and checksum verification. Small derived
fixtures may be committed only with extraction code, source checksums, cells,
dates, variables, unit conversions, and CC BY 4.0 attribution.

## Current reference harness

`experiments.toml` is the machine-readable source of dataset, artifact,
experiment, and initial provenance facts. Candidate commits or controls are
marked as candidates; they must not be promoted to authoritative references
until a rerun passes the archive integrity gate.

`provenance_attempts.toml` is the append-only investigation log. Failed and
blocked attempts remain in it so later work does not repeat searches or erase
unexplained differences.

`reference_harness.jl` currently has no non-stdlib Julia dependencies. From
the repository root:

```bash
# Show availability. Missing optional archives are informational.
julia --startup-file=no \
  test/testbed_validation/reference_harness.jl status <data-root>

# Verify every present file; missing files are allowed.
julia --startup-file=no \
  test/testbed_validation/reference_harness.jl verify <data-root>

# Require and verify selected files.
julia --startup-file=no \
  test/testbed_validation/reference_harness.jl verify <data-root> \
  drivers casa_c_output mimics_c_output

# Require every manifest artifact.
julia --startup-file=no \
  test/testbed_validation/reference_harness.jl verify-all <data-root>

# Exercise parsers, checksum behavior, and patch application.
julia --startup-file=no \
  test/testbed_validation/reference_harness.jl self-test \
  <biogeochem-testbed-source-root>

# Copy source to a temporary directory, patch it, and compile it there.
julia --startup-file=no \
  test/testbed_validation/reference_harness.jl build-fortran \
  <biogeochem-testbed-source-root> <build-parent>

# Build the pinned source once, then run a reduced one-cell CASA-C prespin,
# accelerated spin, passive-C restoration, and 1901 historical sequence.
# Repeating this command reuses only stages whose executable, control, inputs,
# transforms, and output hashes still match.
julia --startup-file=no \
  test/testbed_validation/reference_harness.jl casa-workflow-tracer \
  <biogeochem-testbed-source-root> \
  test/testbed_validation/fixtures/casa_c_cell_11060 <run-root>

# Run an already-built executable through any schema-version-1 workflow.
julia --startup-file=no \
  test/testbed_validation/reference_harness.jl run-workflow \
  <executable> <workflow.toml> <run-root>

# Parse a Fortran control and report every required input path.
julia --startup-file=no \
  test/testbed_validation/reference_harness.jl audit-control \
  <fcasacnp_clm_testbed.lst>

# Run the pinned executable through one CASA-C grid year. This is a runtime
# smoke test, not archive parity, because it uses default initial pools.
julia --startup-file=no \
  test/testbed_validation/reference_harness.jl smoke-fortran \
  <biogeochem-testbed-source-root> <extracted-met_1901_1901.nc> \
  <run-parent>

# Build and run a one-cell CASA-C fixture, verify fixture checksums, and compare
# all 365 daily records with the archived NetCDF slice. Cell 51 is an exact
# ice/water boundary check; cell 11060 is the productive initialization audit.
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/casa_fixture_parity.jl \
  <biogeochem-testbed-source-root> \
  test/testbed_validation/fixtures/casa_c_cell_11060 <run-parent>

# Extract a source-exact MIMICS/CASA output pair for one active cell.
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/extract_fixture.jl mimics \
  <mimics_pool_flux_1901_1905_daily.nc> \
  <casaclm_pool_flux_1901_1905_daily.nc> \
  test/testbed_validation/fixtures/mimics_c_cell_11060 11060

# Compile the pinned CORPSE source and run the exact one-day cohort probe.
julia --startup-file=no \
  test/testbed_validation/reference_harness.jl corpse-one-day \
  <biogeochem-testbed-source-root> <run-parent>

# Native scientific comparison. Exact comparison is the default; ignored
# variables must be scientifically justified in the experiment manifest.
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/netcdf_compare.jl \
  <reference.nc> <candidate.nc> [ignored-variable ...]

# Select representative CASA grid cells and measure all first-year soil-pool
# transitions. The optional report is TOML and remains outside normal tests.
julia --startup-file=no --project=test \
  test/testbed_validation/grid_transition_parity.jl casa \
  <casaclm_pool_flux_1901_1905_daily.nc> \
  <pftlookup_igbp_updated4_exud0.csv> \
  <gridinfo_soil_CLM5_GSWP3.csv> [report.toml]

# Run the same selected-cell workflow for MIMICS and its companion CASA file.
julia --startup-file=no --project=test \
  test/testbed_validation/grid_transition_parity.jl mimics \
  <mimics_pool_flux_1901_1905_daily.nc> \
  <companion_casaclm_pool_flux_1901_1905_daily.nc> \
  <mimics-parameters.csv> <casa-parameters.csv> \
  <gridinfo_soil_CLM5_GSWP3.csv> [report.toml]

# Validate CASA-CN with the published CN parameter table and output.
julia --startup-file=no --project=test \
  test/testbed_validation/grid_transition_parity.jl casa-cn \
  <casaclm_pool_flux_1901_1905_daily.nc> \
  <pftlookup_igbp_updated4_exud0.csv> \
  <gridinfo_soil_CLM5_GSWP3.csv> [report.toml]

# Run the complete bounded CASA-CN archive reconstruction search.
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/casa_cn_reconstruction.jl search \
  <biogeochem-testbed-source-root> <data-root> <run-root>

# Run the native four-stage, 4,263-cell CASA-CN reconstruction and compare its
# boundaries and historical output with fresh Fortran and archive data.
julia --startup-file=no --project=test \
  test/testbed_validation/native_casa_cn_reconstruction.jl \
  <biogeochem-testbed-source-root> <forcing-root> \
  <casa-cn-reference-root> <run-root>

# Run the complete bounded MIMICS-CN archive reconstruction search.
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/mimics_cn_reconstruction.jl search \
  <biogeochem-testbed-source-root> <data-root> <run-root>

# Run the native three-stage, 4,263-cell MIMICS-C reconstruction and compare
# its checkpoints and historical output with fresh Fortran and archive data.
julia --startup-file=no --project=test \
  test/testbed_validation/native_mimics_c_reconstruction.jl \
  <biogeochem-testbed-source-root> <forcing-root> \
  <mimics-c-reference-root> <run-root>

# Run the native four-stage, 4,263-cell MIMICS-CN reconstruction with the
# issue-43 KO4/FI30 parameters and separate fresh/archive comparisons.
# See NATIVE_MIMICS_CN_RECONSTRUCTION.md for parameters, stage boundaries,
# diagnostics, tolerances, and the selected-cell validation procedure.
julia --startup-file=no --project=test \
  test/testbed_validation/native_mimics_cn_reconstruction.jl \
  <biogeochem-testbed-source-root> <forcing-root> \
  <issue-43-reference-root> <run-root>

# Gate the global run on a fresh Fortran comparison over the 37 selected cells.
julia --startup-file=no --project=test \
  test/testbed_validation/selected_mimics_cn_validation.jl \
  <biogeochem-testbed-source-root> <issue-43-reference-root> \
  <fortran-executable> <selected-reference-root> <selected-julia-root>

# Validate the ordered MIMICS-CN map, working DIN, overflow, and N fluxes.
julia --startup-file=no --project=test \
  test/testbed_validation/grid_transition_parity.jl mimics-cn \
  <mimics_pool_flux_1901_1905_daily.nc> \
  <companion_casaclm_pool_flux_1901_1905_daily.nc> \
  <pftlookup_LIDET-MIM-REV_CN_desorb2xKO4_micCN_FI30.csv> \
  <pftlookup_igbp_updated4.csv> \
  <gridinfo_soil_CLM5_GSWP3.csv> [report.toml]
```

A workflow TOML has `schema_version = 1`, a unique `name`, the pinned
`source_commit`, and ordered `[[stage]]` tables. Each stage declares a control
file, its expected output paths, and `[[stage.input]]` tables with `source` and
`destination`. A source such as `stage:prespin/casa_final.csv` creates an
explicit dependency on an earlier stage. Input `mode` is `copy` (default) or
`symlink`; `transform = "casa_passive_carbon_x10"` restores passive carbon for
CASA-C, while `transform = "casa_passive_carbon_nitrogen_x10"` restores both
passive pools for CASA-CN. Both transformations locate their fields from the
restart header. Output and destination paths must remain inside their stage
directory.

The runner writes `build/cache_metadata.toml`, one
`stages/NN-name/stage_metadata.toml` per attempted stage, preserved stage logs,
materialized controls, and a top-level `workflow_metadata.toml`. Stage metadata
contains the complete fingerprint, control and input hashes, output hashes,
completion state, and elapsed time. A successful stage is reused only when its
fingerprint and every declared output hash still match; an upstream output
change therefore invalidates its dependent stages automatically.

The build harness obtains compiler and netCDF paths from `gfortran` and
`nf-config`, applies `fortran_compat.patch` only to the copied source, and uses
the flags pinned in `experiments.toml`. It writes `build_metadata.toml` and
`build.log` beside the executable. The compatibility patch only moves four
declarations before their `NAMELIST`; it does not change equations or values.
Modern `gfortran` otherwise rejects this declaration order.

Compiler warnings from the legacy source are retained in the log. A successful
link is not an integrity pass: the executable still has to reproduce the
archived scientific values.

The current smoke recipe completed one full 1901 CASA carbon-only year for all
4,263 active cells. Its exact source commit and input checksums are recorded in
`experiments.toml`; each invocation writes output checksums and logs into its
temporary run directory. These outputs are diagnostic and must not be used as
archive-parity goldens.

The committed cell-51 and cell-11060 fixtures are source-exact slices of the
verified 1901 driver and archived 1901–1905 daily CASA-C output. Cell 51 is
IGBP ice/water and tests the inactive boundary path. Cell 11060 is productive
IGBP shrubland and exercises environmental responses and active carbon pools.
Both manifests record every source checksum and an exact extraction round-trip
audit. Global cell IDs are retained while local latitude/longitude indices are
remapped to `1,1`.

The productive MIMICS fixture contains both archived files needed for its
carbon budget: the seven concentration-based MIMICS pools and the companion
CASA plant/CWD output. The pair reproduces 364 MIMICS daily maps without an
archive-generating restart because each transition starts from the archived
previous-day state. This validates input-output relationships but does not
claim that the unpublished multistage spinup has been reconstructed.

The one-command comparison compiles current Fortran source and runs the first
365 days. Cell 51 matches all 49 variables exactly, but all of its carbon pools
and fluxes are zero, so it is not an active-pool integrity gate. For productive
cell 11060, 28 variables match exactly—including `fT`, `fW`, `thetaLiq`,
drivers, coordinates, masks, and critical metadata—while 21 plant, litter,
soil, and dependent flux variables differ. This is the expected signature of
the missing archive-generating spinup restart; default PFT initial pools are
not a substitute. The productive comparison intentionally exits nonzero until
that initial state is recovered or reconstructed.

The sole coordinate normalization adds 1900 to the raw run's time coordinate:
the archive labels the same fractional-year sequence as 1901–1902, while the
raw executable labels it as 1–2. No scientific tolerance is applied. Each 1×1
run also requires exactly one documented alignment warning because its global
cell ID is not renumbered to 1.

Two independent smoke builds/runs produced byte-identical CASA restart CSVs
and exact data payloads for 47 of 48 NetCDF variables. The exception,
`nLitInptStruc`, is an N-only output that the carbon-only execution path does
not assign before writing. It is recorded as an undefined Fortran output, not
silently tolerated. Raw NetCDF file checksums also include creation metadata,
so scientific payload comparison is distinct from byte comparison.

## Fortran-to-archive integrity workflow

For each CASA-C, MIMICS-C, CASA-CN, and MIMICS-CN experiment:

1. Verify source, input, output, parameter, run-list, and restart checksums.
2. Identify the exact source commit, compiler configuration, model switches,
   and control files that generated the archive.
3. Reproduce prespin, accelerated spin, normal spin, restart, and historical
   phases in the original order.
4. Compare available restart boundaries.
5. Compare fresh Fortran NetCDF output against the archived NetCDF output.
6. Stop on a provenance/configuration mismatch. Do not compare Julia yet.
7. Only after that gate passes, compare Julia with the fresh Fortran output
   using identical initial states and drivers.

Coordinates, dimensions, masks, and categorical variables match exactly.
Every available finite scientific value is compared. Missing values, NaNs,
infinities, and sign changes cannot be hidden by relative error. Creation
timestamps, history text, compression, chunking, and attribute order are not
scientific differences, but variable names, units, coordinate meaning, and
masks are.

Daily files are the primary transient check and annual files are secondary.
Fortran-versus-archive and Julia-versus-Fortran tolerances are measured and
reported separately.

Archived carbon-only NetCDF histories name control directories that are not
committed or included in the archives. `experiments.toml` therefore records
date-based candidate source commits without claiming they generated the data.
Reconstructing these controls is the next provenance task.

Auditing the two committed CN historical controls found the static grid, PFT,
phenology, soil, perturbation, and MIMICS parameter inputs, but not the spinup
restart states. Git object/history searches found no committed copies of those
restart filenames. The meteorology is present in the verified driver archive
but must be extracted or mapped to the relative path expected by a staged run.
These are explicit integrity blockers, not reasons to substitute a nearby
restart or parameter file.

## CORPSE provenance rule

Zenodo does not contain a complete CORPSE archive. The local
`corpse_pool_flux_2000-2010_mean.nc` may or may not be reproducible by the
currently documented setup.

The bounded investigation is:

1. audit its NetCDF metadata and postprocessing history;
2. reproduce the documented `EXAMPLE_GRID` run, initialization, restarts,
   `corpse_params_12.18d.2017.nml`, and aggregation;
3. try only evidence-supported historical commits/configurations around the
   file creation date;
4. record forcing, spin-up, precision, `ncrcat`, and `cdo -yearmean` effects;
5. log every attempted configuration and comparison result.

If an evidence-supported setup reproduces the old file, it becomes an
additional integration gate. If those attempts are exhausted without a match,
a fresh output from one pinned and fully documented Fortran setup becomes the
authoritative CORPSE reference. The old mean then remains informational. Its
tolerance must not be relaxed to manufacture agreement.

The current one-day probe is an equation-order gate, not a resolution of the
legacy mean. It compiles the pinned `corpse_soil_carbon.f90` directly, reads
the documented namelist, and emits nine cohort states plus daily CO₂. The
Julia `Float32` kernel matches all nine states exactly; daily CO₂ is within
two Float32 ULP because of reduction rounding. The probe writes compiler
flags, versions, checksums, stdout, and metadata to its run directory.

The bounded legacy investigation is now exhausted for the published and local
inputs. The mean uses the older 4,299-cell CLM4.5/CRU-NCEP experiment, but its
1901-2010 meteorology and exact CASA restart are absent. The available
4,263-cell CLM5/GSWP3 archive cannot be substituted. Public Git history also
places the named parameter file and restart after the mean file's creation
date, and the committed historical executable is a Linux x86-64 binary.

The authoritative selected-cell fallback is
`fixtures/selected_corpse/fresh_fortran_1901.nc`. It is regenerated by
`generate_selected_corpse_reference.jl` from pinned Fortran source and the
shared selected-cell forcing, grid, soil, and parameter fixture. Its manifest
records source and input hashes, configuration, and data transformations. The
core, extended, and arbitrary subset collections all pass through the shared
bounded comparison runner. Following the Fortran CASA/CORPSE driver, PFTs 11,
13, 15, and 17 are reported as explicitly skipped ice/water cells.

The complete workflow oracle is
`fixtures/selected_corpse/complete_workflow.nc`, with extraction and run
provenance in `complete_workflow.toml`. It uses the same pinned source,
compiler flags, CASA parameters, CORPSE namelist, and selected GSWP3 fixture
for a 100-year prespin, two 9,980-year spins joined by exact CASA and
cohort-restart handoffs, and the 1901--2014 historical transient. The extended
run contains the core set as an explicit mask, so both collections share one
authoritative execution. The artifact records every CASA boundary and each
rhizosphere/bulk, litter/soil CORPSE cohort component, including cumulative
respiration, original-carbon bookkeeping, and cumulative decomposition.
Per-cell conservation and spin-convergence records and SHA-256 hashes for each
stage's control, inputs, outputs, and log remain in the manifest.

The legacy 2000--2010 mean is not promoted because its exact CRU-NCEP forcing
and CASA/CORPSE restart are unavailable. The complete fresh GSWP3 execution is
therefore the oracle, while the legacy mean remains informational. Regenerate
the resumable workflow with:

```bash
julia --startup-file=no --project=test \
  test/testbed_validation/generate_complete_selected_corpse_reference.jl \
  <biogeochem-testbed-source-root> <run-root> \
  test/testbed_validation/fixtures/selected_corpse
```

Every productive cell uses one forcing series and initial state for both the
LegacyDaily and 900-second ContinuousRate paths. LegacyDaily retains absolute
pool, respiration, final-state, and machine-precision moisture gates.
ContinuousRate reports absolute errors and gates relative pool and respiration
errors at `1e-3` and `1e-2`, respectively, so the same scientific comparison
applies across cells with very different carbon magnitudes. The historical
single-cell fixture in
`fixtures/corpse_c_fresh_cell_11060` remains an audit artifact. The old mean
also remains informational unless its missing inputs are recovered.

## Test architecture

Ordinary package tests do not compile or run Fortran and do not require large
archives. They will include:

- scalar equation, partition, rate, and transfer tests;
- unit and parameter conversion tests;
- instrumented-Fortran one-day golden fixtures;
- standalone initialization, cache, and tendency tests;
- integrated exchange and independent C/N budget tests;
- safeguard and edge-case tests;
- diagnostics, legacy-name mapping, and native restart round trips;
- small grid slices spanning climate, texture, and PFT regimes;
- `Float32`, `Float64`, inference, allocation, and GPU smoke/parity coverage.

Full external validation compiles Fortran, verifies it against archives, runs
Julia with the same inputs and initialization, and reports bias, maximum
absolute and relative errors, failure counts, spatial summaries, and budget
residuals. It should run on CPU and GPU when resources permit.

Fixture selection combines static metadata, driver extremes, and
output-derived behaviors. NetCDF slices retain coordinates, masks, calendars,
units, and original variable names where practical. Extraction performs a
round-trip equality audit against the source before unit conversion. Every
fixture manifest records the source archive and checksum, source commit,
selection script, cells, dates, variables, conversions, and measured tolerance
contract.

### Selected-cell workflow fixture

`fixtures/selected_cells/fixture.toml` publishes one archive-independent
1901–2014 forcing bundle for both fixture tiers. The 11-cell core tier is a
subset of the 37-cell extended tier, so the historical forcing is stored only
once. The core covers productive woody and non-woody vegetation, contrasting
soil-temperature, liquid-moisture, clay, and silt regimes, and the inactive
cell-51 ice/water boundary. The extended tier adds a productive representative
for every active PFT in the source grid and the cells nearest the 0.1, 0.5, and
0.9 empirical quantiles of GPP, soil temperature, liquid moisture, nitrogen
deposition, clay, silt, and porosity. Non-vegetated PFTs 13, 15, and 17 are
excluded from the productive distribution; PFT 17 appears only as the explicit
boundary case.

The fixture retains all daily `xtairk`, `ndep`, `xcgpp`, `xtsoil`, `xmoist`,
and `xfrznmoist` values, coordinates, masks, global cell IDs, selected grid and
soil rows, CASA-C and CASA-CN parameter tables, the MIMICS KO4 table, the
CORPSE namelist, phenology, and perturbation controls. Raw values and storage
types are unchanged; only the scattered longitude/latitude cells are packed
into a single `cell` dimension and the yearly no-leap time dimensions are
concatenated. The manifest records selection reasons and historical means for
every cell, source and fixture hashes, units, dimensions, conversions, code
revision, calendar, per-source and per-file licenses, and both exact extraction
audits. The forcing is CC-BY-4.0; copied testbed repository inputs are MIT.

Load either tier without the source archive:

```julia
include("test/testbed_validation/selected_cell_fixtures.jl")
using .TestbedSelectedCellFixtures

manifest = "test/testbed_validation/fixtures/selected_cells/fixture.toml"
TestbedSelectedCellFixtures.load_selected_cell_fixture(manifest; tier = :core) do fixture
    forcing = fixture.forcing
    core_gpp = forcing["xcgpp"][:, fixture.cell_indices]
end
```

Regenerate it from a verified local copy of the published archive and the
pinned testbed source checkout:

```sh
julia --project=test test/testbed_validation/selected_cell_fixtures.jl build \
    /path/to/data-root /path/to/biogeochem_testbed \
    test/testbed_validation/fixtures/selected_cells
```

The builder verifies the 13 GB archive size and MD5, streams every forcing
member from that archive to prove the extracted NetCDF files are byte-exact,
and checks copied repository inputs against the pinned Git commit. It then
recomputes selection statistics over all 114 years, independently audits
selected source values before packing, and checks the packed fixture against
every source year, coordinate, and mask.

`selected_casa_workflow.jl` runs the carbon-only and carbon-nitrogen fixtures
through the complete pinned prespin, accelerated-spin, passive-restoration,
normal-spin, and 1901–2014 historical schedule. Every phase uses the public
integrated CASA models, ClimaTimeSteppers Forward Euler, and native ClimaLand
checkpoints. Each stage reloads its checkpoint before the next stage; the
carbon-only leaf stoichiometry bookkeeping is deterministically rebuilt from
the restored leaf-carbon state. Reference tests use
`ordinary_cell_collection()` by default. The same CASA comparison accepts
`extended_cell_collection()` or `subset(...)` and a `ConcurrencyBudget`.
Fixture verification, eligibility, resource scopes, timing, deterministic
ordering, and cell-context failure aggregation remain inside
`reference_cell_comparisons.jl`. The package regression uses the extended collection,
compares the complete initialized state and every stage boundary with compact
fresh-Fortran and native-Julia references in `complete_casa_workflow.toml`,
checks early/middle/late historical dates, and reports both stage and
complete-workflow C/N budgets. Regenerate one reference configuration only
from completed native and fresh-Fortran runs:

```sh
julia --project=test \
  test/testbed_validation/generate_selected_casa_workflow_reference.jl \
  carbon_only extended /path/to/native-output /path/to/fresh-fortran \
  test/testbed_validation/fixtures/selected_cells/complete_casa_workflow.toml
```

The CASA-CN reference includes the plant mineral-N supply limit, the parameter
table's P:N interpretation, and CASA's fixed structural-litter C:N ratio of
150. Regenerating the corrected 37-cell reference reduced the largest measured
stage-boundary Julia--fresh-Fortran absolute error from `8.55 kg m^-2` to
`0.00430 kg m^-2`; the regression caps it at `0.005 kg m^-2`. Over the matched
daily windows 1901--1905 and 2010--2014, representative maximum cell NRMSE
values changed as follows:

| Pool | Before, Julia vs archive | Corrected Julia vs Fortran | Corrected Julia vs archive |
| --- | ---: | ---: | ---: |
| Slow soil C | 22.542% | 0.038% | 0.024% |
| Structural litter N | 40.857% | 1.873% | 0.872% |
| Mineral N | 37.569% | 2.762% | 2.478% |

Every pool's across-cell median Julia--Fortran NRMSE is below `0.0013%`. The
remaining `10.722%` maximum for metabolic litter C occurs at cell 923, where
the fresh-Fortran mean stock is only `0.00495 g m^-2`.

`Reproduces the Fortran` means the same pinned equations, ordering, daily map,
parameters, drivers, initialization, restarts, and postprocessing; bitwise
identity across languages is not required. An archive/source discrepancy must
be traced and documented rather than silently resolved in favor of either.

## Diagnostics, restarts, and documentation

Native names and SI units are used internally. ClimaLand diagnostics expose
every prognostic pool and major flux. A separate compatibility mapping supports
legacy names such as `cLITm`, `cMICr`, and `cSOMp`. Legacy CSV, namelist, `.lst`,
and restart parsing remains in reproducibility tooling, while public Julia
simulations use ClimaParams and native ClimaLand restart/output machinery.

Each model requires:

- scientific overview, citations, and an original pool/flux diagram;
- equations in implementation order;
- parameter, prognostic, auxiliary, driver, and coupling tables;
- standalone and integrated tutorials;
- the Forward Euler `LegacyDaily` restriction;
- CPU/GPU, diagnostics, and restart instructions;
- validation results and known limitations.

Repository documentation also needs the reproducibility workflow, provenance,
licensing, full grid reports, API navigation, and an appropriate NEWS entry.
The testbed source is MIT licensed, the Zenodo data are CC BY 4.0, and
ClimaLand is Apache 2.0.

## Milestones and gates

1. **Reference harness.** Pin manifests, verify data, build Fortran, reproduce
   the smallest point case, pass the archive integrity gate for the first
   experiment, generate one-step/grid fixtures, and resolve CORPSE reference
   status.
2. **CASA carbon.** Implement scalar kernels, CASA plant/soil field models,
   `LegacyDaily`, standalone/integrated execution, conservation, fixtures,
   GPU-safe tests, and initial documentation.
3. **MIMICS carbon.** Implement and validate all carbon pools, kinetics,
   protection, turnover, litter/CWD transformations, and CASA coupling.
4. **CORPSE carbon.** Implement the fixed reference cohorts and ordered daily
   map against the selected pinned Fortran reference.
5. **CASA and MIMICS CN.** Add compile-time nitrogen states/processes, mineral N
   ownership, equal-and-opposite uptake, CWD N, and the two CN grid workflows.
   The implementation and CPU/archive gates are complete; CUDA execution is
   pending on a CUDA host.
6. **Native ClimaLand coupling.** Add root-weighted `EnergyHydrology` drivers,
   finalize integrated construction, diagnostics, restarts, legacy mappings,
   and CPU/GPU performance validation. Root-weighted drivers, construction,
   heterogeneous rooting depth, and diagnostics are complete; integrated
   device/performance gates remain.
7. **Full validation and documentation.** Execute gridded comparisons, publish
   quantified error/conservation reports, finish tutorials/API docs, and run
   all repository checks appropriate to the change.

The gate for every physics milestone is one-step agreement, conservation,
measured gridded tolerance, and device-compatible hot paths. Scientific
deviations remain explicit and quantified.
