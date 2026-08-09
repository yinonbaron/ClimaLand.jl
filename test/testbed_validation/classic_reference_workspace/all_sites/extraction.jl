module ClassicAllSitesExtraction

using Dates
import SHA
import TOML
import Tar

export build_extraction_plan,
    prepare_extraction_resume, run_extraction_plan, sha256_path

const SHA256_PATTERN = r"^[0-9a-f]{64}$"
const SAFE_SITE = r"^[A-Z0-9]{2,3}-[A-Za-z0-9]{2,3}$"

sha256_path(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

valid_sha256(value) =
    value isa AbstractString && occursin(SHA256_PATTERN, value)

include("failure_evidence.jl")

function write_toml_atomic(path, table)
    ispath(path) && throw(ArgumentError("refusing to overwrite $path"))
    mkpath(dirname(abspath(path)))
    temporary = path * ".partial"
    try
        open(temporary, "w") do io
            TOML.print(io, table; sorted = true)
        end
        mv(temporary, path)
    catch
        ispath(temporary) && rm(temporary)
        rethrow()
    end
    return path
end

function expanded_schema_fields(schema)
    fields = copy(get(schema, "field", Any[]))
    for group in get(get(schema, "groups", Dict()), "field", Any[])
        for name in get(group, "names", Any[])
            field =
                Dict(key => value for (key, value) in group if key != "names")
            field["name"] = name
            push!(fields, field)
        end
    end
    return fields
end

function validate_policy_for_plan(inventory, expected_site_count)
    get(inventory, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported policy inventory"))
    get(inventory, "expected_site_count", nothing) == expected_site_count ||
        throw(ArgumentError("policy expected_site_count differs"))
    sites = get(inventory, "site", Any[])
    length(sites) == expected_site_count ||
        throw(ArgumentError("policy site count differs"))
    names = getindex.(sites, "name")
    length(unique(names)) == length(names) ||
        throw(ArgumentError("policy inventory contains duplicate sites"))
    all(occursin(SAFE_SITE, name) for name in names) ||
        throw(ArgumentError("policy inventory contains an unsafe site name"))
    artifact_policy = get(inventory, "artifact_policy", Dict())
    all(
        get(artifact_policy, key, nothing) == "external_only" for
        key in ("site_inputs", "derived_tapes", "trajectory_bundles")
    ) || throw(ArgumentError("site artifacts must remain external_only"))
    required = (
        "full_name",
        "policy_reference",
        "source_category",
        "source_identifier",
        "policy_status",
        "attribution_status",
        "source_chain_status",
        "redistribution_status",
        "unresolved_reason",
    )
    all(all(haskey(site, key) for key in required) for site in sites) ||
        throw(ArgumentError("policy inventory has incomplete site provenance"))
    return sites
end

"""
    build_extraction_plan(destination, policy_inventory, trajectory_schema)

Create a control-plane plan for sequential external capture. The plan contains
identifiers, policy status, expected driver names, and hashes only.
"""
function build_extraction_plan(
    destination,
    policy_inventory_path,
    trajectory_schema_path;
    expected_site_count = 59,
    real_acceptance = false,
)
    inventory = TOML.parsefile(policy_inventory_path)
    sites = validate_policy_for_plan(inventory, expected_site_count)
    schema = TOML.parsefile(trajectory_schema_path)
    get(schema, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported trajectory schema"))
    bundle_fields =
        sort!([field["name"] for field in expanded_schema_fields(schema)])
    length(unique(bundle_fields)) == length(bundle_fields) ||
        throw(ArgumentError("trajectory schema has duplicate fields"))
    drivers = sort!([
        field["name"] for field in expanded_schema_fields(schema) if
        get(field, "section", nothing) == "drivers"
    ])
    isempty(drivers) && throw(ArgumentError("trajectory schema has no drivers"))
    length(unique(drivers)) == length(drivers) ||
        throw(ArgumentError("trajectory schema has duplicate drivers"))
    plan_sites = [
        Dict(
            "name" => site["name"],
            "full_name" => site["full_name"],
            "source_category" => site["source_category"],
            "source_identifier" => site["source_identifier"],
            "policy_status" => site["policy_status"],
            "policy_reference" => site["policy_reference"],
            "attribution_status" => site["attribution_status"],
            "source_chain_status" => site["source_chain_status"],
            "redistribution_status" => site["redistribution_status"],
            "unresolved_reason" => site["unresolved_reason"],
            "artifact_policy" => "external_only",
        ) for site in sites
    ]
    plan = Dict(
        "schema_version" => 1,
        "site_count" => expected_site_count,
        "execution_order" => "sequential",
        "packing_policy" => "pack_each_site_before_next_capture",
        "raw_retention" => "delete_after_verified_pack",
        "real_acceptance" => real_acceptance,
        "acceptance_blockers" =>
            real_acceptance ? String[] :
            [
                "clean_v5_seasonal_evidence_unavailable",
                "issue_105_free_replay_unavailable",
            ],
        "policy_inventory_sha256" => sha256_path(policy_inventory_path),
        "trajectory_schema_sha256" => sha256_path(trajectory_schema_path),
        "required_driver_field" => drivers,
        "required_bundle_field" => bundle_fields,
        "site" => plan_sites,
    )
    write_toml_atomic(destination, plan)
    return destination
end

function resolved_path(path)
    current = abspath(path)
    suffix = String[]
    while !ispath(current)
        parent = dirname(current)
        parent == current && throw(ArgumentError("cannot resolve path"))
        push!(suffix, basename(current))
        current = parent
    end
    resolved = realpath(current)
    for component in reverse(suffix)
        resolved = joinpath(resolved, component)
    end
    return normpath(resolved)
end

function path_within(path, root)
    relative = relpath(resolved_path(path), resolved_path(root))
    return relative != ".." &&
           !startswith(relative, ".." * Base.Filesystem.path_separator)
end

function require_external_root(path, repository_root, label)
    path_within(path, repository_root) &&
        throw(ArgumentError("$label must remain outside the Git repository"))
    return resolved_path(path)
end

function validate_activity(path, required_fields)
    report = TOML.parsefile(path)
    get(report, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported field-activity report"))
    fields = get(report, "field", Any[])
    names = getindex.(fields, "name")
    length(unique(names)) == length(names) ||
        throw(ArgumentError("field-activity report contains duplicates"))
    extra = sort!(collect(setdiff(Set(names), Set(required_fields))))
    isempty(extra) ||
        throw(ArgumentError("field-activity report contains undeclared fields"))
    records = Dict(field["name"] => field for field in fields)
    missing = sort!([
        name for name in required_fields if !haskey(records, name) ||
            get(records[name], "present", false) !== true
    ])
    for (name, record) in records
        haskey(record, "active") && record["active"] isa Bool ||
            throw(ArgumentError("$name activity flag is invalid"))
        if all(
            haskey(record, key) for
            key in ("nonzero_count", "maximum_absolute_value")
        )
            count = record["nonzero_count"]
            maximum = record["maximum_absolute_value"]
            count isa Integer && count >= 0 ||
                throw(ArgumentError("$name nonzero count is invalid"))
            maximum isa Real && isfinite(maximum) && maximum >= 0 ||
                throw(ArgumentError("$name maximum magnitude is invalid"))
            measured_active = count > 0 && maximum > 0
            record["active"] == measured_active || throw(
                ArgumentError(
                    "$name activity flag contradicts measured values",
                ),
            )
        end
    end
    inactive = sort!([
        name for name in required_fields if haskey(records, name) &&
            get(records[name], "present", false) === true &&
            get(records[name], "active", false) !== true
    ])
    return (; missing, inactive)
end

function validate_capture_receipt(path, site, schema_sha256)
    receipt = TOML.parsefile(path)
    get(receipt, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported site capture receipt"))
    get(receipt, "site", nothing) == site ||
        throw(ArgumentError("capture receipt site differs"))
    get(receipt, "status", nothing) in ("synthetic", "complete") ||
        throw(ArgumentError("capture receipt status is invalid"))
    valid_sha256(get(receipt, "trajectory_schema_sha256", nothing)) ||
        throw(ArgumentError("capture receipt lacks trajectory_schema_sha256"))
    receipt["trajectory_schema_sha256"] == schema_sha256 ||
        throw(ArgumentError("capture receipt trajectory schema differs"))
    step_count = get(receipt, "step_count", nothing)
    step_count isa Integer && step_count > 0 ||
        throw(ArgumentError("capture receipt step_count is invalid"))
    if receipt["status"] == "synthetic"
        for key in ("source_sha256", "execution_sha256")
            valid_sha256(get(receipt, key, nothing)) ||
                throw(ArgumentError("synthetic capture receipt lacks $key"))
        end
    else
        get(receipt, "reference_kind", nothing) == "fresh_local_fortran" ||
            throw(ArgumentError("complete capture is not fresh local Fortran"))
        get(receipt, "oracle_contract", nothing) == "stage_b_v5" ||
            throw(ArgumentError("complete capture is not Stage B v5"))
        get(receipt, "synthetic_data_used", nothing) === false ||
            throw(ArgumentError("complete capture used synthetic data"))
        get(receipt, "nonperturbation_result", nothing) == "pass" ||
            throw(ArgumentError("complete capture lacks exact nonperturbation"))
        provenance = get(receipt, "provenance", Dict())
        isempty(provenance) &&
            throw(ArgumentError("complete capture lacks provenance"))
        stage_b_status = get(receipt, "stage_b_status", "active")
        stage_b_status in ("active", "inactive") ||
            throw(ArgumentError("complete capture Stage-B status is invalid"))
        if stage_b_status == "inactive"
            get(receipt, "replay_claimed", nothing) === false ||
                throw(ArgumentError("inactive capture claims Stage-B replay"))
            get(receipt, "stage_c_semantics_excluded", nothing) === true ||
                throw(
                    ArgumentError(
                        "inactive capture includes Stage-C semantics",
                    ),
                )
            get(receipt, "deferred_issue", nothing) == 108 || throw(
                ArgumentError("inactive capture is not deferred to Stage C"),
            )
            valid_sha256(
                get(provenance, "inactive_stage_b_evidence_sha256", nothing),
            ) || throw(
                ArgumentError("inactive capture lacks applicability evidence"),
            )
            haskey(provenance, "replay_receipt_sha256") && throw(
                ArgumentError("inactive capture contains replay evidence"),
            )
        else
            get(receipt, "replay_claimed", true) === true ||
                throw(ArgumentError("active capture lacks replay claim"))
            valid_sha256(get(provenance, "replay_receipt_sha256", nothing)) ||
                throw(ArgumentError("active capture lacks replay evidence"))
        end
        all(
            valid_sha256(value) for
            (key, value) in provenance if key != "source_commit"
        ) || throw(ArgumentError("complete capture provenance hash is invalid"))
    end
    if receipt["status"] == "complete"
        get(receipt, "complete_seasonal_cycle", false) === true ||
            throw(ArgumentError("complete site capture lacks a seasonal cycle"))
        step_count >= 365 || throw(
            ArgumentError("complete site capture has fewer than 365 steps"),
        )
        capture_year = get(receipt, "capture_year", nothing)
        capture_year isa Integer ||
            throw(ArgumentError("complete capture lacks capture_year"))
        get(receipt, "capture_event_count", nothing) == step_count ||
            throw(ArgumentError("capture event count differs from step_count"))
        step_count == daysinyear(capture_year) ||
            throw(ArgumentError("capture event count differs from first year"))
        get(receipt, "capture_source_calendar", nothing) == "standard" ||
            throw(ArgumentError("capture source calendar is not standard"))
        first_time = DateTime(get(receipt, "capture_first_time", ""))
        last_time = DateTime(get(receipt, "capture_last_time", ""))
        next_year_start = DateTime(get(receipt, "capture_next_year_start", ""))
        first_time == DateTime(capture_year, 1, 1) ||
            throw(ArgumentError("capture does not start January 1"))
        last_time + Day(1) ==
        next_year_start ==
        DateTime(capture_year + 1, 1, 1) ||
            throw(ArgumentError("capture does not reach next January 1"))
        oracle_time_file_sha =
            get(receipt, "oracle_daily_time_file_sha256", nothing)
        candidate_time_file_sha =
            get(receipt, "candidate_daily_time_file_sha256", nothing)
        valid_sha256(oracle_time_file_sha) &&
        valid_sha256(candidate_time_file_sha) ||
            throw(ArgumentError("capture daily time file SHA is invalid"))
        oracle_time_sha = get(receipt, "oracle_daily_time_sha256", nothing)
        candidate_time_sha =
            get(receipt, "candidate_daily_time_sha256", nothing)
        valid_sha256(oracle_time_sha) &&
        oracle_time_sha == candidate_time_sha ||
            throw(ArgumentError("capture daily time hash differs from oracle"))
    end
    return receipt
end

function pack_capture(capture_directory, destination)
    isdir(capture_directory) || throw(
        ArgumentError("capture callback did not create a capture directory"),
    )
    isempty(readdir(capture_directory)) &&
        throw(ArgumentError("capture directory is empty"))
    ispath(destination) && throw(ArgumentError("site archive already exists"))
    temporary = destination * ".partial"
    try
        Tar.create(capture_directory, temporary)
        filesize(temporary) > 0 || throw(ArgumentError("site archive is empty"))
        mv(temporary, destination)
    catch
        ispath(temporary) && rm(temporary)
        rethrow()
    end
    return destination
end

function failure_result(site, issues, missing = String[], inactive = String[])
    return (;
        site,
        status = "failed",
        issues,
        missing_fields = missing,
        inactive_fields = inactive,
    )
end

function validate_resume_report(report, site)
    hasproperty(report, :ok) && report.ok ||
        throw(ArgumentError("strict archive validation failed for $site"))
    hasproperty(report, :evidence_complete) && report.evidence_complete ||
        throw(ArgumentError("archive evidence is incomplete for $site"))
    return report
end

function validated_package_record(
    site,
    archive,
    receipt_path,
    validate_existing!,
)
    validate_resume_report(
        validate_existing!(site, archive, receipt_path),
        site,
    )
    receipt = TOML.parsefile(receipt_path)
    get(receipt, "site", nothing) == site ||
        throw(ArgumentError("final package receipt site differs for $site"))
    archive_sha256 = sha256_path(archive)
    get(receipt, "archive_sha256", nothing) == archive_sha256 ||
        throw(ArgumentError("final package archive hash differs for $site"))
    get(receipt, "archive_bytes", nothing) == filesize(archive) ||
        throw(ArgumentError("final package archive size differs for $site"))
    status = get(receipt, "status", nothing)
    status in ("complete", "synthetic") ||
        throw(ArgumentError("final package status is invalid for $site"))
    classification = if status == "complete"
        stage_b_status = get(receipt, "stage_b_status", "active")
        stage_b_status in ("active", "inactive") || throw(
            ArgumentError("final package Stage-B status is invalid for $site"),
        )
        stage_b_status
    else
        status
    end
    return Dict(
        "site" => site,
        "archive_sha256" => archive_sha256,
        "archive_bytes" => filesize(archive),
        "receipt_sha256" => sha256_path(receipt_path),
        "receipt_bytes" => filesize(receipt_path),
        "evidence_classification" => classification,
    )
end

function validated_package_inventory(sites, archive_root, validate_existing!)
    return [
        validated_package_record(
            site["name"],
            joinpath(archive_root, site["name"] * ".tar"),
            joinpath(archive_root, site["name"] * ".receipt.toml"),
            validate_existing!,
        ) for site in sites
    ]
end

function interrupted_file_records(workspace)
    records = Dict{String, Any}[]
    for (root, directories, files) in walkdir(workspace)
        for name in directories
            islink(joinpath(root, name)) &&
                throw(ArgumentError("interrupted workspace contains a symlink"))
        end
        for name in files
            path = joinpath(root, name)
            islink(path) &&
                throw(ArgumentError("interrupted workspace contains a symlink"))
            isfile(path) || throw(
                ArgumentError("interrupted workspace entry is not regular"),
            )
            push!(
                records,
                Dict(
                    "path" => relpath(path, workspace),
                    "bytes" => filesize(path),
                    "sha256" => sha256_path(path),
                ),
            )
        end
    end
    sort!(records; by = record -> record["path"])
    isempty(records) &&
        throw(ArgumentError("interrupted workspace contains no evidence"))
    return records
end

function safe_interruption_path(path)
    path isa AbstractString || return false
    isabspath(path) && return false
    normalized = normpath(path)
    return !(
        normalized in ("", ".", "..") ||
        startswith(normalized, ".." * Base.Filesystem.path_separator)
    )
end

function verify_interrupted_archive(archive_path, expected_records)
    headers = try
        Tar.list(archive_path; strict = true)
    catch error
        throw(
            ArgumentError(
                "unreadable interruption archive: $(sprint(showerror, error))",
            ),
        )
    end
    paths = normpath.(getproperty.(headers, :path))
    length(paths) == length(unique(paths)) ||
        throw(ArgumentError("interruption archive contains duplicate members"))
    all(
        header ->
            header.type in (:file, :directory) &&
            isempty(header.link) &&
            safe_interruption_path(header.path),
        headers,
    ) || throw(ArgumentError("interruption archive contains an unsafe member"))
    expected_files = Set(record["path"] for record in expected_records)
    archive_files =
        Set(normpath(header.path) for header in headers if header.type == :file)
    archive_files == expected_files ||
        throw(ArgumentError("interruption archive inventory differs"))
    allowed_directories = Set{String}()
    for path in expected_files
        directory = dirname(path)
        while !(directory in ("", "."))
            push!(allowed_directories, directory)
            directory = dirname(directory)
        end
    end
    all(
        normpath(header.path) in allowed_directories for
        header in headers if header.type == :directory
    ) ||
        throw(ArgumentError("interruption archive contains an extra directory"))
    mktempdir() do extracted
        Tar.extract(archive_path, extracted)
        interrupted_file_records(extracted) == expected_records ||
            throw(ArgumentError("interruption archive content differs"))
    end
    return true
end

function preserve_interrupted_workspace!(
    workspace,
    archive_root,
    site,
    completed_count,
    plan_sha256,
    config_sha256,
    pack_interrupted!,
)
    attempt_root =
        joinpath(archive_root, "interruption_attempts", "attempt_0001")
    ispath(attempt_root) &&
        throw(ArgumentError("interruption attempt already exists"))
    mkpath(attempt_root)
    records = interrupted_file_records(workspace)
    manifest_path = joinpath(attempt_root, "tree_manifest.toml")
    write_toml_atomic(
        manifest_path,
        Dict(
            "schema_version" => 1,
            "file_count" => length(records),
            "file" => records,
        ),
    )
    archive_path = joinpath(attempt_root, site * ".interrupted.tar")
    pack_interrupted!(workspace, archive_path)
    verify_interrupted_archive(archive_path, records)
    receipt_path = joinpath(attempt_root, "interruption_receipt.toml")
    receipt = Dict(
        "schema_version" => 1,
        "status" => "interrupted",
        "site" => site,
        "completed_site_count" => completed_count,
        "plan_sha256" => plan_sha256,
        "campaign_config_sha256" => config_sha256,
        "tree_manifest_sha256" => sha256_path(manifest_path),
        "file_count" => length(records),
        "archive_path" => abspath(archive_path),
        "archive_bytes" => filesize(archive_path),
        "archive_sha256" => sha256_path(archive_path),
    )
    write_toml_atomic(receipt_path, receipt)
    TOML.parsefile(receipt_path) == receipt ||
        throw(ArgumentError("interruption receipt round trip differs"))
    sha256_path(archive_path) == receipt["archive_sha256"] ||
        throw(ArgumentError("interruption archive hash differs"))
    rm(workspace; recursive = true)
    return (; archive_path, receipt_path, receipt)
end

"""
    prepare_extraction_resume(plan_path, config_path, work_root, archive_root,
                              validate_existing!; ...)

Validate a contiguous prefix of accepted packages through the strict consumer,
preserve one interrupted staging tree as hash-bound evidence, and return the
state required to resume at the first unfinished site.
"""
function prepare_extraction_resume(
    plan_path,
    config_path,
    work_root,
    archive_root,
    validate_existing!;
    repository_root,
    expected_plan_sha256,
    expected_config_sha256,
    pack_interrupted! = pack_capture,
)
    sha256_path(plan_path) == expected_plan_sha256 ||
        throw(ArgumentError("resume extraction plan hash differs"))
    sha256_path(config_path) == expected_config_sha256 ||
        throw(ArgumentError("resume campaign config hash differs"))
    work_root = require_external_root(work_root, repository_root, "work root")
    archive_root =
        require_external_root(archive_root, repository_root, "archive root")
    ispath(joinpath(archive_root, "campaign_extraction_receipt.toml")) &&
        throw(ArgumentError("campaign already has a final receipt"))
    plan = TOML.parsefile(plan_path)
    sites = get(plan, "site", Any[])
    length(sites) == get(plan, "site_count", nothing) ||
        throw(ArgumentError("resume plan site count differs"))
    site_names = getindex.(sites, "name")
    expected_files = Set(
        Iterators.flatten((
            (site * ".tar", site * ".receipt.toml") for site in site_names
        ),),
    )
    archive_entries = readdir(archive_root)
    all(
        name ->
            name in expected_files &&
            isfile(joinpath(archive_root, name)) &&
            !islink(joinpath(archive_root, name)),
        archive_entries,
    ) || throw(ArgumentError("resume archive root contains an extra artifact"))
    actual_files = Set(archive_entries)
    isempty(setdiff(actual_files, expected_files)) ||
        throw(ArgumentError("resume archive root contains an extra artifact"))
    completed_results = NamedTuple[]
    found_gap = false
    next_index = length(sites) + 1
    for (index, site_plan) in enumerate(sites)
        site = site_plan["name"]
        archive = joinpath(archive_root, site * ".tar")
        receipt_path = joinpath(archive_root, site * ".receipt.toml")
        has_archive = isfile(archive)
        has_receipt = isfile(receipt_path)
        has_archive == has_receipt ||
            throw(ArgumentError("resume package pair differs for $site"))
        if has_archive
            found_gap &&
                throw(ArgumentError("resume packages are not a prefix"))
            validate_resume_report(
                validate_existing!(site, archive, receipt_path),
                site,
            )
            receipt = TOML.parsefile(receipt_path)
            push!(
                completed_results,
                (;
                    site,
                    status = "packed",
                    issues = String[],
                    missing_fields = String.(
                        get(receipt, "missing_fields", Any[]),
                    ),
                    inactive_fields = String.(
                        get(receipt, "inactive_fields", Any[]),
                    ),
                ),
            )
        elseif !found_gap
            found_gap = true
            next_index = index
        end
    end
    next_index <= length(sites) ||
        throw(ArgumentError("resume plan has no unfinished site"))
    expected_workspace =
        joinpath(work_root, sites[next_index]["name"] * ".capture")
    work_entries = readdir(work_root)
    length(work_entries) == 1 &&
    only(work_entries) == basename(expected_workspace) &&
    isdir(expected_workspace) &&
    !islink(expected_workspace) || throw(
        ArgumentError(
            "resume work root does not contain exactly the interrupted site",
        ),
    )
    interrupted = preserve_interrupted_workspace!(
        expected_workspace,
        archive_root,
        sites[next_index]["name"],
        length(completed_results),
        expected_plan_sha256,
        expected_config_sha256,
        pack_interrupted!,
    )
    return (;
        plan_path = abspath(plan_path),
        config_path = abspath(config_path),
        plan_sha256 = expected_plan_sha256,
        config_sha256 = expected_config_sha256,
        work_root,
        archive_root,
        next_index,
        completed_results,
        validate_existing!,
        interruption_archive = interrupted.archive_path,
        interruption_receipt = interrupted.receipt_path,
        interruption_receipt_sha256 = sha256_path(interrupted.receipt_path),
        interrupted_attempt = interrupted.receipt,
    )
end

"""
    run_extraction_plan(plan, work_root, archive_root, capture!; repository_root)

Run one site at a time. A callback populates only the current site's workspace.
The capture is packed and checksummed before that workspace is removed and the
next site starts. Failures are reported without retaining loose files.
"""
function run_extraction_plan(
    plan_path,
    work_root,
    archive_root,
    capture!;
    repository_root,
    stop_on_failure = false,
    resume = nothing,
)
    plan = TOML.parsefile(plan_path)
    get(plan, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported extraction plan"))
    get(plan, "execution_order", nothing) == "sequential" ||
        throw(ArgumentError("extraction plan is not sequential"))
    work_root = require_external_root(work_root, repository_root, "work root")
    archive_root =
        require_external_root(archive_root, repository_root, "archive root")
    work_root == archive_root &&
        throw(ArgumentError("work and archive roots must differ"))
    (
        path_within(work_root, archive_root) ||
        path_within(archive_root, work_root)
    ) && throw(ArgumentError("work and archive roots must not overlap"))
    summary_path = joinpath(archive_root, "campaign_extraction_receipt.toml")
    ispath(summary_path) &&
        throw(ArgumentError("campaign extraction receipt already exists"))
    mkpath(work_root)
    mkpath(archive_root)
    sites = get(plan, "site", Any[])
    length(sites) == get(plan, "site_count", nothing) ||
        throw(ArgumentError("extraction plan site count differs"))
    required_fields = get(plan, "required_bundle_field", String[])
    schema_sha256 = get(plan, "trajectory_schema_sha256", nothing)
    valid_sha256(schema_sha256) ||
        throw(ArgumentError("extraction plan schema hash is invalid"))
    results = if isnothing(resume)
        NamedTuple[]
    else
        abspath(plan_path) == resume.plan_path ||
            throw(ArgumentError("resume plan path differs"))
        work_root == resume.work_root ||
            throw(ArgumentError("resume work root differs"))
        archive_root == resume.archive_root ||
            throw(ArgumentError("resume archive root differs"))
        sha256_path(plan_path) == resume.plan_sha256 ||
            throw(ArgumentError("resume plan changed after preparation"))
        sha256_path(resume.config_path) == resume.config_sha256 ||
            throw(ArgumentError("resume config changed after preparation"))
        length(resume.completed_results) == resume.next_index - 1 ||
            throw(ArgumentError("resume completed prefix length differs"))
        copy(resume.completed_results)
    end
    first_index = isnothing(resume) ? 1 : resume.next_index
    for site_plan in sites[first_index:end]
        site = site_plan["name"]
        workspace = joinpath(work_root, site * ".capture")
        archive = joinpath(archive_root, site * ".tar")
        receipt_path = joinpath(archive_root, site * ".receipt.toml")
        if ispath(archive) || ispath(receipt_path)
            push!(
                results,
                failure_result(
                    site,
                    ["site archive or receipt already exists"],
                ),
            )
            stop_on_failure && break
            continue
        end
        ispath(workspace) && begin
            push!(results, failure_result(site, ["stale site workspace exists"]))
            stop_on_failure && break
            continue
        end
        mkpath(workspace)
        activity = (; missing = String[], inactive = String[])
        try
            capture!(site, workspace, required_fields)
            capture_directory = joinpath(workspace, "capture")
            activity_path =
                isfile(joinpath(workspace, "field_activity.toml")) ?
                joinpath(workspace, "field_activity.toml") :
                joinpath(capture_directory, "field_activity.toml")
            isfile(activity_path) ||
                throw(ArgumentError("capture lacks field_activity.toml"))
            activity = validate_activity(activity_path, required_fields)
            isempty(activity.missing) || begin
                push!(
                    results,
                    failure_result(
                        site,
                        ["capture is missing required bundle fields"],
                        activity.missing,
                        activity.inactive,
                    ),
                )
                stop_on_failure && break
                continue
            end
            capture_receipt_path =
                isfile(joinpath(workspace, "capture_receipt.toml")) ?
                joinpath(workspace, "capture_receipt.toml") :
                joinpath(capture_directory, "capture_receipt.toml")
            isfile(capture_receipt_path) ||
                throw(ArgumentError("capture lacks capture_receipt.toml"))
            capture_receipt = validate_capture_receipt(
                capture_receipt_path,
                site,
                schema_sha256,
            )
            for evidence_path in (activity_path, capture_receipt_path)
                destination =
                    joinpath(capture_directory, basename(evidence_path))
                if ispath(destination)
                    sha256_path(destination) == sha256_path(evidence_path) ||
                        throw(
                            ArgumentError(
                                "capture control file differs from packed evidence",
                            ),
                        )
                else
                    cp(evidence_path, destination)
                end
            end
            pack_capture(capture_directory, archive)
            receipt = Dict(
                "schema_version" => 1,
                "site" => site,
                "status" => capture_receipt["status"],
                "archive_path" => abspath(archive),
                "archive_sha256" => sha256_path(archive),
                "archive_bytes" => filesize(archive),
                "capture_receipt_sha256" =>
                    sha256_path(capture_receipt_path),
                "activity_report_sha256" => sha256_path(activity_path),
                "trajectory_schema_sha256" => schema_sha256,
                "policy_inventory_sha256" =>
                    plan["policy_inventory_sha256"],
                "source_category" => site_plan["source_category"],
                "source_identifier" => site_plan["source_identifier"],
                "full_name" => site_plan["full_name"],
                "policy_status" => site_plan["policy_status"],
                "policy_reference" => site_plan["policy_reference"],
                "attribution_status" => site_plan["attribution_status"],
                "source_chain_status" => site_plan["source_chain_status"],
                "redistribution_status" =>
                    site_plan["redistribution_status"],
                "unresolved_reason" => site_plan["unresolved_reason"],
                "artifact_policy" => "external_only",
                "missing_fields" => activity.missing,
                "inactive_fields" => activity.inactive,
                "real_acceptance" =>
                    capture_receipt["status"] == "complete",
                "acceptance_blockers" =>
                    capture_receipt["status"] == "complete" ? String[] :
                    plan["acceptance_blockers"],
            )
            if capture_receipt["status"] == "complete"
                for key in (
                    "reference_kind",
                    "oracle_contract",
                    "synthetic_data_used",
                    "complete_seasonal_cycle",
                    "step_count",
                    "capture_year",
                    "capture_event_count",
                    "capture_source_calendar",
                    "capture_first_time",
                    "capture_last_time",
                    "capture_next_year_start",
                    "oracle_daily_time_file_sha256",
                    "candidate_daily_time_file_sha256",
                    "oracle_daily_time_sha256",
                    "candidate_daily_time_sha256",
                    "nonperturbation_result",
                    "stage_b_status",
                    "replay_claimed",
                    "stage_c_semantics_excluded",
                    "deferred_issue",
                    "provenance",
                )
                    receipt[key] = capture_receipt[key]
                end
            end
            write_toml_atomic(receipt_path, receipt)
            if !isnothing(resume)
                validate_resume_report(
                    resume.validate_existing!(site, archive, receipt_path),
                    site,
                )
            end
            push!(
                results,
                (;
                    site,
                    status = "packed",
                    issues = String[],
                    missing_fields = activity.missing,
                    inactive_fields = activity.inactive,
                ),
            )
        catch error
            issue = sprint(showerror, error)
            ispath(archive) && rm(archive)
            ispath(receipt_path) && rm(receipt_path)
            failure = failure_result(
                site,
                [issue],
                activity.missing,
                activity.inactive,
            )
            push!(results, failure)
            failure_receipt = Dict(
                "schema_version" => 1,
                "site" => site,
                "status" => "failed",
                "issues" => failure.issues,
                "missing_fields" => failure.missing_fields,
                "inactive_fields" => failure.inactive_fields,
            )
            merge!(
                failure_receipt,
                failure_diagnostics(error, archive_root, site),
            )
            write_toml_atomic(
                joinpath(archive_root, site * ".failure.toml"),
                failure_receipt,
            )
            println(stderr, string(site, " failed: ", issue))
            stop_on_failure && break
        finally
            ispath(workspace) && rm(workspace; recursive = true)
        end
    end
    packed_count = count(result -> result.status == "packed", results)
    failed_count = length(results) - packed_count
    summary = Dict(
        "schema_version" => 1,
        "site_count" => length(results),
        "packed_count" => packed_count,
        "failed_count" => failed_count,
        "real_acceptance" =>
            get(plan, "real_acceptance", false) && failed_count == 0,
        "site" => [
            Dict(
                "name" => result.site,
                "status" => result.status,
                "issues" => result.issues,
                "missing_fields" => result.missing_fields,
                "inactive_fields" => result.inactive_fields,
            ) for result in results
        ],
    )
    if !isnothing(resume)
        completed =
            length(results) == length(sites) &&
            failed_count == 0 &&
            all(result -> result.status == "packed", results)
        packages = if completed
            validated_package_inventory(
                sites,
                archive_root,
                resume.validate_existing!,
            )
        else
            Dict{String, Any}[]
        end
        inventory_path =
            joinpath(archive_root, "campaign_package_inventory.toml")
        inventory_sha256 = if completed
            inventory = Dict(
                "schema_version" => 1,
                "status" => "complete",
                "full_coverage" => true,
                "site_count" => length(sites),
                "plan_sha256" => resume.plan_sha256,
                "campaign_config_sha256" => resume.config_sha256,
                "package" => packages,
            )
            write_toml_atomic(inventory_path, inventory)
            sha256_path(inventory_path)
        else
            ""
        end
        summary["status"] = completed ? "complete" : "failed"
        summary["full_coverage"] = completed
        summary["plan_sha256"] = resume.plan_sha256
        summary["campaign_config_sha256"] = resume.config_sha256
        summary["package_count"] = length(packages)
        summary["package"] = packages
        summary["package_inventory_path"] =
            completed ? abspath(inventory_path) : ""
        summary["package_inventory_sha256"] = inventory_sha256
        summary["attempt_count"] = 2
        summary["attempt"] = [
            merge(
                copy(resume.interrupted_attempt),
                Dict(
                    "interruption_receipt_sha256" =>
                        resume.interruption_receipt_sha256,
                ),
            ),
            Dict(
                "status" => completed ? "complete" : "failed",
                "full_coverage" => completed,
                "start_site" => sites[resume.next_index]["name"],
                "completed_site_count" => packed_count,
                "plan_sha256" => resume.plan_sha256,
                "campaign_config_sha256" => resume.config_sha256,
                "package_count" => length(packages),
                "package_inventory_sha256" => inventory_sha256,
            ),
        ]
        completed || (summary["real_acceptance"] = false)
    end
    write_toml_atomic(summary_path, summary)
    return (;
        site_count = length(results),
        packed_count,
        failed_count,
        site = results,
        summary_path,
    )
end

end
