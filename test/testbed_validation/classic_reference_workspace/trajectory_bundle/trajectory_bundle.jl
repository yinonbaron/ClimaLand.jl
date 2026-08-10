module ClassicTrajectoryBundle

using Dates
import SHA
import TOML

export TrajectoryReplay,
    TrajectoryStep,
    load_bundle_schema,
    open_replay,
    validate_bundle,
    verify_replay_acceptance

const SHA256_PATTERN = r"^[0-9a-f]{64}$"
const COMMIT_PATTERN = r"^[0-9a-f]{40}$"

const SECTIONS = Set((
    "static_data",
    "initial_state",
    "drivers",
    "reference_state",
    "audit_diagnostics",
))

const SECTION_ROLES = Dict(
    "static_data" => Set(("static_data", "parameter")),
    "initial_state" => Set(("owned_state",)),
    "drivers" => Set(("external_forcing",)),
    "reference_state" => Set(("reference_state",)),
    "audit_diagnostics" => Set(("audit_diagnostic",)),
)
const SAMPLING = Set((
    "constant",
    "beginning",
    "end",
    "instantaneous",
    "interval_mean",
    "interval_sum",
))
const DTYPES = Dict("float64" => Float64, "int32" => Int32)
const PROVENANCE_HASHES = (
    "source_archive_sha256",
    "source_tree_sha256",
    "executable_sha256",
    "parameter_namelist_sha256",
    "job_options_sha256",
    "initial_condition_sha256",
    "instrumentation_patch_sha256",
    "schema_sha256",
)

function load_bundle_schema(path)
    isfile(path) || throw(ArgumentError("bundle schema does not exist: $path"))
    schema = TOML.parsefile(path)
    get(schema, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported bundle schema_version"))
    fields = copy(get(schema, "field", Any[]))
    for group in get(get(schema, "groups", Dict()), "field", Any[])
        names = get(group, "names", Any[])
        isempty(names) &&
            throw(ArgumentError("bundle schema field group has no names"))
        for name in names
            field =
                Dict(key => value for (key, value) in group if key != "names")
            field["name"] = name
            push!(fields, field)
        end
    end
    schema["field"] = fields
    isempty(fields) && throw(ArgumentError("bundle schema has no fields"))
    names = String[]
    for field in fields
        all(
            haskey(field, key) for key in (
                "name",
                "section",
                "role",
                "units",
                "dtype",
                "dimensions",
                "sampling",
                "application_phase",
            )
        ) || throw(ArgumentError("bundle schema field has incomplete metadata"))
        field["section"] in SECTIONS ||
            throw(ArgumentError("invalid bundle section for $(field["name"])"))
        field["role"] in SECTION_ROLES[field["section"]] ||
            throw(ArgumentError("ambiguous role for $(field["name"])"))
        haskey(DTYPES, field["dtype"]) ||
            throw(ArgumentError("unsupported dtype for $(field["name"])"))
        field["sampling"] in SAMPLING ||
            throw(ArgumentError("ambiguous sampling for $(field["name"])"))
        isempty(field["units"]) &&
            throw(ArgumentError("missing units for $(field["name"])"))
        dimensions = get(schema, "dimensions", Dict())
        all(
            haskey(dimensions, dimension) for dimension in field["dimensions"]
        ) || throw(ArgumentError("unknown dimension for $(field["name"])"))
        push!(names, field["name"])
    end
    length(unique(names)) == length(names) ||
        throw(ArgumentError("bundle schema contains duplicate fields"))
    return schema
end
valid_sha256(value) =
    value isa AbstractString && occursin(SHA256_PATTERN, value)
valid_commit(value) =
    value isa AbstractString && occursin(COMMIT_PATTERN, value)
sha256sum(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

function safe_payload_path(root, relative_path)
    relative_path isa AbstractString || return nothing
    root_path = realpath(root)
    path = normpath(joinpath(root_path, relative_path))
    relative = relpath(path, root_path)
    if relative == ".." ||
       startswith(relative, ".." * Base.Filesystem.path_separator)
        return nothing
    end
    ispath(path) && begin
        resolved = realpath(path)
        resolved_relative = relpath(resolved, root_path)
        if resolved_relative == ".." || startswith(
            resolved_relative,
            ".." * Base.Filesystem.path_separator,
        )
            return nothing
        end
        path = resolved
    end
    return path
end

function validate_record!(issues, root, record, expected, dimensions, context)
    required = (
        "name",
        "section",
        "role",
        "units",
        "dtype",
        "dimensions",
        "shape",
        "sampling",
        "application_phase",
        "path",
        "bytes",
        "sha256",
    )
    all(haskey(record, key) for key in required) || begin
        push!(issues, "$context has incomplete field metadata")
        return
    end
    name = record["name"]
    isnothing(expected) && begin
        push!(issues, "$context contains undeclared field $name")
        return
    end
    for key in (
        "section",
        "role",
        "units",
        "dtype",
        "dimensions",
        "sampling",
        "application_phase",
    )
        record[key] == expected[key] ||
            push!(issues, "$name $key does not match schema")
    end
    expected_shape =
        [dimensions[dimension] for dimension in expected["dimensions"]]
    record["shape"] == expected_shape ||
        push!(issues, "$name shape does not match dimensions")
    element_type = get(DTYPES, record["dtype"], nothing)
    isnothing(element_type) && begin
        push!(issues, "$name has unsupported dtype")
        return
    end
    expected_bytes = prod(expected_shape; init = 1) * sizeof(element_type)
    record["bytes"] == expected_bytes ||
        push!(issues, "$name byte count does not match shape and dtype")
    path = safe_payload_path(root, record["path"])
    isnothing(path) && begin
        push!(issues, "$name payload escapes bundle")
        return
    end
    isfile(path) || begin
        push!(issues, "$name payload is missing")
        return
    end
    filesize(path) == record["bytes"] ||
        push!(issues, "$name payload byte count is inconsistent")
    valid_sha256(record["sha256"]) && sha256sum(path) == record["sha256"] ||
        push!(issues, "$name payload SHA-256 is inconsistent")
end

function validate_record_set!(
    issues,
    root,
    records,
    expected_fields,
    dimensions,
    context,
)
    names = [get(record, "name", "") for record in records]
    length(unique(names)) == length(names) ||
        push!(issues, "$context contains duplicate fields")
    actual = Dict(get(record, "name", "") => record for record in records)
    expected = Dict(field["name"] => field for field in expected_fields)
    for name in sort!(collect(setdiff(Set(keys(expected)), Set(keys(actual)))))
        push!(issues, "$context is missing schema field $name")
    end
    for (name, record) in actual
        validate_record!(
            issues,
            root,
            record,
            get(expected, name, nothing),
            dimensions,
            context,
        )
    end
end

function parse_time(value, label, issues)
    value isa AbstractString || begin
        push!(issues, "$label is not a timestamp")
        return nothing
    end
    try
        DateTime(value)
    catch
        push!(issues, "$label is not an ISO-8601 timestamp")
        nothing
    end
end

function validate_bundle(root, schema_path)
    issues = String[]
    schema = try
        load_bundle_schema(schema_path)
    catch error
        return (;
            ok = false,
            issues = [sprint(showerror, error)],
            manifest = nothing,
            schema = nothing,
        )
    end
    manifest_path = joinpath(root, "manifest.toml")
    isfile(manifest_path) || return (;
        ok = false,
        issues = ["bundle is missing manifest.toml"],
        manifest = nothing,
        schema,
    )
    manifest = try
        TOML.parsefile(manifest_path)
    catch error
        return (;
            ok = false,
            issues = ["invalid manifest.toml: $(sprint(showerror, error))"],
            manifest = nothing,
            schema,
        )
    end

    get(manifest, "schema_version", nothing) == 1 ||
        push!(issues, "unsupported bundle schema_version")
    get(manifest, "storage_order", nothing) == schema["storage_order"] ||
        push!(issues, "bundle storage order does not match schema")
    get(manifest, "endianness", nothing) == schema["endianness"] ||
        push!(issues, "bundle endianness does not match schema")
    trajectory = get(manifest, "trajectory", Dict())
    for key in (
        "site",
        "calendar",
        "time_standard",
        "timestamp_format",
        "evidence_status",
    )
        haskey(trajectory, key) ||
            push!(issues, "trajectory metadata is missing $key")
    end
    get(trajectory, "calendar", nothing) ==
    get(schema["time"], "calendar", nothing) ||
        push!(issues, "trajectory calendar does not match schema")
    get(trajectory, "time_standard", nothing) ==
    get(schema["time"], "time_standard", nothing) ||
        push!(issues, "trajectory time standard does not match schema")
    get(trajectory, "timestamp_format", nothing) ==
    get(schema["time"], "timestamp_format", nothing) ||
        push!(issues, "trajectory timestamp format does not match schema")

    provenance = get(manifest, "provenance", Dict())
    for key in PROVENANCE_HASHES
        valid_sha256(get(provenance, key, nothing)) ||
            push!(issues, "provenance has missing or invalid $key")
    end
    valid_commit(get(provenance, "source_commit", nothing)) ||
        push!(issues, "provenance has missing or invalid source_commit")
    get(provenance, "schema_sha256", nothing) == sha256sum(schema_path) ||
        push!(issues, "schema SHA-256 does not match provenance")

    dimensions = get(manifest, "dimensions", Dict())
    expected_dimensions = collect(keys(schema["dimensions"]))
    Set(keys(dimensions)) == Set(expected_dimensions) ||
        push!(issues, "bundle dimensions do not match schema dimensions")
    for dimension in expected_dimensions
        value = get(dimensions, dimension, nothing)
        value isa Integer && value > 0 ||
            push!(issues, "dimension $dimension must be a positive integer")
        value == schema["dimensions"][dimension] || push!(
            issues,
            "dimension $dimension does not match the DE-Hai schema extent",
        )
    end
    dimensions_ok = all(
        get(dimensions, dimension, nothing) isa Integer for
        dimension in expected_dimensions
    )
    dimensions_ok || return (; ok = false, issues, manifest, schema)

    fixed_expected = filter(
        field -> field["section"] in ("static_data", "initial_state"),
        schema["field"],
    )
    validate_record_set!(
        issues,
        root,
        get(manifest, "field", Any[]),
        fixed_expected,
        dimensions,
        "fixed fields",
    )

    steps = get(manifest, "step", Any[])
    isempty(steps) && push!(issues, "trajectory has no steps")
    step_expected = filter(
        field -> field["section"] in
        ("drivers", "reference_state", "audit_diagnostics"),
        schema["field"],
    )
    previous_end = nothing
    required_days = schema["time"]["step_days"]
    for (position, step) in enumerate(steps)
        get(step, "index", nothing) == position ||
            push!(issues, "step index is not chronological")
        start = parse_time(
            get(step, "time_start", nothing),
            "step $position time_start",
            issues,
        )
        stop = parse_time(
            get(step, "time_end", nothing),
            "step $position time_end",
            issues,
        )
        if !isnothing(start) && !isnothing(stop)
            start < stop ||
                push!(issues, "step $position has nonpositive time bounds")
            duration_days = Dates.value(stop - start) / 86_400_000
            duration_days == required_days || push!(
                issues,
                "step $position time bounds do not match required duration",
            )
            get(step, "duration_days", nothing) == required_days || push!(
                issues,
                "step $position duration_days does not match schema",
            )
            !isnothing(previous_end) &&
                start != previous_end &&
                push!(
                    issues,
                    "step $position is not contiguous with the previous step",
                )
            previous_end = stop
        end
        validate_record_set!(
            issues,
            root,
            get(step, "field", Any[]),
            step_expected,
            dimensions,
            "step $position",
        )
    end
    return (; ok = isempty(issues), issues, manifest, schema)
end
struct TrajectoryStep
    index::Int
    time_start::DateTime
    time_end::DateTime
    drivers::Dict{String, Any}
    reference_state::Dict{String, Any}
    audit_diagnostics::Dict{String, Any}
end

struct TrajectoryReplay
    provenance::Dict{String, Any}
    static_data::Dict{String, Any}
    initial_state::Dict{String, Any}
    steps::Vector{TrajectoryStep}
    evidence_status::String
end

storage_type(::Type{Float64}) = UInt64
storage_type(::Type{Int32}) = UInt32

from_little_endian(::Type{Float64}, value::UInt64) =
    reinterpret(Float64, ltoh(value))
from_little_endian(::Type{Int32}, value::UInt32) =
    reinterpret(Int32, ltoh(value))

function read_record(root, record)
    element_type = DTYPES[record["dtype"]]
    storage = storage_type(element_type)
    count = prod(record["shape"]; init = 1)
    raw = open(joinpath(root, record["path"]), "r") do io
        read!(io, Vector{storage}(undef, count))
    end
    values = [from_little_endian(element_type, value) for value in raw]
    return reshape(values, Tuple(record["shape"]))
end

function read_section(root, records, section)
    return Dict(
        record["name"] => read_record(root, record) for
        record in records if record["section"] == section
    )
end

function open_replay(root, schema_path)
    report = validate_bundle(root, schema_path)
    report.ok || throw(
        ArgumentError(
            "invalid trajectory bundle: $(join(report.issues, "; "))",
        ),
    )
    manifest = report.manifest
    fixed = manifest["field"]
    static_data = read_section(root, fixed, "static_data")
    initial_state = read_section(root, fixed, "initial_state")
    steps = TrajectoryStep[]
    for step in manifest["step"]
        records = step["field"]
        push!(
            steps,
            TrajectoryStep(
                step["index"],
                DateTime(step["time_start"]),
                DateTime(step["time_end"]),
                read_section(root, records, "drivers"),
                read_section(root, records, "reference_state"),
                read_section(root, records, "audit_diagnostics"),
            ),
        )
    end
    return TrajectoryReplay(
        manifest["provenance"],
        static_data,
        initial_state,
        steps,
        manifest["trajectory"]["evidence_status"],
    )
end
function verify_evidence_file!(issues, root, evidence, path_key, hash_key)
    relative_path = get(evidence, path_key, nothing)
    expected_hash = get(evidence, hash_key, nothing)
    valid_sha256(expected_hash) || begin
        push!(issues, "real issue-#101 evidence has missing or invalid $hash_key")
        return
    end
    path = safe_payload_path(root, relative_path)
    if isnothing(path) || !isfile(path)
        push!(
            issues,
            "real issue-#101 evidence file $path_key is missing or escapes bundle",
        )
        return
    end
    sha256sum(path) == expected_hash || push!(
        issues,
        "real issue-#101 evidence file $path_key has the wrong SHA-256",
    )
end

function verify_replay_acceptance(root, schema_path)
    validation = validate_bundle(root, schema_path)
    validation.ok || return (;
        ok = false,
        issues = validation.issues,
        replay = nothing,
        validation,
    )
    manifest = validation.manifest
    schema = validation.schema
    issues = String[]
    trajectory = manifest["trajectory"]
    get(trajectory, "evidence_status", nothing) == "complete" ||
        push!(issues, "trajectory evidence_status is not complete")

    provenance = manifest["provenance"]
    authority = schema["authority"]
    get(provenance, "source_archive_sha256", nothing) ==
    authority["source_archive_sha256"] || push!(
        issues,
        "provenance does not match the pinned CLASSIC source archive",
    )
    get(provenance, "source_commit", nothing) == authority["source_commit"] ||
        push!(
            issues,
            "provenance does not match the pinned CLASSIC source commit",
        )
    for key in ("parameter_namelist_sha256",)
        get(provenance, key, nothing) == authority[key] || push!(
            issues,
            "provenance does not match the pinned fresh-local $key",
        )
    end

    evidence = get(manifest, "evidence", Dict())
    for key in (
        "snapshot_schema_sha256",
        "time_index_sha256",
        "completion_ledger_sha256",
        "capture_receipt_sha256",
    )
        valid_sha256(get(provenance, key, nothing)) ||
            push!(issues, "accepted trajectory provenance lacks ")
    end
    evidence_complete =
        get(evidence, "status", nothing) == "complete" &&
        get(evidence, "source", nothing) ==
        "issue_101_stage_b_call_snapshots" &&
        get(evidence, "snapshot_count", nothing) == length(manifest["step"]) &&
        get(evidence, "contiguous", nothing) === true &&
        get(evidence, "complete_seasonal_cycle", nothing) === true &&
        get(evidence, "replay_result", nothing) == "pass" &&
        get(evidence, "recurrent_state_replacement", nothing) === false &&
        get(evidence, "nonperturbation_result", nothing) == "pass"
    evidence_complete ||
        push!(issues, "bundle lacks complete real issue-#101 evidence")
    if evidence_complete
        for (path_key, hash_key) in (
            ("instrumentation_receipt_path", "instrumentation_receipt_sha256"),
            ("nonperturbation_receipt_path", "nonperturbation_receipt_sha256"),
            ("snapshot_index_path", "snapshot_index_sha256"),
            ("completion_ledger_path", "completion_ledger_sha256"),
            ("sealed_event_index_path", "sealed_event_index_sha256"),
            ("execution_receipt_path", "execution_receipt_sha256"),
            ("netcdf_time_receipt_path", "netcdf_time_receipt_sha256"),
            ("replay_receipt_path", "replay_receipt_sha256"),
        )
            verify_evidence_file!(issues, root, evidence, path_key, hash_key)
        end
        capture_path = safe_payload_path(
            root,
            get(evidence, "instrumentation_receipt_path", nothing),
        )
        if !isnothing(capture_path) && isfile(capture_path)
            capture_receipt = TOML.parsefile(capture_path)
            capture_provenance = get(capture_receipt, "provenance", Dict())
            get(capture_provenance, "job_options_sha256", nothing) ==
            get(provenance, "job_options_sha256", nothing) || push!(
                issues,
                "site job-options hash differs between capture and trajectory",
            )
            capture_site = get(capture_receipt, "site", trajectory["site"])
            capture_site == trajectory["site"] ||
                push!(issues, "capture site differs from trajectory site")
        end
    end
    replay = isempty(issues) ? open_replay(root, schema_path) : nothing
    return (; ok = isempty(issues), issues, replay, validation)
end


end
