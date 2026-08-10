# DE-Hai pristine comparison summary

## Result

**FAIL (blocking), captured 2026-08-06T21:27:24Z.** The unchanged local
CLASSIC v2.0 run does not reproduce the published DE-Hai modeled output. No
tolerance, offset, parameter, configuration, or restart adjustment was
applied.

The local run emitted 57 modeled NetCDF files. All were paired with published
files and compared, but only 10 passed exact numerical comparison and 47
failed. The published directory also contains 118 modeled monthly and annual
files that the local workflow did not emit. Issue #97 cannot be completed
until the missing output cadences and numerical discrepancies are explained.

## Inventory

| Evidence | Published | Local | Compared |
| --- | ---: | ---: | ---: |
| Daily modeled files | 56 | 56 | 56 |
| Monthly modeled files | 63 | 0 | 0 |
| Annual modeled files | 55 | 0 | 0 |
| Static modeled files | 1 | 1 | 1 |
| Total modeled files | 175 | 57 | 57 |

The published `rsFile_modified.nc` is a CLASSIC initialization/restart file,
not modeled output. It is explicitly reported as an excluded non-modeled file.
There are 118 reference-only modeled files and no candidate-only modeled
files; the full reference-only inventory is in the external report.

## Overlap

All 56 paired daily files cover the complete raw time-coordinate overlap from
day `1` through day `4749`, inclusive: 4,749 records using `days since
1999-12-31 00:00` and the `standard` calendar. The paired static `sftlf.nc`
has no time dimension and compares one record.

Dimensions, dimension order, coordinate values, units, calendars, element
types, `_FillValue`, `missing_value`, and missing-value masks have zero
mismatches across all 57 paired files. Coordinate numerical comparisons also
have zero failures.

## Numerical differences

Ten files pass exactly: `huss_daily.nc`, `mrroi_daily.nc`, `pr_daily.nc`,
`ps_daily.nc`, `rlds_daily.nc`, `rsds_daily.nc`, `sftlf.nc`, `tas_daily.nc`,
`uvas_daily.nc`, and `wtd_daily.nc`.

The other 47 files contain 292,012 differing modeled values. The global
maximum relative difference is infinite where the published value is zero.
The largest absolute differences are:

| File | Failed values | Maximum absolute difference |
| --- | ---: | ---: |
| `snwdens_daily.nc` | 1,800 | 366.8433439262768 |
| `tsn_daily.nc` | 1,460 | 250.3966666666666 |
| `mrsfl_daily.nc` | 1,957 | 46.42334521471468 |
| `mrsll_daily.nc` | 23,581 | 41.88418518267018 |
| `hfls_daily.nc` | 4,749 | 31.440821119675114 |

The external report records every failed value count, maximum absolute and
relative difference, and first failing index.

## Evidence

Paths:

- Published NetCDF: `/work/yinonmb/classic-v2-reference/replaceable/extracted/issue-97-de-hai-pristine/published/Benchmark_CLASSIC_output/DE-Hai/netCDF`
- Local NetCDF: `/work/yinonmb/classic-v2-reference/replaceable/runs/issue-97-de-hai-pristine/outputFiles/DE-Hai/netCDF`
- Full comparison report: `/work/yinonmb/classic-v2-reference/replaceable/runs/issue-97-de-hai-pristine/comparison-report.txt`
- Run receipt: `/work/yinonmb/classic-v2-reference/replaceable/runs/issue-97-de-hai-pristine/receipt.txt`

SHA-256:

| Evidence | SHA-256 |
| --- | --- |
| Published benchmark archive | `a2a9f33c4472610cb95c567367e6a633cdf35e3101fb89176ca0eee4138336e2` |
| Full comparison report | `95cc5dec447e26f49d04ed687e9423497f158c3f0f9a6999d3dd0866c944fee3` |
| Local output hash manifest | `77874d88c3c7d28b045f56814a412b9b76ebb562f8b4645094438fb459aa1a89` |
| Run receipt | `66c580626311ed46bc15b6f6b6992b8ae43fb1db1d84be1eba6d97ea52e0d277` |
| Comparison tool | `c2e39abee19a0606e6d7fbf06ab7d495672d8a245d3e13fe1765126e1bda7bf6` |

The published benchmark archive also matches its recorded MD5,
`fb0d8c57e7b926644bf0b9fcdf079a2c`.
