module StageBSnapshotEvidence

import TOML

using ..StageBSnapshots
using ..StageBSnapshotSchema

export verify_stage_b_evidence

const EXACT_CRITERIA = "exact values, coordinates, masks, dimensions, types, and units"

function read_toml(path, description, issues)
    isfile(path) || begin
        push!(issues, "missing $description: $path")
        return nothing
    end
    return try
        TOML.parsefile(path)
    catch error
        push!(issues, "invalid $description: $(sprint(showerror, error))")
        nothing
    end
end

function verify_stage_b_evidence(
    schema_path,
    ordinary_snapshot,
    difficult_snapshot,
    instrumentation_receipt_path,
    comparison_path,
)
    issues = String[]
    receipt = read_toml(
        instrumentation_receipt_path,
        "instrumentation receipt",
        issues,
    )
    comparison = read_toml(comparison_path, "pristine comparison", issues)

    patch_sha256 = nothing
    source_sha256 = nothing
    if !isnothing(receipt)
        get(receipt, "schema_version", nothing) == 1 ||
            push!(issues, "unsupported instrumentation receipt schema_version")
        get(receipt, "status", nothing) == "complete" ||
            push!(issues, "instrumentation receipt is not complete")
        patch_path = get(receipt, "patch_path", "")
        patch_sha256 = get(receipt, "patch_sha256", nothing)
        source_sha256 = get(receipt, "source_sha256", nothing)
        receipt_directory = dirname(instrumentation_receipt_path)
        resolved_patch = normpath(joinpath(receipt_directory, patch_path))
        relative_patch = relpath(resolved_patch, receipt_directory)
        if relative_patch == ".." ||
           startswith(relative_patch, ".." * Base.Filesystem.path_separator) ||
           !isfile(resolved_patch) ||
           isnothing(patch_sha256) ||
           StageBSnapshots.sha256sum(resolved_patch) != patch_sha256
            push!(issues, "instrumentation patch SHA-256 is inconsistent")
        end
    end

    snapshots =
        (("ordinary", ordinary_snapshot), ("frozen_soil", difficult_snapshot))
    snapshot_reports = Dict{String, Any}()
    for (expected_transition, path) in snapshots
        report = StageBSnapshotSchema.verify_against_schema(path, schema_path)
        snapshot_reports[expected_transition] = report
        append!(
            issues,
            "$expected_transition snapshot: $issue" for issue in report.issues
        )
        report.snapshot.transition == expected_transition || push!(
            issues,
            "$expected_transition snapshot has the wrong transition label",
        )
        if report.snapshot.ok && !isnothing(receipt)
            metadata = report.snapshot.manifest["snapshot"]
            metadata["patch_sha256"] == patch_sha256 || push!(
                issues,
                "$expected_transition snapshot patch hash does not match receipt",
            )
            metadata["source_sha256"] == source_sha256 || push!(
                issues,
                "$expected_transition snapshot source hash does not match receipt",
            )
        end
    end

    if !isnothing(comparison)
        comparison_ok =
            get(comparison, "schema_version", nothing) == 1 &&
            get(comparison, "result", nothing) == "pass" &&
            get(comparison, "criteria", nothing) == EXACT_CRITERIA &&
            get(comparison, "compared_files", 0) >= 57 &&
            get(comparison, "failed_files", nothing) == 0
        comparison_ok || push!(
            issues,
            "instrumented ordinary output does not match pristine output",
        )
    end
    return (;
        ok = isempty(issues),
        issues,
        receipt,
        comparison,
        snapshot_reports,
    )
end

end
