---
status: accepted
---

# Own soil state and prescribe external transfers

The standalone translation owns and evolves every state within its selected soil-biogeochemistry scope after initialization. Values and transfers produced by vegetation, mortality, disturbance, fire, competition, land use, and other processes outside that boundary enter as prescribed [forcing](../../CONTEXT.md), recorded at their actual application point; they never replace translated soil state.

## Consequences

Validation keeps [call snapshots](../../CONTEXT.md) separate from [trajectory forcing](../../CONTEXT.md): snapshots isolate individual transitions with complete pre- and post-step states, while trajectory forcing initializes internal state once and then lets the translation evolve it without replacement by later Fortran state.

PFT, bare-ground, tile, and layer distinctions remain visible across the boundary. Land-use product pools stay external even when they share a decay calculation with soil processes, and living-moss production remains an external transfer while moss litter and moss-derived soil carbon belong to C scope.
