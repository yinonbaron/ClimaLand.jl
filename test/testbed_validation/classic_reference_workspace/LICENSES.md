# CLASSIC reference licensing notes

These notes distinguish record-level metadata from the terms embedded in or
referenced by the downloaded content. They are an audit aid, not legal advice.

## Zenodo records

The Zenodo API metadata for records `18188101`, `18201505`, and `18202323`
declares `CC-BY-4.0`. Each record is pinned by its version-specific DOI and
file checksums in `manifest.toml`.

The CLASSIC v2.0 source archive contains `LICENCE.txt`, which states that
CLASSIC is distributed under the
[Open Government Licence - Canada 2.0](https://open.canada.ca/en/open-government-licence-canada).
The container record also names that license in addition to CC BY 4.0. Preserve
both the Zenodo attribution and embedded CLASSIC license notices.

## Benchmark collection

The top-level Benchmarking Collection record declares CC BY 4.0, but the
collection describes observations and inputs sourced from FLUXNET, AmeriFlux,
and other site providers. Those nested sources can impose access, attribution,
or redistribution terms that are not replaced by the record-level metadata.

Treat the complete collection and every extraction as local-only until each
selected site's source terms have been audited. Do not commit archives,
complete site data, restarts, or unreviewed derived fixtures to Git. A future
small fixture must include its source record and member, source checksum,
extraction command, selected site/time/variables, transformations, attribution,
and a completed redistribution review.
