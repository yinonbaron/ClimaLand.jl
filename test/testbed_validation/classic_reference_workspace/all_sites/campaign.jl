module ClassicAllSitesCampaign

import SHA: sha256
import TOML

include(joinpath(@__DIR__, "..", "de_hai", "compare_de_hai_output.jl"))
using .DEHaiOutputComparison: compare_de_hai_directories

export compare_published_site,
    discover_sites, main, write_campaign_summary, write_site_receipt

const EXPECTED_SITE_COUNT = 59
const REQUIRED_BASE_EVIDENCE = (
    "command.txt",
    "run.log",
    "prepared-inputs.sha256",
    "initial-restart.sha256",
    "published-comparison.toml",
)
const REQUIRED_SUCCESS_EVIDENCE = ("final-restart.sha256", "outputs.sha256")

function directory_names(root; require_netcdf = false)
    isdir(root) || throw(ArgumentError("not a directory: $root"))
    names = String[]
    for name in readdir(root)
        path = joinpath(root, name)
        isdir(path) || continue
        require_netcdf && !isdir(joinpath(path, "netCDF")) && continue
        push!(names, name)
    end
    return sort!(names)
end

"""
    discover_sites(configuration_root, published_root; expected_count = 59)

Return the sorted site inventory only when the released configurations and
published benchmark contain exactly the same expected sites.
"""
function discover_sites(
    configuration_root,
    published_root;
    expected_count = EXPECTED_SITE_COUNT,
)
    configurations = directory_names(configuration_root)
    published = directory_names(published_root; require_netcdf = true)
    configured_only = setdiff(configurations, published)
    published_only = setdiff(published, configurations)
    isempty(configured_only) || throw(
        ArgumentError(
            "configured-only site(s): $(join(configured_only, ", "))",
        ),
    )
    isempty(published_only) || throw(
        ArgumentError("published-only site(s): $(join(published_only, ", "))"),
    )
    length(configurations) == expected_count || throw(
        ArgumentError(
            "expected $expected_count sites, found $(length(configurations))",
        ),
    )
    return configurations
end

function write_toml(path, table)
    mkpath(dirname(path))
    temporary = path * ".tmp"
    open(temporary, "w") do io
        TOML.print(io, table; sorted = true)
    end
    mv(temporary, path; force = true)
    return path
end

function comparison_file_summary(comparison)
    variable = comparison.variable
    coordinate_values_match = all(
        coordinate.values.ok for coordinate in values(comparison.coordinates)
    )
    return Dict{String, Any}(
        "filename" => comparison.filename,
        "variable" => comparison.variable_name,
        "status" => comparison.ok ? "match" : "mismatch",
        "metadata_mismatches" => comparison.metadata_mismatches,
        "values_match" => !isnothing(variable) && variable.values.ok,
        "coordinate_values_match" => coordinate_values_match,
        "value_failure_count" =>
            isnothing(variable) ? 0 : variable.values.failure_count,
        "missing_mask_mismatch_count" =>
            isnothing(variable) ? 0 : variable.values.missing_mismatch_count,
        "overlap_record_count" => comparison.overlap.record_count,
    )
end

function comparison_table(site, report)
    passed_files = count(comparison -> comparison.ok, report.file_comparisons)
    return Dict{String, Any}(
        "schema_version" => 1,
        "site" => site,
        "reference_kind" => "published_benchmark",
        "candidate_kind" => "fresh_local_fortran",
        "published_parity_claimed" => false,
        "status" => report.ok ? "match" : "mismatch",
        "reference_directory" => report.reference_directory,
        "candidate_directory" => report.candidate_directory,
        "reference_modeled_files" => report.reference_file_count,
        "candidate_modeled_files" => report.candidate_file_count,
        "compared_files" => length(report.compared_files),
        "passed_files" => passed_files,
        "failed_files" => length(report.file_comparisons) - passed_files,
        "reference_only_files" => report.reference_only_files,
        "candidate_only_files" => report.candidate_only_files,
        "reference_excluded_files" => report.reference_excluded_files,
        "candidate_excluded_files" => report.candidate_excluded_files,
        "file" => comparison_file_summary.(report.file_comparisons),
    )
end

"""
    compare_published_site(site, published_directory, local_directory, output)

Compare values and metadata exactly. The local result is recorded as a fresh
Fortran oracle candidate; a mismatch never becomes a published-parity claim.
"""
function compare_published_site(
    site,
    published_directory,
    local_directory,
    output,
)
    try
        report =
            compare_de_hai_directories(published_directory, local_directory)
        table = comparison_table(site, report)
        write_toml(output, table)
        return (
            status = table["status"],
            compared_files = table["compared_files"],
            passed_files = table["passed_files"],
            failed_files = table["failed_files"],
        )
    catch error
        table = Dict{String, Any}(
            "schema_version" => 1,
            "site" => site,
            "reference_kind" => "published_benchmark",
            "candidate_kind" => "fresh_local_fortran",
            "published_parity_claimed" => false,
            "status" => "error",
            "error" => sprint(showerror, error),
            "compared_files" => 0,
            "passed_files" => 0,
            "failed_files" => 0,
        )
        write_toml(output, table)
        return (
            status = "error",
            compared_files = 0,
            passed_files = 0,
            failed_files = 0,
        )
    end
end

sha256_file(path) = bytes2hex(open(sha256, path))

function required_file(path, label)
    isfile(path) || throw(ArgumentError("missing $label: $path"))
    islink(path) && throw(ArgumentError("$label must not be a symlink: $path"))
    filesize(path) > 0 || throw(ArgumentError("empty $label: $path"))
    return path
end

function evidence_files(site, evidence_directory, run_site_directory; success)
    relative_files = collect(REQUIRED_BASE_EVIDENCE)
    success && append!(relative_files, REQUIRED_SUCCESS_EVIDENCE)
    files = Pair{String, String}[
        name => required_file(joinpath(evidence_directory, name), name) for
        name in relative_files
    ]
    append!(
        files,
        [
            "job_options_file.txt" => required_file(
                joinpath(run_site_directory, "job_options_file.txt"),
                "generated job options",
            ),
            "$(site)_init.nc" => required_file(
                joinpath(run_site_directory, "$(site)_init.nc"),
                "generated initialization",
            ),
            "rsfile.nc" => required_file(
                joinpath(run_site_directory, "rsfile.nc"),
                "restart",
            ),
        ],
    )
    return files
end

"""
    write_site_receipt(...; run_exit_code, comparison_exit_code)

Write a checksummed receipt for one site. Successful executions must retain
the prepared configuration, initial and final restart hashes, output hashes,
command, log, and published comparison summary.
"""
function write_site_receipt(
    site,
    evidence_directory,
    run_site_directory,
    output_directory,
    receipt_path;
    run_exit_code,
    comparison_exit_code,
)
    success = run_exit_code == 0
    files =
        evidence_files(site, evidence_directory, run_site_directory; success)
    if success
        isdir(output_directory) ||
            throw(ArgumentError("missing output directory: $output_directory"))
        any(
            endswith(lowercase(name), ".nc") for
            name in readdir(output_directory)
        ) || throw(ArgumentError("output directory has no NetCDF files"))
    end

    comparison = TOML.parsefile(
        joinpath(evidence_directory, "published-comparison.toml"),
    )
    comparison_status = get(comparison, "status", "error")
    comparison_status in ("match", "mismatch", "error") || throw(
        ArgumentError(
            "invalid published comparison status: $comparison_status",
        ),
    )
    hashes = Dict(label => sha256_file(path) for (label, path) in files)
    local_oracle_status = success ? "available" : "unavailable"
    table = Dict{String, Any}(
        "schema_version" => 1,
        "site" => site,
        "local_oracle_kind" => "fresh_local_fortran",
        "local_oracle_status" => local_oracle_status,
        "published_reference_kind" => "published_benchmark",
        "published_comparison_status" => comparison_status,
        "published_parity_claimed" => false,
        "run_exit_code" => run_exit_code,
        "comparison_exit_code" => comparison_exit_code,
        "run_site_directory" => abspath(run_site_directory),
        "output_directory" => abspath(output_directory),
        "evidence_sha256" => hashes,
    )
    write_toml(receipt_path, table)
    return (;
        local_oracle_status,
        published_comparison_status = comparison_status,
    )
end

function normalized_path(path)
    path isa AbstractString ||
        throw(ArgumentError("recorded path is not a string"))
    isabspath(path) ||
        throw(ArgumentError("recorded path is not absolute: $path"))
    return normpath(path)
end

function require_same_path(recorded, expected, label)
    normalized_path(recorded) == normalized_path(expected) ||
        throw(ArgumentError("$label path differs: $recorded != $expected"))
    return nothing
end

function read_sha256_manifest(path, label)
    entries = Pair{String, String}[]
    for (line_number, line) in enumerate(eachline(path))
        parsed = match(r"^([0-9a-f]{64})  (.+)$", line)
        isnothing(parsed) &&
            throw(ArgumentError("invalid $label entry at $path:$line_number"))
        recorded_path = normalized_path(parsed.captures[2])
        push!(entries, recorded_path => parsed.captures[1])
    end
    isempty(entries) && throw(ArgumentError("empty $label: $path"))
    paths = first.(entries)
    length(paths) == length(unique(paths)) ||
        throw(ArgumentError("duplicate path in $label: $path"))
    return entries
end

function validate_current_manifest(path, label)
    entries = read_sha256_manifest(path, label)
    for (artifact, expected_hash) in entries
        required_file(artifact, "$label artifact")
        sha256_file(artifact) == expected_hash ||
            throw(ArgumentError("$label artifact hash differs: $artifact"))
    end
    return entries
end

function validate_manifests(
    site,
    evidence_directory,
    run_site,
    output_directory,
)
    job_options = joinpath(run_site, "job_options_file.txt")
    initialization = joinpath(run_site, "$(site)_init.nc")
    restart = joinpath(run_site, "rsfile.nc")

    prepared_path = joinpath(evidence_directory, "prepared-inputs.sha256")
    prepared = validate_current_manifest(prepared_path, "prepared inputs")
    prepared_paths = Set(first.(prepared))
    for configuration in (job_options, initialization)
        normalized_path(configuration) in prepared_paths || throw(
            ArgumentError(
                "prepared inputs omit generated configuration: $configuration",
            ),
        )
    end

    initial_path = joinpath(evidence_directory, "initial-restart.sha256")
    initial = read_sha256_manifest(initial_path, "initial restart")
    length(initial) == 1 ||
        throw(ArgumentError("initial restart manifest must contain one entry"))
    require_same_path(first(initial[1]), restart, "initial restart")
    last(initial[1]) == sha256_file(initialization) || throw(
        ArgumentError(
            "initial restart hash differs from generated initialization",
        ),
    )

    final_path = joinpath(evidence_directory, "final-restart.sha256")
    final = validate_current_manifest(final_path, "final restart")
    length(final) == 1 ||
        throw(ArgumentError("final restart manifest must contain one entry"))
    require_same_path(first(final[1]), restart, "final restart")

    outputs_path = joinpath(evidence_directory, "outputs.sha256")
    outputs = validate_current_manifest(outputs_path, "outputs")
    recorded_outputs = Set(first.(outputs))
    current_outputs = Set(
        normalized_path(joinpath(output_directory, name)) for
        name in readdir(output_directory) if endswith(lowercase(name), ".nc")
    )
    isempty(current_outputs) &&
        throw(ArgumentError("output directory has no NetCDF files"))
    recorded_outputs == current_outputs ||
        throw(ArgumentError("output manifest does not match output directory"))
    return nothing
end

function validate_published_comparison(site, receipt, evidence_directory)
    comparison_path = joinpath(evidence_directory, "published-comparison.toml")
    comparison = TOML.parsefile(comparison_path)
    get(comparison, "schema_version", nothing) == 1 || throw(
        ArgumentError("unsupported published comparison schema for $site"),
    )
    get(comparison, "site", nothing) == site ||
        throw(ArgumentError("published comparison site differs for $site"))
    status = get(comparison, "status", nothing)
    status in ("match", "mismatch") ||
        throw(ArgumentError("published comparison did not complete for $site"))
    status == receipt["published_comparison_status"] ||
        throw(ArgumentError("published comparison status differs for $site"))
    get(comparison, "candidate_kind", nothing) == "fresh_local_fortran" ||
        throw(ArgumentError("invalid published comparison candidate for $site"))
    get(comparison, "reference_kind", nothing) == "published_benchmark" ||
        throw(ArgumentError("invalid published comparison reference for $site"))
    get(comparison, "published_parity_claimed", nothing) == false ||
        throw(ArgumentError("published parity must remain unclaimed for $site"))
    require_same_path(
        get(comparison, "candidate_directory", nothing),
        receipt["output_directory"],
        "published comparison candidate",
    )
    return nothing
end

function validate_site_receipt(site, evidence_directory, receipt_path)
    receipt = TOML.parsefile(receipt_path)
    get(receipt, "schema_version", nothing) == 1 || throw(
        ArgumentError("unsupported receipt schema for $site: $receipt_path"),
    )
    get(receipt, "site", nothing) == site ||
        throw(ArgumentError("receipt site does not match $site: $receipt_path"))
    get(receipt, "local_oracle_kind", nothing) == "fresh_local_fortran" ||
        throw(ArgumentError("invalid local oracle kind for $site"))
    get(receipt, "local_oracle_status", nothing) == "available" ||
        throw(ArgumentError("local oracle is unavailable for $site"))
    get(receipt, "published_reference_kind", nothing) ==
    "published_benchmark" ||
        throw(ArgumentError("invalid published reference kind for $site"))
    get(receipt, "published_comparison_status", nothing) in
    ("match", "mismatch") ||
        throw(ArgumentError("published comparison is incomplete for $site"))
    get(receipt, "published_parity_claimed", nothing) == false ||
        throw(ArgumentError("published parity must remain unclaimed for $site"))
    get(receipt, "run_exit_code", nothing) == 0 ||
        throw(ArgumentError("CLASSIC execution failed for $site"))
    get(receipt, "comparison_exit_code", nothing) == 0 ||
        throw(ArgumentError("published comparison command failed for $site"))

    run_site = normalized_path(get(receipt, "run_site_directory", nothing))
    output_directory =
        normalized_path(get(receipt, "output_directory", nothing))
    isdir(run_site) || throw(ArgumentError("missing run directory for $site"))
    isdir(output_directory) ||
        throw(ArgumentError("missing output directory for $site"))
    basename(run_site) == site ||
        throw(ArgumentError("run directory does not identify $site"))
    basename(output_directory) == "netCDF" ||
        throw(ArgumentError("invalid output directory for $site"))
    basename(dirname(output_directory)) == site ||
        throw(ArgumentError("output directory does not identify $site"))
    dirname(run_site) == dirname(dirname(dirname(output_directory))) || throw(
        ArgumentError(
            "run and output directories have different roots for $site",
        ),
    )

    files = evidence_files(site, evidence_directory, run_site; success = true)
    hashes = get(receipt, "evidence_sha256", nothing)
    hashes isa AbstractDict ||
        throw(ArgumentError("receipt omits evidence hashes for $site"))
    expected_labels = Set(first.(files))
    Set(keys(hashes)) == expected_labels ||
        throw(ArgumentError("receipt evidence inventory differs for $site"))
    for (label, artifact) in files
        expected_hash = hashes[label]
        expected_hash isa AbstractString &&
        occursin(r"^[0-9a-f]{64}$", expected_hash) ||
            throw(ArgumentError("invalid recorded hash for $site $label"))
        sha256_file(artifact) == expected_hash ||
            throw(ArgumentError("evidence hash differs for $site $label"))
    end

    validate_manifests(site, evidence_directory, run_site, output_directory)
    validate_published_comparison(site, receipt, evidence_directory)
    return receipt
end

function read_site_receipts(sites, evidence_root)
    length(sites) == length(unique(sites)) ||
        throw(ArgumentError("campaign site list contains duplicates"))
    receipts = Dict{String, Any}[]
    for site in sites
        path = required_file(
            joinpath(evidence_root, site, "receipt.toml"),
            "site receipt",
        )
        receipt = validate_site_receipt(site, dirname(path), path)
        push!(receipts, receipt)
    end
    return receipts
end

"""
    write_campaign_summary(sites, evidence_root, output)

Require one receipt per requested site. A completed campaign may retain
published mismatches, but comparison errors or unavailable local oracles make
the campaign incomplete.
"""
function write_campaign_summary(sites, evidence_root, output)
    receipts = read_site_receipts(sites, evidence_root)
    available = count(
        receipt -> receipt["local_oracle_status"] == "available",
        receipts,
    )
    matches = count(
        receipt -> receipt["published_comparison_status"] == "match",
        receipts,
    )
    mismatches = count(
        receipt -> receipt["published_comparison_status"] == "mismatch",
        receipts,
    )
    errors = length(receipts) - matches - mismatches
    ok = available == length(sites) && errors == 0
    table = Dict{String, Any}(
        "schema_version" => 1,
        "campaign_status" => ok ? "complete" : "incomplete",
        "site_count" => length(sites),
        "local_oracle_kind" => "fresh_local_fortran",
        "local_oracle_available" => available,
        "published_reference_kind" => "published_benchmark",
        "published_matches" => matches,
        "published_mismatches" => mismatches,
        "published_comparison_errors" => errors,
        "published_parity_claimed" => false,
        "site" => [
            Dict(
                "name" => receipt["site"],
                "local_oracle_status" => receipt["local_oracle_status"],
                "published_comparison_status" =>
                    receipt["published_comparison_status"],
            ) for receipt in receipts
        ],
    )
    write_toml(output, table)
    return (
        ok,
        local_oracle_available = available,
        published_matches = matches,
        published_mismatches = mismatches,
        published_comparison_errors = errors,
    )
end

function read_site_list(path)
    sites = filter(!isempty, strip.(readlines(path)))
    sites == sort(sites) || throw(ArgumentError("site list must be sorted"))
    length(sites) == length(unique(sites)) ||
        throw(ArgumentError("site list contains duplicates"))
    return sites
end

const USAGE = """usage:
  campaign.jl validate-sites CONFIGURATION_ROOT PUBLISHED_ROOT SITE_LIST
  campaign.jl compare-site SITE PUBLISHED_NETCDF LOCAL_NETCDF SUMMARY
  campaign.jl site-receipt SITE EVIDENCE_DIR RUN_SITE_DIR OUTPUT_DIR RECEIPT RUN_EXIT COMPARE_EXIT
  campaign.jl campaign-summary SITE_LIST EVIDENCE_ROOT SUMMARY
"""

function main(args = ARGS; stdout = stdout, stderr = stderr)
    try
        if length(args) == 4 && args[1] == "validate-sites"
            sites = discover_sites(args[2], args[3])
            open(args[4], "w") do io
                foreach(site -> println(io, site), sites)
            end
            println(stdout, "validated $(length(sites)) sites")
            return 0
        elseif length(args) == 5 && args[1] == "compare-site"
            result = compare_published_site(args[2], args[3], args[4], args[5])
            println(stdout, "$(args[2]) published comparison: $(result.status)")
            return result.status == "error" ? 2 : 0
        elseif length(args) == 8 && args[1] == "site-receipt"
            result = write_site_receipt(
                args[2],
                args[3],
                args[4],
                args[5],
                args[6];
                run_exit_code = parse(Int, args[7]),
                comparison_exit_code = parse(Int, args[8]),
            )
            println(
                stdout,
                "$(args[2]) local oracle: $(result.local_oracle_status)",
            )
            return result.local_oracle_status == "available" ? 0 : 1
        elseif length(args) == 4 && args[1] == "campaign-summary"
            sites = read_site_list(args[2])
            length(sites) == EXPECTED_SITE_COUNT || throw(
                ArgumentError(
                    "expected $EXPECTED_SITE_COUNT sites, found $(length(sites))",
                ),
            )
            result = write_campaign_summary(sites, args[3], args[4])
            println(
                stdout,
                "campaign: $(result.ok ? "complete" : "incomplete")",
            )
            return result.ok ? 0 : 1
        end
        print(stderr, USAGE)
        return 2
    catch error
        println(stderr, "error: ", sprint(showerror, error))
        return 2
    end
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(ClassicAllSitesCampaign.main())
end
