# CLASSIC v2.0 benchmark-production provenance

Research date: 2026-08-07

## Bottom line

The exact production bundle for the CLASSIC v2.0 CBC outputs cannot be
reconstructed from the three published Zenodo records or the public GitLab
history. The public material supplies the released source, dependency
container, site inputs, meteorological forcing, published outputs, and a
terminal restart for each site. It does **not** supply the production job
options, generated parameter namelist, starting restart, executable, compiler
log, or source commit recorded by the executable.

There is also direct evidence that the published CBC outputs were not made by
the released quick-start procedure without modification:

- the DE-Hai outputs contain daily, monthly, and annual streams and retain
  `Comment = " test"`;
- the public `prep_jobopts.sh` has forced daily-only output since August 2022;
- the same helper has replaced the template comment with a dated run comment
  since June 2025; and
- the DE-Hai output files record a creation timestamp about 13 hours before the
  final `CLASSICv2.0` tag commit.

The most efficient route to exact recovery is therefore a focused provenance
request to the CBC record creators, not further parameter guessing. An
unchanged run at AU-Tum reproduces the DE-Hai failure pattern: all ten forcing
pass-through variables agree exactly, while the same 47 modeled variables fail
and 33 already differ at the first record. This implicates shared production
configuration, initialization, or binary provenance rather than a DE-Hai-only
problem.

## Verified facts

### Official records and retained artifacts

The source record contains one 13.6 MB archive and identifies release 2.0 and
the official repository. The public tag resolves to commit
`7dd82c9a48a7c8beb6455a229888c90ba20d8eff`.
([source record](https://zenodo.org/records/18188101),
[tag](https://gitlab.com/cccma/classic/-/tags/CLASSICv2.0),
[commit](https://gitlab.com/cccma/classic/-/commit/7dd82c9a48a7c8beb6455a229888c90ba20d8eff))

The current container API record is revision 6 and contains only
`CLASSIC_container.tar.gz`, size 1,716,454,680 bytes, MD5
`5510acc8ba800aa3ff716683ab8304b7`. The local immutable archive has the same
size and MD5. The quick-start guide instructs the user to compile the checked
out source with `make mode=serial`; it does not provide the executable that
produced the benchmark.
([container API](https://zenodo.org/api/records/18201505),
[container record and quick-start guide](https://zenodo.org/records/18201505))

The CBC dataset record contains exactly three files: forcing/observations,
published outputs, and plots. Its file inventory contains no job-options file,
generated `model_params.nml`, build log, executable, source receipt, or initial
checkpoint. The record says that following the quick-start guide will generate
the model outputs, but it does not identify the commit or production command
used for the deposited outputs.
([CBC API](https://zenodo.org/api/records/18202323),
[CBC record](https://zenodo.org/records/18202323))

An exhaustive filename search of the three locally verified CBC archives found
only modeled output/plot/forcing products. `Benchmark_CLASSIC_output.tar.gz`
contains `rsFile_modified.nc` for each published site, but no job or parameter
files. For DE-Hai, comparison with the final modeled day and the documented
overwrite behavior identifies this as the end-of-run restart, not the missing
initial state. Its global attributes preserve `creation_date = "20241115"`,
which is also present in the released DE-Hai CDL and therefore is not a
production-run timestamp.

### The published configuration fingerprint differs from quick start

The tagged job-options template enables monthly and annual output, leaves daily
output disabled by default, and contains `Comment = ' test '`. The tagged
preparation helper then explicitly enables daily output, disables monthly and
annual output, and replaces the comment with the execution date, N-cycle flag,
and HPC flag.
([tagged template](https://gitlab.com/cccma/classic/-/blob/CLASSICv2.0/configurationFiles/template_job_options_file.txt),
[tagged preparation helper](https://gitlab.com/cccma/classic/-/blob/CLASSICv2.0/tools/siteLevelFLUXNET/prep_jobopts.sh))

The deposited DE-Hai NetCDF inventory has all three cadences, and its global
attributes contain `Comment = " test"`. This is a positive fingerprint of the
template settings and a negative fingerprint of the released preparation
helper. It does not reveal the other job-option values because CLASSIC does not
serialize them into the output metadata.

Git history dates the daily-only override to commit
`b785f64d86462ff0509a0709b4280d8b821a002c` on 2022-08-23; immediately before
that commit, `prep_jobopts.sh` inherited the template's output frequencies.
The dated-comment rewrite was added in commit
`4d4da69764f423e2aae047812119668810f58c19` on 2025-06-04. Thus an older public
helper can explain the output/comment *shape*, but code from 2022 is not by
itself evidence of the source used to make the 2026 v2.0 output. The more
likely explanation is a stale production run directory, a private/internal
helper, or manual job-options editing.
([daily-only commit](https://gitlab.com/cccma/classic/-/commit/b785f64d86462ff0509a0709b4280d8b821a002c),
[comment-rewrite commit](https://gitlab.com/cccma/classic/-/commit/4d4da69764f423e2aae047812119668810f58c19))

### The outputs predate the final release tag

The DE-Hai daily files record `timestamp = "20260107 0419"` and
`Comment = " test"`. The final tag commit is timestamped
2026-01-07 17:23:49 UTC. The output timestamp is therefore approximately 13
hours earlier than the tagged commit. Commit
`d128b021a029c3befca9294a80136c12e446742e` existed by 2026-01-05 22:57 UTC and
is the last public pre-release merge before the output timestamp. A later
2026-01-07 17:08 commit changed CBC documentation, not model code.
([pre-output merge](https://gitlab.com/cccma/classic/-/commit/d128b021a029c3befca9294a80136c12e446742e),
[documentation commit](https://gitlab.com/cccma/classic/-/commit/b9793200655e9b4ef98f1acffdb666a059da2d0b),
[release commit](https://gitlab.com/cccma/classic/-/commit/7dd82c9a48a7c8beb6455a229888c90ba20d8eff))

This timing proves that the benchmark executable was not compiled from the
later final tag commit as such. It does **not** prove that the executable came
from `d128b021...`: the NetCDF files contain no source hash, and the production
host clock/time-zone and any unpushed internal changes are not recorded.

## Strong inferences

1. **A non-released production job configuration was used.** The combination
   of all three output cadences and an untouched template comment is
   incompatible with the released helper. This is stronger than inference
   from numerical differences alone.
2. **A stale or separately spun dynamic starting state remains the leading
   explanation for DE-Hai.** Meteorological outputs agree exactly, while
   physical state differences occur in the first modeled record. Shared static
   fields agree. That pattern is more consistent with a different initial
   dynamic state than with forcing ingestion.
3. **The production source was probably a pre-release v2 checkout available on
   2026-01-07, but its exact commit is unknowable from the deposits.** The
   public `d128b021...` commit is a concrete candidate, not a verified pin.
4. **The generated parameter namelist may also have come from an older run
   directory.** Production output retained other template-era characteristics;
   no hash or copy of `model_params.nml` is embedded, so equality with the
   current generator output cannot be established.

## Artifacts that remain unavailable

The following were not found in Zenodo metadata, any deposited archive,
published NetCDF attributes, the public GitLab issues, or public repository
history:

- exact production `job_options_file.txt` for DE-Hai (preferably all sites);
- exact generated `model_params.nml` and the JSON input/hash used to make it;
- the **initial** production restart/checkpoint and its role in any spin-up
  chain;
- complete spin-up recipe: source commit, forcing years/order, cycle count,
  stopping criterion, and intermediate restart hashes;
- source commit and dirty-tree diff used to build the production executable;
- production `CLASSIC_serial` binary or its SHA-256;
- compiler/linker versions, flags, `make` invocation, and full build log;
- the run command, environment/module/container receipt, and stdout/stderr;
- an output manifest connecting each deposited site to those artifacts.

## Recommended provenance request

Open a public issue in the
[official CLASSIC tracker](https://gitlab.com/cccma/classic/-/issues/new), link
Zenodo record 18202323 and the reproducibility comparison, and ask the CBC
creators for the following **exact files rather than reconstructed settings**:

1. DE-Hai production `job_options_file.txt` and `model_params.nml`.
2. The restart read at the beginning of the deposited 2000--2012 simulation,
   plus a note stating whether it was produced by spin-up and the complete
   spin-up command chain.
3. `git rev-parse HEAD`, `git status --porcelain`, and a patch for any local
   modifications at build time.
4. SHA-256 of the executable; preferably the executable itself if licensing
   permits.
5. Full build command/log with compiler, NetCDF libraries, flags, and container
   image SHA-256.
6. Exact run command and environment/module/container invocation.
7. A SHA-256 manifest for the above and for the deposited DE-Hai outputs.
8. Whether the benchmark was intentionally produced before the final
   `CLASSICv2.0` tag, and which pre-release commit should be treated as the
   oracle.

The Zenodo record lists Gesa Meyer, Joe R. Melton, Salvatore Curasi, and Jade
Skye as CBC creators, with ORCID identifiers in the
[official API metadata](https://zenodo.org/api/records/18202323). The public
repository's release commit also supplies a first-party maintainer route. A
public tracker issue is preferable because the answer then becomes part of the
model's reproducibility record.

## Second-site result

The unchanged released workflow was run for AU-Tum (2001--2014) and compared
with the deposited AU-Tum output using the same exact comparator. Of the 57
paired variables, the same ten forcing pass-through variables pass exactly and
the same 47 modeled variables fail; 118 deposited monthly/annual variables are
absent from the released workflow's daily-only output. Thirty-three modeled
variables differ at their first time record.

This rules out a DE-Hai-only site configuration problem. It focuses the
provenance request on the shared production job options, parameter namelist,
initialization/spin-up procedure, source checkout, and binary. The experiment
localizes the problem but cannot replace the missing production receipts;
exact parity still requires the artifacts listed above.
