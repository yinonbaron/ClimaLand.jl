# CLASSIC v2.0 Stage B mineral-soil carbon boundary

This note is the authoritative scientific cut for issue #100. It maps the
daily CLASSIC v2.0 mineral-soil carbon transition that the standalone Julia
translation must reproduce. It is a source trace, not a redesign: operator
order, native PFT and layer indexing, one-day stepping, and Float64 arithmetic
are preserved.

The authority is the verified CLASSIC v2.0 source archive from Zenodo record
18188101, tag `CLASSICv2.0`, commit
`7dd82c9a48a7c8beb6455a229888c90ba20d8eff`. The translation oracle is the
pinned **fresh local Fortran execution** described by
[`docs/adr/0004-use-pinned-local-classic-v2-oracle.md`](../../adr/0004-use-pinned-local-classic-v2-oracle.md).
The published CBC files remain independent mismatch evidence; they are not the
numerical authority for this boundary.

## Scientific cut

Stage B owns and evolves, after initialization:

- mineral-soil litter carbon, `litrmass(tile, pft_or_bare, layer)`; and
- mineral-soil organic carbon, `soilcmas(tile, pft_or_bare, layer)`.

The owned category index is `1:iccp1`: `1:icc` are CTEM PFTs and `iccp1` is
bare ground. The `iccp2` slot is the land-use paper/furniture product pool. It
is packed into the same Fortran arrays but remains outside Stage B ownership.
Peat, moss, nitrogen, methane, and tracer state are C- or D-scope and are also
outside this cut.

Vegetation, competition, land use, timber harvest, mortality, and disturbance
remain external. Their effects on owned pools enter as signed transfers at the
same points at which the Fortran driver applies them. The Julia trajectory is
initialized from Fortran once and then evolves its own pools; later Fortran
pool values are comparison-only reference state.

## Complete daily transition

The transition consumes physics accumulated over the preceding day and runs
when `ncount == nday`. The ordered mineral-carbon transition is:

| Order | CLASSIC v2.0 operation | Stage B treatment |
|---:|---|---|
| 0 | Enter `ctemDriver` with the preceding post-step pools | Owned pre-step state |
| 1 | `competition` when enabled | Apply separately recorded signed litter and SOM transfers; update prescribed cover |
| 2 | `luc` when enabled | Apply separately recorded signed litter and SOM transfers; update prescribed cover; keep product pools external |
| 3 | `harvestTile` when enabled | Apply separately recorded signed litter and SOM transfers |
| 4 | Compute `fc = sum(fcancmx)` and `fg = 1 - fc` | External cover forcing at the respiration application point |
| 5 | `heterotrophicRespiration` | Owned mineral litter/SOM respiration kernel; no pool mutation |
| 6 | `updatePoolsHetResp` | Owned respiration loss, litter-to-SOM humification, pool mutation, and nonnegative clamp |
| 7 | `calcNEP`, methane, allocation, and vegetation growth | External or diagnostic; no Stage B pool mutation |
| 8 | `updatePoolsTurnover` | Apply current-day reproduction, leaf/stem litter, and layered root-litter transfer |
| 9 | `updatePoolsMortality` when competition is off | Apply mortality litter transfer; competition handles its own corresponding redistribution when on |
| 10 | `disturbance` | Apply the signed fire/disturbance litter transfer, including litter combustion loss |
| 11 | `calcNBP` | Audit only; no Stage B pool mutation |
| 12 | `turbation` when enabled | Owned vertical movement for PFT and bare pools only |
| 13 | `prepBalanceC` and `balcar` | Audit only; no Stage B pool mutation |
| 14 | Leave Stage B | Owned post-step state; the recorded Fortran copy is reference state |

This ordering has two important consequences:

1. Competition, land-use, and timber-harvest changes can affect respiration on
   the same day because they occur before `heterotrophicRespiration`.
2. Current-day vegetation, mortality, and disturbance litter changes occur
   after respiration. They can be vertically redistributed by same-day
   turbation, but they first affect respiration on the following daily call.

The external transfers must not be collapsed into a single start-of-step
forcing. Keeping their application points is necessary for one-step and
trajectory parity.

## Role rules for snapshots and trajectories

Every dynamic value crossing this boundary has one of four roles:

- **Owned state**: the Julia model's live `litrmass` and `soilcmas` values.
- **External forcing**: a time-indexed physical value, cover, active-layer
  value, root-respiration value, or signed external pool transfer.
- **Reference state**: a recorded Fortran pool value after an intermediate or
  final transition, used only on the comparison side.
- **Audit diagnostic**: a computed flux, scalar, intermediate, aggregation, or
  conservation residual that is never fed back as trajectory forcing.

In a Fortran call snapshot, the input pool arrays describe owned state at that
instant and the serialized intermediate/post arrays are reference state. In
the Julia model, those same post-transition arrays remain owned state. This
artifact-level distinction prevents a validator from accidentally replacing a
free-running Julia state with a later Fortran state.

The complete field-by-field classification is in
[`interface_inventory.md`](interface_inventory.md). Source locations,
equations, and exact parameter provenance are in
[`source_trace.md`](source_trace.md).

## Explicit ownership of external processes

| Process | Fortran behavior | Standalone Stage B contract |
|---|---|---|
| Vegetation and reproduction | `updatePoolsTurnover` puts leaf and stem litter plus reproduction into layer 1 and distributes root litter by `rmatctem` | Prescribe the resulting signed layered litter delta after pool respiration; do not translate vegetation state |
| Mortality | `updatePoolsMortality` moves mortality losses into PFT litter, with roots distributed by `rmatctem` | Prescribe its separate signed layered delta after turnover |
| Competition | Can alter cover and redistribute PFT/bare litter and SOM before respiration | Prescribe both pool deltas and the post-competition cover; do not replay vegetation state |
| Land use | Can alter cover and redistribute owned PFT/bare pools before respiration; also creates paper/furniture pools | Prescribe owned-pool deltas and post-LUC cover; keep product state external |
| Timber harvest | Can alter owned pools before respiration | Prescribe its separate signed delta at that point |
| Fire/disturbance | Adds killed vegetation to litter and removes burned litter; it does not accept or mutate `soilcmas` | Prescribe the net layered litter delta after mortality. `fFireCsoil` is an output name for burned below-surface litter, not a Stage B SOM mutation |
| Harvested products | Fast paper is `litrmass(:,iccp2,1)` and slow furniture is `soilcmas(:,iccp2,1)`; the respiration routines also decay these slots | Keep both pools and their decay outside Stage B. If the common decay kernel is reused, validate it in a focused external-product test rather than adding `iccp2` to soil state |

All transfer arrays use `kg C m-2 step-1` on the receiving PFT/bare subarea and
are signed as `after_external_process - before_external_process`: positive adds
carbon to an owned pool and negative removes it. A process that is disabled
still has an explicit zero transfer, preserving a stable schema.

## Oracle and published-output separation

The local Fortran call snapshots and trajectory outputs must be generated from
the pinned source, container, configuration, initial state, executable, and
hash receipts. They are the Stage B parity oracle.

The CBC published outputs do not reproduce under the released Quick Start and
their production initialization/configuration is unavailable. That evidence is
retained in
[`docs/research/classic_benchmark_provenance.md`](../classic_benchmark_provenance.md)
and issue #97. Passing local Stage B parity must not be reported as published
CBC parity.
