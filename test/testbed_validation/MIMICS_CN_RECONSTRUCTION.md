# MIMICS-CN archive reconstruction

`mimics_cn_reconstruction.jl` implements the complete 4,263-point MIMICS
carbon-nitrogen CLM5/GSWP3 reconstruction chain for issue 25. Large drivers,
archive members, build products, and model outputs remain outside this
repository.

The bounded matrix in `mimics_cn_reconstruction.toml` selects source revision
`82c57f8aa1179865d9752b617493ef06f45c3266`, the latest public revision before
the archive was created. It derives the documented boreal-N-fix CASA and
KO6/FI30 MIMICS prespin candidates, then uses the hash-pinned exudate-zero CASA
and KO4/FI30 MIMICS tables for both long spins and history. FI10 and FI05
prespin alternatives are excluded because the archive records FI30; the
post-archive source revision is excluded by date.

The generated workflow contains four stages:

1. 100 repeats of the 1901 prespin forcing.
2. 499 repeats of 1901--1920 with the normal KO4/FI30 parameters.
3. A second 499-repeat 1901--1920 spin initialized from both paired restarts.
4. The complete 1901--2014 historical forcing.

Run the bounded, resumable search from the ClimaLand checkout:

```sh
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/mimics_cn_reconstruction.jl search \
  ../biogeochem_testbed .. ../mimics_cn_reconstruction_issue25
```

The workflow hashes both CASA plant and MIMICS organic-pool restarts at every
stage boundary. The last two equivalent 20-year endpoints of each long spin
produce separate carbon, organic-nitrogen, and mineral-nitrogen convergence
records. Only the published carbon convergence thresholds are applied; the
runner does not invent nitrogen thresholds. Organic-N and mineral-N changes
receive an explicit `reported_without_published_threshold` assessment, and a
case cannot be labelled matching unless both assessments are present.

Exact comparisons use zero absolute and relative tolerance. They cover both
CASA and MIMICS annual histories for 1901--2014 and both published daily
windows, 1901--1905 and 2010--2014. Named scientific groups require plant C/N,
all organic C/N pools, working DIN, plant uptake, gross and net
mineralization, immobilization, leaching and gaseous losses, respiration,
overflow, litter inputs, and archived environmental drivers. Root exudation
is audited as zero in the CASA parameter table because the archive has no
separate exudation variable.

Historical daily files are reduced and compared as soon as the following year
opens. Each annual and retained-daily comparison fragment is written
atomically before the raw yearly files are removed, keeping the complete
history within bounded local storage. Completed stages are reused only when
their executable, control, inputs, and declared output hashes still match.

If execution completed but reporting was interrupted, regenerate the report
without rerunning the model:

```sh
julia --startup-file=no --project=.buildkite \
  test/testbed_validation/mimics_cn_reconstruction.jl report-case \
  .. ../mimics_cn_reconstruction_issue25 archive_predecessor_ko6_fi30
```

## Current execution status

The production search has not completed on the current macOS ARM host, so no
matching setup or exhausted-matrix result is claimed. The source-exact GNU
Fortran 16.1.0 run completed the 100-year prespin in 517.05 seconds. Its CASA
and MIMICS restart SHA-256 values are respectively
`656a341ce5ff16f3119458ce55226e457e36e744b3a82a88cbfff354e2325a55` and
`7f56eb039bd81d1cb0d5553b94ec9ef1eafada20d89046f4f450c49ed489ef22`.

A controlled 20-year full-grid spin took 137.70 seconds, projecting roughly
19 hours for each required 9,980-year spin and 38 hours for both before the
historical comparison. Ordinary `-O3` compilation took 137.83 seconds and
provided no speedup. Compiler automatic loop parallelization was slower than
serial. An explicit eight-thread outer-grid loop took 68.00 seconds and kept
the prognostic MIMICS restart exact, but changed CASA carbon-balance fields and
the archived respiration diagnostic; it is therefore rejected.

The remaining execution blockers are the approximately 38-hour serial spin
cost and the unpublished archive compiler. GNU Fortran 8.1.0, named by the
legacy source Makefile, is unavailable on this host. The evidence matrix,
workflow, comparisons, and tolerances are pinned; the final result must come
from an uninterrupted production search rather than tolerance inflation or a
diagnostic-changing acceleration.
