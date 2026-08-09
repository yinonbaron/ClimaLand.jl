module ClassicAllSiteReport

import SHA
import TOML
using ..ClassicAllSiteParity:
    external_output_path, sha256_file, validate_archive_set

export build_all_site_draft_report, write_all_site_draft_report

const SHA256_PATTERN = r"^[0-9a-f]{64}$"

valid_sha256(value) =
    value isa AbstractString && occursin(SHA256_PATTERN, value)

function checked_measurements(tolerances)
    valid_sha256(tolerances.sha256) ||
        throw(ArgumentError("tolerance contract SHA-256 is invalid"))
    isempty(tolerances.measurement_receipts) &&
        throw(ArgumentError("tolerance contract has no measurements"))
    return [
        begin
            isfile(measurement.path) && !islink(measurement.path) || throw(
                ArgumentError("tolerance measurement receipt is unavailable"),
            )
            sha256_file(measurement.path) == measurement.sha256 || throw(
                ArgumentError("tolerance measurement receipt SHA-256 differs"),
            )
            Dict(
                "evidence_id" => measurement.evidence_id,
                "sha256" => measurement.sha256,
            )
        end for measurement in tolerances.measurement_receipts
    ]
end

function exact_error_inventory(errors, expected, label)
    errors isa AbstractDict || throw(ArgumentError("$label is not a field map"))
    Set(keys(errors)) == Set(keys(expected)) ||
        throw(ArgumentError("$label field inventory differs"))
    all(
        value -> value isa Real && isfinite(value) && value >= 0,
        values(errors),
    ) || throw(ArgumentError("$label contains invalid maxima"))
    return Dict(String(name) => Float64(value) for (name, value) in errors)
end

function tolerance_inventory(tolerances)
    return Dict(
        "state" => exact_error_inventory(
            tolerances.state,
            tolerances.state,
            "state tolerances",
        ),
        "flux" => exact_error_inventory(
            tolerances.flux,
            tolerances.flux,
            "flux tolerances",
        ),
        "budget" => exact_error_inventory(
            tolerances.budget,
            tolerances.budget,
            "budget tolerances",
        ),
        "drift" => exact_error_inventory(
            tolerances.drift,
            tolerances.drift,
            "drift tolerances",
        ),
    )
end

function evidence_hashes(external, stage_b_status)
    provenance = get(external, "provenance", Dict())
    required = Dict(
        "capture_receipt_sha256" =>
            get(external, "capture_receipt_sha256", nothing),
        "activity_report_sha256" =>
            get(external, "activity_report_sha256", nothing),
        "nonperturbation_receipt_sha256" =>
            get(provenance, "nonperturbation_receipt_sha256", nothing),
    )
    if stage_b_status == "active"
        required["replay_receipt_sha256"] =
            get(provenance, "replay_receipt_sha256", nothing)
    else
        required["inactive_stage_b_evidence_sha256"] =
            get(provenance, "inactive_stage_b_evidence_sha256", nothing)
    end
    all(valid_sha256, values(required)) ||
        throw(ArgumentError("site evidence hash inventory is incomplete"))
    return required
end

function checked_site_record(report, package, tolerances)
    external = TOML.parsefile(package.receipt)
    get(external, "site", nothing) == report.site == package.site ||
        throw(ArgumentError("site identity differs across report inventory"))
    get(external, "status", nothing) == "complete" ||
        throw(ArgumentError("site archive receipt is incomplete"))
    get(external, "archive_path", nothing) == package.archive ||
        throw(ArgumentError("site archive receipt path differs"))
    get(external, "archive_sha256", nothing) == sha256_file(package.archive) ||
        throw(ArgumentError("site archive receipt hash differs"))
    stage_b_status = get(external, "stage_b_status", nothing)
    stage_b_status == report.stage_b_status &&
    stage_b_status in ("active", "inactive") ||
        throw(ArgumentError("site Stage-B applicability differs"))
    report.evidence_complete === true ||
        throw(ArgumentError("site evidence is incomplete"))
    activity = report.activity
    activity_record = Dict(
        "active_pathways" => collect(activity.active_pathways),
        "inactive_pathways" => collect(activity.inactive_pathways),
        "active_fields" => collect(activity.active_fields),
        "inactive_fields" => collect(activity.inactive_fields),
    )
    record = Dict{String, Any}(
        "site" => report.site,
        "stage_b_status" => stage_b_status,
        "evidence_complete" => true,
        "stage_b_parity_observed" => report.stage_b_parity,
        "archive_path" => package.archive,
        "archive_sha256" => sha256_file(package.archive),
        "archive_receipt_path" => package.receipt,
        "archive_receipt_sha256" => sha256_file(package.receipt),
        "evidence_sha256" => evidence_hashes(external, stage_b_status),
        "activity" => activity_record,
    )
    if stage_b_status == "active"
        report.stage_b_parity === true ||
            throw(ArgumentError("active site parity did not pass"))
        isnothing(report.achieved_errors) &&
            throw(ArgumentError("active site lacks achieved errors"))
        record["max_state_errors"] = exact_error_inventory(
            report.achieved_errors.state,
            tolerances.state,
            "state maxima",
        )
        record["max_flux_errors"] = exact_error_inventory(
            report.achieved_errors.flux,
            tolerances.flux,
            "flux maxima",
        )
        record["max_budget_errors"] = exact_error_inventory(
            report.achieved_errors.budget,
            tolerances.budget,
            "budget maxima",
        )
        record["max_drift_errors"] = exact_error_inventory(
            report.achieved_errors.drift,
            tolerances.drift,
            "drift maxima",
        )
        record["failure_localization"] =
            collect(report.evaluation.failure_localization)
        record["replay_claimed"] = true
    else
        report.stage_b_parity === false ||
            throw(ArgumentError("inactive site claims Stage-B parity"))
        !isnothing(report.applicability) ||
            throw(ArgumentError("inactive site lacks applicability evidence"))
        get(report.applicability, "stage_b_status", nothing) == "inactive" ||
            throw(ArgumentError("inactive applicability evidence differs"))
        record["max_state_errors"] = Dict{String, Float64}()
        record["max_flux_errors"] = Dict{String, Float64}()
        record["max_budget_errors"] = Dict{String, Float64}()
        record["max_drift_errors"] = Dict{String, Float64}()
        record["failure_localization"] = Any[]
        record["replay_claimed"] = false
        record["deferred_issue"] = 108
    end
    return record
end

function archive_inventory_sha256(records)
    lines = [
        join(
            (
                record["site"],
                record["archive_sha256"],
                record["archive_receipt_sha256"],
            ),
            "\t",
        ) for record in records
    ]
    return bytes2hex(SHA.sha256(join(lines, "\n") * "\n"))
end

function build_all_site_draft_report(
    campaign,
    archive_root,
    inventory,
    tolerances,
)
    campaign.site_count == 59 && length(campaign.reports) == 59 ||
        throw(ArgumentError("draft report requires exactly 59 site results"))
    campaign.evidence_complete === true && campaign.ok === true ||
        throw(ArgumentError("all-site evidence campaign is incomplete"))
    getproperty.(campaign.reports, :site) == inventory.sites ||
        throw(ArgumentError("campaign report order differs from inventory"))
    packages = validate_archive_set(archive_root, inventory)
    sites = [
        checked_site_record(report, package, tolerances) for
        (report, package) in zip(campaign.reports, packages)
    ]
    active_count = count(site -> site["stage_b_status"] == "active", sites)
    inactive_count = count(site -> site["stage_b_status"] == "inactive", sites)
    active_count + inactive_count == 59 ||
        throw(ArgumentError("site applicability inventory is incomplete"))
    return Dict{String, Any}(
        "schema_version" => 1,
        "report_kind" => "all_site_stage_b_draft",
        "status" => "draft_complete",
        "approval_status" => "pending_direct_user_approval",
        "scientific_status" => "not_promoted",
        "seasonal_parity_claimed" => false,
        "checksum_status" => "draft_only_not_promoted",
        "site_count" => 59,
        "active_site_count" => active_count,
        "inactive_site_count" => inactive_count,
        "evidence_complete" => true,
        "active_stage_b_parity_observed" =>
            campaign.active_stage_b_parity_complete,
        "policy_inventory_sha256" => inventory.policy_sha256,
        "site_metrics_sha256" => inventory.metrics_sha256,
        "archive_inventory_sha256" => archive_inventory_sha256(sites),
        "tolerance_contract_sha256" => tolerances.sha256,
        "tolerances" => tolerance_inventory(tolerances),
        "tolerance_measurement_receipt" => checked_measurements(tolerances),
        "site" => sites,
    )
end

function write_all_site_draft_report(
    path,
    campaign,
    archive_root,
    inventory,
    tolerances;
    repository_root,
)
    path = external_output_path(path, repository_root)
    ispath(path) && throw(ArgumentError("draft report already exists"))
    report = build_all_site_draft_report(
        campaign,
        archive_root,
        inventory,
        tolerances,
    )
    open(path, "w") do io
        TOML.print(io, report; sorted = true)
    end
    return (; report, path, sha256 = sha256_file(path))
end

end
