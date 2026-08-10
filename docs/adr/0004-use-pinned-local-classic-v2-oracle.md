---
status: accepted
---

# Use a pinned local CLASSIC v2.0 execution as the translation oracle

Julia translation parity is measured against a fresh local Fortran execution
built from the verified CLASSIC v2.0 source, container, and released site
inputs. The published benchmarking output remains an independent external
reference because the unchanged Quick Start does not reproduce it and its
production configuration and initial dynamic state are unavailable.

## Consequences

Every local oracle generation records the source archive, tag and commit,
container image, executable and toolchain, forcing, initialization, generated
job options and parameter namelist, commands, logs, and output hashes. A new
generation creates a new versioned oracle rather than overwriting prior
evidence.

Call snapshots and trajectory bundles come from an instrumented copy of the
pinned local execution. Instrumentation is accepted only when ordinary model
output still matches the corresponding uninstrumented local oracle under the
declared comparison policy.

Local-oracle parity may unblock translation work, but it does not establish
published-benchmark parity. The issue #97 mismatch and all-site published
comparisons remain visible until the missing production provenance is obtained
or the benchmark is corrected upstream.
