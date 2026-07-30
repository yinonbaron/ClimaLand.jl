# CASA-CN Representative validation

The regular CASA-CN CI comparison runs all 80 cells in the immutable
Representative scope against a model-specific pinned artifact. It reuses the
same forcing and scope manifest as CASA-C while keeping the CASA-CN oracle,
policy, calibration, and report namespace independent.

## Scientific comparison

The pinned oracle retains all four fresh-Fortran C/N stage boundaries and
variable-aware 1901--2014 annual summaries. State pools use annual means;
their pinned native-Julia regression companion also retains end-of-year
values. Fluxes use annual totals. Carbon and nitrogen budgets report their
maximum absolute residuals. Fixed daily regression samples retain seven days
from January, April, July, and October in 1901, 1957, and 2014: 84 samples per
variable and cell. Fresh Fortran supplies and empirically calibrates the 56
retained requested samples in 1901 and 2014 over all 4,263 cells. Its archive
does not retain 1957 daily states; those 28 samples are explicitly native-only
under the reviewed `fresh_fortran_fixed_daily` time-window gap until the fresh
mode runs statefully through 1957 and replaces the pinned oracle.

Fresh-Fortran boundary, annual, and retained-daily tolerances are mixed
absolute-relative
envelopes calibrated against the current Julia implementation over all 4,263
cells. Boundary rules cover 20 C/N pools at four workflow boundaries. Annual
rules cover every valid state and flux over 114 years; daily rules cover
238,728 day-cell pairs per valid variable. The calibration
manifest records the exact Julia and Fortran inputs, execution source hashes,
single-thread execution contract, distributions, leading outliers, active
constraints, and the derived policy.

`nLitInptStruc` is the sole variable-level invalid-oracle gap. The audited
Fortran implementation adds an uninitialized `nwd2str` work array to that
diagnostic, so it is excluded only from fresh-Fortran comparisons. It is not a
cell exclusion and does not weaken comparisons for other variables. The
initialized Julia diagnostic remains covered by the pinned native-Julia daily
regression. Every other missing or nonfinite value in an eligible cell fails
validation.

Completion of stable integration in #57 remains blocked on fresh generation
and publication in #54 and #55 producing all 84 fresh daily samples and
empirical rules, including 1957.

## Running the comparison

```sh
julia --project=test test/testbed_validation/validation_runner.jl \
    --scope representative --models CASA-CN --reference pinned --workers 1
```

The public runner resolves the reduced forcing and reference exclusively from
their Julia artifact bindings. Pinned mode never falls back to running
Fortran. Each compact reference records the exact forcing artifact tree hash,
and the runner rejects cross-artifact combinations before simulation. It runs
in a supervised process with a hard 7,200-second deadline and records scope
coverage, Eligibility Gaps, policy and artifact provenance, annual reducers,
fixed daily samples, carbon and nitrogen budgets, scientific checks, and
timing in `validation_report.toml`.
