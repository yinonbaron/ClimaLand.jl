# CLASSIC 59-site data-policy inventory

`site_policy_inventory.toml` records the policy and attribution review state
for every site in the released CLASSIC v2.0 benchmarking collection. It is a
control-plane inventory only: it contains identifiers and review results, not
site observations, forcing, restarts, snapshots, or trajectory bundles.

## Review basis

The site list and identifiers come from the released `siteinfo.yaml` files.
Policy labels were checked on 2026-08-09 against the authoritative FLUXNET and
AmeriFlux policy/site pages and the CA-DL1 provider record. The classification
is:

- 37 FLUXNET sites: 34 CC BY 4.0 and three Tier Two (`RU-Sam`, `RU-SkP`, and
  `ZA-Kru`);
- 21 AmeriFlux sites: 20 CC BY 4.0 and one Legacy Policy site (`CA-WP1`);
- one provider deposit: `CA-DL1`, Zenodo record 4301133, CC BY 4.0;
- no sites with an unknown provider category.

The authoritative policy references are:

- <https://fluxnet.org/data/data-policy/>
- <https://ameriflux.lbl.gov/data/data-policy/>
- <https://zenodo.org/records/4301133>

## Why every redistribution status is blocked

The benchmark collection's record-level CC BY 4.0 label does not document the
source-product version, downloaded attribution payload, member-level checksum,
or transformation chain for each bundled meteorological input. A per-site DOI
is enough to identify a likely source, but not enough to prove that a derived
forcing tape can be redistributed with complete attribution.

There are additional explicit restrictions:

- FLUXNET Tier Two limits use to scientific and educational purposes and
  requires provider contact and an opportunity to collaborate.
- AmeriFlux Legacy Policy requires contacting site contributors and giving
  them an opportunity to contribute substantively.

The archive does not retain the required contact payload for those four sites.
For this reason, all site inputs and all derived tapes or bundles remain in the
external `$CLASSIC_REFERENCE_ROOT` workspace. They must not be
committed to Git. This restriction is independent of whether a site is marked
CC BY 4.0; `redistribution_status` can become `approved` only after the exact
source chain and required attribution are complete.

## Completing a site review

Record the exact source product and version, access date, original member and
checksum, all transformations, final checksum, required citation and
acknowledgement text, and any provider contact obligations. Then change
`attribution_status` and `source_chain_status` to `complete`. The validator
rejects an `approved` redistribution status unless all three conditions hold:
CC BY 4.0, complete attribution, and a complete source chain.

Run the policy checks with:

```bash
julia --startup-file=no \
  test/testbed_validation/classic_reference_workspace/all_sites/policy_inventory_tests.jl
```
