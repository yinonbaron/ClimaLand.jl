module ClassicSitePolicyInventory

using TOML

export CLASSIC_BENCHMARK_SITES, validate_policy_inventory

const CLASSIC_BENCHMARK_SITES = (
    "AU-Tum",
    "BR-Sa1",
    "CA-Ca1",
    "CA-Cbo",
    "CA-DL1",
    "CA-Gro",
    "CA-HPC",
    "CA-Man",
    "CA-Mer",
    "CA-Oas",
    "CA-Obs",
    "CA-Qfo",
    "CA-SMC",
    "CA-TP4",
    "CA-TPD",
    "CA-TVC",
    "CA-WP1",
    "CG-Tch",
    "CN-Dan",
    "CZ-BK1",
    "DE-Hai",
    "DE-Kli",
    "DE-Tha",
    "DK-Sor",
    "ES-Amo",
    "ES-LJu",
    "ES-LgS",
    "FI-Hyy",
    "FR-Fon",
    "FR-Pue",
    "GF-Guy",
    "GH-Ank",
    "GL-ZaH",
    "IT-Lav",
    "IT-Noe",
    "IT-SRo",
    "IT-Tor",
    "MY-PSO",
    "NL-Loo",
    "PA-SPs",
    "RU-Che",
    "RU-Fyo",
    "RU-Ha1",
    "RU-Sam",
    "RU-SkP",
    "SD-Dem",
    "US-BZS",
    "US-Ha1",
    "US-MMS",
    "US-Prr",
    "US-SRC",
    "US-Sta",
    "US-UMB",
    "US-Uaf",
    "US-WCr",
    "US-Whs",
    "US-Wkg",
    "ZA-Kru",
    "ZM-Mon",
)

const REQUIRED_SITE_KEYS = (
    "name",
    "full_name",
    "source_category",
    "source_identifier",
    "policy_status",
    "policy_reference",
    "attribution_status",
    "source_chain_status",
    "redistribution_status",
    "unresolved_reason",
)
const SOURCE_CATEGORIES = ("fluxnet", "ameriflux", "provider", "unknown")
const POLICY_STATUSES = ("cc_by_4", "tier_two", "legacy", "unknown")
const ATTRIBUTION_STATUSES = ("complete", "identifier_only", "unknown")
const SOURCE_CHAIN_STATUSES = ("complete", "unresolved")
const REDISTRIBUTION_STATUSES = ("approved", "blocked")

function require_keys(table, keys, label)
    missing = filter(key -> !haskey(table, key), keys)
    isempty(missing) ||
        throw(ArgumentError("$label missing key(s): $(join(missing, ", "))"))
end

function require_member(value, allowed, label)
    value in allowed || throw(ArgumentError("invalid $label: $value"))
end

"""
    validate_policy_inventory(path)

Validate exact 59-site coverage and the fail-closed redistribution policy.
An entry can be approved only with CC BY 4.0 policy, complete attribution, and
a complete source-product and transformation chain.
"""
function validate_policy_inventory(path)
    inventory = TOML.parsefile(path)
    require_keys(
        inventory,
        ("schema_version", "expected_site_count", "artifact_policy", "site"),
        "inventory",
    )
    inventory["schema_version"] == 1 ||
        throw(ArgumentError("unsupported inventory schema version"))
    inventory["expected_site_count"] == length(CLASSIC_BENCHMARK_SITES) ||
        throw(ArgumentError("expected_site_count must be 59"))

    artifact_policy = inventory["artifact_policy"]
    require_keys(
        artifact_policy,
        ("site_inputs", "derived_tapes", "trajectory_bundles"),
        "artifact policy",
    )
    for artifact in ("site_inputs", "derived_tapes", "trajectory_bundles")
        artifact_policy[artifact] == "external_only" ||
            throw(ArgumentError("$artifact must remain external_only"))
    end

    sites = inventory["site"]
    names = String[]
    counts = Dict(category => 0 for category in SOURCE_CATEGORIES)
    for (index, site) in enumerate(sites)
        label = "site entry $index"
        require_keys(site, REQUIRED_SITE_KEYS, label)
        name = site["name"]
        push!(names, name)
        require_member(
            site["source_category"],
            SOURCE_CATEGORIES,
            "source category",
        )
        require_member(site["policy_status"], POLICY_STATUSES, "policy status")
        require_member(
            site["attribution_status"],
            ATTRIBUTION_STATUSES,
            "attribution status",
        )
        require_member(
            site["source_chain_status"],
            SOURCE_CHAIN_STATUSES,
            "source-chain status",
        )
        require_member(
            site["redistribution_status"],
            REDISTRIBUTION_STATUSES,
            "redistribution status",
        )
        counts[site["source_category"]] += 1

        safe_to_redistribute =
            site["policy_status"] == "cc_by_4" &&
            site["attribution_status"] == "complete" &&
            site["source_chain_status"] == "complete"
        site["redistribution_status"] == "approved" &&
            !safe_to_redistribute &&
            throw(
                ArgumentError(
                    "$name is approved without complete policy evidence",
                ),
            )
        site["redistribution_status"] == "blocked" &&
            isempty(strip(site["unresolved_reason"])) &&
            throw(
                ArgumentError("$name is blocked without an unresolved reason"),
            )
    end

    names == collect(CLASSIC_BENCHMARK_SITES) || throw(
        ArgumentError(
            "site inventory does not exactly match the released campaign",
        ),
    )
    length(names) == length(unique(names)) ||
        throw(ArgumentError("site inventory contains duplicate names"))

    return (site_count = length(names), source_category_counts = counts)
end

end
