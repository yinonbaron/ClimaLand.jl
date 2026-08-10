# CLASSIC Stage B all-site acceptance

`run_all_site_report.jl` strictly consumes the 59 immutable campaign packages
and writes an external draft containing package hashes, provenance, activity,
per-field tolerances, achieved errors, and effective analytic budget/drift
ceilings. `promote_all_site_report.jl` revalidates those external files and
ceilings before recording direct user approval in a separate acceptance
report; it cannot promote a draft by changing status fields alone.

The accepted scientific scope is 57 active mineral-soil Stage B seasonal
replays plus two structurally complete inactive applicability packages
(`CA-Mer` and `CA-WP1`). The inactive peat/moss sites make no Stage B parity
claim and remain deferred to issue #108.

This promotion does not complete issue #107. Every current site policy keeps
`redistribution_status = "blocked"`, so no real compact fixture may be checked
in. The synthetic packer tests only prove the fail-closed packaging contract.
Issue #107 remains open until ordinary/difficult real fixtures have legally
cleared provenance and redistribution approval.

Fresh-local Fortran parity is translation evidence only. It is not parity with
the published CBC output; that distinct mismatch remains open in issue #97 and
is governed by ADR 0004.
