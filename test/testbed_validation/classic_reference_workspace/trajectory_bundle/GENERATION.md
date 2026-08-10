# DE-Hai trajectory generation and free replay

`generate_trajectory_bundle` converts an external all-daily v5 capture into the
version-1 trajectory contract. It accepts only the canonical 66-field snapshot
schema. The generated bundle adds the two native geometry arrays and four
explicitly derived conservation audits, for 70 trajectory fields in total.

The raw capture must contain gap-free directories named
`daily/event_00000001.raw`, an append-only completion ledger with
`index iday relative_path` rows enclosed by the writer header and completion
marker, and a NetCDF-derived time index with matching
ordinals, `iday` values, paths, and contiguous UTC daily bounds. The capture
receipt binds all of these inputs and the source, executable, instrumentation,
configuration, initialization, schema, execution, exact nonperturbation, and
NetCDF-time evidence by SHA-256. For the released DE-Hai evidence, the CF `standard` source
calendar is normalized to the contract `proleptic_gregorian` calendar only after proving every interval
is on or after the 1582-10-15 Gregorian cutover; other source calendars and
pre-cutover intervals fail closed. Complete evidence additionally requires at
least 365 daily events and an explicit complete-season declaration.

The first transition-start `pre.*` pools become `initial.*` once. Later
`pre.*` arrays are used only to prove exact continuity with the preceding
`post.*`; they are never written as forcing. Static arrays must remain exact
throughout the capture. Drivers, reference states, and audits are written to
separate sections and retain their application phases and sampling semantics.

`free_replay` copies the initial pools once, then calls a transition adapter
with only the evolving owned state, static data, and that day's drivers. The
adapter returns the evolved state, four intermediate checkpoints, and every
meaningful audit diagnostic. The runner compares each of the six state arrays
and each of the 15 audit arrays at every step. It reports per-field and maximum
state errors with units, per-field and maximum flux errors with units, maximum
daily carbon closure, and accumulated closure drift as separate quantities.
Day-one state and flux parity must be exact. State, flux, daily closure, and
accumulated drift are independent acceptance gates; relative tolerance remains
zero for the real seasonal replay.

Generated payloads and real captures stay under the replaceable external
workspace; none belong in Git. Synthetic tests exercise the generator and
runner, but cannot satisfy `verify_replay_acceptance`. Real acceptance remains
closed until a complete v5 all-daily capture is generated and a CLASSIC Julia
transition adapter passes the full seasonal replay.
