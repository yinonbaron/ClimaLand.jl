# CLASSIC Soil Biogeochemistry Translation

This context defines the language used to reproduce and translate CLASSIC soil biogeochemistry into ClimaLand while retaining a traceable scientific comparison with the upstream model.

## Language

**CLASSIC**:
The Canadian Land Surface Scheme including Biogeochemical Cycles, with CLASSIC v2.0 as the upstream scientific reference for this translation.
_Avoid_: JSBACH, CLASS

**Fortran oracle**:
The pinned, unmodified scientific calculations from CLASSIC v2.0 against which the Julia translation is evaluated.
_Avoid_: Ground truth

**Reference simulation**:
A reproducible execution of the Fortran oracle from a specified initial condition, site configuration, and external forcing.
_Avoid_: Benchmark

**Forcing**:
The complete time-indexed values entering the chosen soil-biogeochemistry boundary from outside that boundary. Soil-biogeochemical state evolved within the boundary is not forcing.
_Avoid_: Meteorological forcing, input data

**Call snapshot**:
A record of one transition containing the complete pre-step soil-biogeochemical state, the forcing applied during that step, audit diagnostics, and the complete post-step state.
_Avoid_: Fixture, trajectory

**Trajectory forcing**:
The initial soil-biogeochemical state, recorded once, followed by the chronological forcing needed to evolve it. Later internal states from the Fortran oracle are comparison evidence, not trajectory forcing.
_Avoid_: State replay, reference trajectory

**Standalone translation**:
The Julia realization of the chosen CLASSIC soil-biogeochemistry boundary that can evolve from prescribed forcing without the rest of CLASSIC or an integrated ClimaLand model.
_Avoid_: CLASSIC emulator

**Component parity**:
Agreement between Fortran oracle and Julia trajectories for the state, fluxes, and conservation budgets owned by the chosen soil-biogeochemistry boundary under identical initial state and forcing.
_Avoid_: Bitwise identity, final-state agreement

**B scope**:
The mineral-soil carbon capability covering PFT and bare-ground litter and soil organic matter, respiration, humification, state evolution, and vertical carbon movement. Land-use product pools remain outside this scope.
_Avoid_: Basic scope, carbon-lite

**C scope**:
The complete soil-carbon capability: B scope plus peat, moss litter, moss-derived soil carbon, and specialized soil-carbon pathways. Living-moss production enters this scope as forcing.
_Avoid_: Peat scope, moss scope

**D scope**:
The complete soil-biogeochemistry capability: C scope plus D1 coupled nitrogen, D2 methane, and D3 Simple and carbon-14 tracers. Carbon-13 fractionation is excluded.
_Avoid_: Nutrient scope, tracer scope
