---
status: accepted
---

# Deliver CLASSIC capabilities in B, C, D order

Deliver the standalone translation as one composable soil-biogeochemistry capability that expands from [B scope](../../CONTEXT.md) to C scope and then D scope. Each scope must reach component parity before work proceeds to the next, because adding specialized carbon, nutrients, methane, or tracers before mineral-carbon parity would make scientific mismatches harder to isolate. The translation preserves the CLASSIC daily discrete ordering, native vertical semantics, and exact Float64 operation order so redesign is not conflated with translation.

## Consequences

B covers mineral-soil carbon, C adds complete soil carbon, and D adds D1 coupled nitrogen, D2 methane, and D3 Simple and carbon-14 tracers. Carbon-13 fractionation, continuous-time redesign, and vertical-grid remapping are not part of this progression.

After exact Float64 parity was established, the B implementation added a Float32 path and a model-owned allocation-free callback cache. These are implementation-quality extensions rather than new scientific capabilities: Float64 remains gated bit for bit against the v5 local oracle, and both precisions share the same source-ordered equations.

Automatic differentiation is explicitly deferred. Stage B is a discrete, mutating daily transition with source-compatible clamps, guards, and cache reuse; forcing `ForwardDiff.Dual` through its `AbstractFloat` containers would broaden the numerical contract without an agreed differentiation seam or derivative oracle. A future AD capability requires a separate decision that defines the differentiated inputs and outputs, nondifferentiable-boundary behavior, and independent derivative validation while retaining exact Float64 parity.
