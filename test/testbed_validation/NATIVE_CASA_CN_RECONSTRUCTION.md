# Native CASA-CN reconstruction

`native_casa_cn_reconstruction.jl` implements issue 30 as a four-stage,
4,263-cell native ClimaLand run using the setup established by issue 24:

1. 100 repeats of 1901 with the derived boreal-N-fix prespin table.
2. 499 repeats of 1901--1920 with the accelerated table.
3. Passive carbon and passive nitrogen are both multiplied by 10, then 499
   repeats of 1901--1920 use the normal table.
4. The complete 1901--2014 historical forcing.

The workflow reads GPP, temperature, moisture, and nitrogen deposition lazily
from the original yearly GSWP3/CLM5 files. CASA soil owns the only prognostic
mineral-N stock (`casa_soil.n_mineral`). Root exudation is required to be zero
in the normal and accelerated tables, while CWD carbon and nitrogen remain
explicit pools and bookkeeping inputs. Every stage hands its complete C/N
state to the next through a native ClimaLand checkpoint.
Each boundary comparison also checks the final Fortran reporting year’s C/N
balance accumulators from `casa_flux_final.csv`.

Run from the repository root:

```sh
julia --startup-file=no --project=test \
  test/testbed_validation/native_casa_cn_reconstruction.jl \
  ../biogeochem_testbed \
  ../INPUT_GSWP3_CLM5dev110_hist \
  ../casa_cn_reconstruction_issue24/archive_predecessor \
  ../native_casa_cn_reconstruction_issue30
```

The CASA-CN Fortran reconstruction runner now writes separately reduced fresh
products under `fresh_reference/`: the 1901--2014 annual file and links to the
retained yearly files for 1901--1905 and 2010--2014. The native runner accepts
these yearly files or the previously supported combined-window files. Keeping
fresh products separate from `reference/` prevents archive postprocessing
differences from being attributed to the Julia model.

`reconstruction_report.toml` records all plant C/N states, organic C/N pools,
mineral N and its deposition, fixation, uptake, mineralization,
immobilization, leaching, and gaseous-loss bookkeeping, plus carbon and
nitrogen budgets. Fresh-Fortran and published-archive errors and tolerances
are stored in separate report namespaces. The native historical stream uses
Float32 NetCDF with light deflation; model integration and checkpoints remain
Float64. The command fails if exudation is nonzero, a comparison fails, or an
aggregate carbon or nitrogen budget does not close.

The full Julia reconstruction passes scientific validation when the
`nLitInptStruc` comparison failure is treated as a documented invalid oracle.
The pinned Fortran `casa_delsoil` diagnostic increments its local `nwd2str`
work array without initializing or resetting it; fresh runs therefore produce
nonfinite and extreme compiler-dependent values, while the published archive
happens to remain finite. Julia instead sums initialized structural-litter and
CWD nitrogen inputs. The report retains the failed raw comparison for
provenance, but the independent state, flux, and budget comparisons determine
parity. See [`CN_REFERENCE_AUDIT.md`](CN_REFERENCE_AUDIT.md) for the
source-level audit.

The automated acceptance case uses the same public four-stage handoff with a
small pinned fixture. The multi-hour full-grid scientific run remains outside
ordinary package tests.
