# Sequential Stage B extraction for all sites

`build_extraction_plan` combines the reviewed 59-site policy inventory with
the versioned Stage B trajectory schema. The resulting control-plane plan
contains no forcing or observations. It binds both source files by SHA-256,
records every site's provider and attribution status, and lists all 70 bundle
fields plus the 20 external driver fields.

`run_extraction_plan` executes an injected site-capture adapter sequentially.
The adapter receives a site name, a unique temporary workspace, and the
required 70-field inventory. It must create:

- `capture/`, containing that site's generated trajectory;
- `field_activity.toml`, with measured presence, activity, nonzero count, and
  maximum absolute value for every field;
- `capture_receipt.toml`, binding the site, source, execution, chronology,
  nonperturbation, replay, activity, and trajectory-schema evidence.

After each adapter call, the runner rejects missing or contradictory fields,
validates complete real-capture receipts, creates one TAR archive, hashes it,
writes a policy-aware site receipt, and removes the loose workspace before
advancing. Callback exceptions are streamed and immediately persisted as
`<site>.failure.toml`. Existing archives and campaign receipts are never
overwritten or deleted.

`site_execution.jl` prepares one isolated site from the retained issue #98
oracle, runs the pinned Stage B v5 executable with bounded all-daily capture,
checks the 66-field event ledger, and compares all 57 NetCDF outputs exactly.
`real_capture.jl` converts the events to the 70-field bundle, performs free
replay, writes activity evidence, and seals the canonical capture root.
`run_real_campaign.jl` connects these seams using a TOML configuration and
runs only one child execution workspace at a time.

The capture length comes from the oracle's first daily time coordinate, not
`runEndYear`. A complete cycle must start January 1, remain daily and gap-free,
and reach the next January 1 under the declared `standard` calendar. Receipts
retain separate oracle/candidate NetCDF file hashes and require equality of a
canonical semantic time hash over calendar, units, coordinate length, and
every decoded timestamp.

Both work and archive roots must resolve outside the Git repository. Archives,
receipts, forcing tapes, and all derived scientific payloads belong under the
external `$CLASSIC_REFERENCE_ROOT/replaceable` hierarchy. Only the
machinery and synthetic tests belong in Git. A plan can set
`real_acceptance = true` only when every site callback produces complete
fresh-local-Fortran, Stage B v5, non-synthetic evidence and the campaign has no
failed sites.
