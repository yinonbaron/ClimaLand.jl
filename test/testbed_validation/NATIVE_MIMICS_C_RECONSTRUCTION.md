# Native MIMICS-C reconstruction

`native_mimics_c_reconstruction.jl` implements issue 29 as the three-stage
native ClimaLand workflow selected by the issue-23 Fortran investigation:

1. 100 repeats of the 1901 prespin forcing.
2. 499 repeats of the 1901–1920 forcing cycle.
3. The transient 1901–2014 historical forcing.

The 4,263 grid rows remain in pinned CSV order, and every stage hands its
complete prognostic state to the next stage through a native ClimaLand
checkpoint. The plant uses `pftlookup_igbp_updated4.csv`; the soil uses the
pre-Q10 KO4 `pftlookup_LIDET-MIM-REV_CN_desorb2xKO4_micCN_FI30.csv` table.
The runner reads the KO4 litter-quality coefficients rather than substituting
the later CASA-C exudation tables. Annual NPP is initialized from half of
forced GPP at each standalone stage boundary and thereafter comes from the
preceding native year, matching the Fortran driver.

Run from the repository root:

```sh
julia --startup-file=no --project=test \
  test/testbed_validation/native_mimics_c_reconstruction.jl \
  ../biogeochem_testbed \
  ../INPUT_GSWP3_CLM5dev110_hist \
  ../mimics_c_reconstruction_issue23/archive_predecessor \
  ../native_mimics_c_reconstruction_issue29
```

The output contains a checkpoint and manifest for prespin, spin, and history,
the full native historical state and diagnostic stream, and
`reconstruction_report.toml`. The report compares CASA labile and plant
carbon, CWD, and all seven MIMICS pools at every stage boundary. Historical
annual means cover 1901–2014; daily comparisons cover 1901–1905 and
2010–2014 against both the fresh Fortran run and the published archive.

The following process coverage is explicit in the report and native output:

- respiration;
- metabolic and structural litter inputs;
- r- and K-strategist microbial turnover;
- physical and chemical protection;
- desorption and oxidation; and
- CWD transfer to structural litter.

The standalone MIMICS tests independently check the formulas, units, and slot
ordering of every process diagnostic in both floating-point precisions. The
Fortran NetCDF directly exposes respiration, litter inputs, and physical
protection; the other internal hourly fluxes are retained natively and are
constrained by the boundary and historical pool comparisons because the
archived files do not contain them. The carbon-budget table records
area-weighted initial and final stocks, GPP, autotrophic and labile losses,
heterotrophic plus CWD respiration, and the residual for every stage. Fresh
Fortran and published-archive comparisons have separate metric trees and
separate tolerance fields; a difference in one is never reclassified through
the other.

The automated acceptance test exercises the same public `run_case` seam with
two points and short versions of all three stages. The command above is the
multi-day scientific acceptance run and remains outside CI.
