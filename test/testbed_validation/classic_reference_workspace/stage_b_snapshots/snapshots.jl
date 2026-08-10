module StageBSnapshots

import SHA
import TOML

export SnapshotField,
    generate_instrumentation_bundle,
    read_field,
    sha256sum,
    snapshot_field,
    verify_snapshot,
    write_snapshot

const SCHEMA_VERSION = 1
const FIELD_NAME = r"^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$"
const SHA256 = r"^[0-9a-f]{64}$"
const PHASES =
    Set((:pre_state, :forcing, :audit, :intermediate_state, :post_state))
const ROLES = Set((
    :owned_state,
    :external_forcing,
    :parameter,
    :reference_state,
    :audit_diagnostic,
))

struct SnapshotField{A <: AbstractArray}
    name::String
    phase::Symbol
    role::Symbol
    units::String
    values::A
end

sha256sum(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

valid_sha256(value) = value isa AbstractString && occursin(SHA256, value)
valid_git_commit(value) =
    value isa AbstractString && occursin(r"^[0-9a-f]{40}$", value)

function snapshot_field(name, phase, role, units, values::AbstractArray)
    occursin(FIELD_NAME, name) ||
        throw(ArgumentError("invalid snapshot field name: $name"))
    phase in PHASES || throw(ArgumentError("invalid snapshot phase: $phase"))
    role in ROLES || throw(ArgumentError("invalid snapshot role: $role"))
    isempty(units) &&
        throw(ArgumentError("snapshot field units cannot be empty"))
    eltype(values) in (Float32, Float64, Int32, Int64, UInt8) || throw(
        ArgumentError("unsupported snapshot element type: $(eltype(values))"),
    )
    return SnapshotField(String(name), phase, role, String(units), values)
end

dtype(::Type{Float32}) = "float32"
dtype(::Type{Float64}) = "float64"
dtype(::Type{Int32}) = "int32"
dtype(::Type{Int64}) = "int64"
dtype(::Type{UInt8}) = "uint8"

dtype_type(value) = get(
    Dict(
        "float32" => Float32,
        "float64" => Float64,
        "int32" => Int32,
        "int64" => Int64,
        "uint8" => UInt8,
    ),
    value,
    nothing,
)

little_endian(value::Float32) = htol(reinterpret(UInt32, value))
little_endian(value::Float64) = htol(reinterpret(UInt64, value))
little_endian(value::Int32) = htol(reinterpret(UInt32, value))
little_endian(value::Int64) = htol(reinterpret(UInt64, value))
little_endian(value::UInt8) = value

from_little_endian(::Type{Float32}, value::UInt32) =
    reinterpret(Float32, ltoh(value))
from_little_endian(::Type{Float64}, value::UInt64) =
    reinterpret(Float64, ltoh(value))
from_little_endian(::Type{Int32}, value::UInt32) =
    reinterpret(Int32, ltoh(value))
from_little_endian(::Type{Int64}, value::UInt64) =
    reinterpret(Int64, ltoh(value))
from_little_endian(::Type{UInt8}, value::UInt8) = value

storage_type(::Type{Float32}) = UInt32
storage_type(::Type{Float64}) = UInt64
storage_type(::Type{Int32}) = UInt32
storage_type(::Type{Int64}) = UInt64
storage_type(::Type{UInt8}) = UInt8

function write_payload(path, values)
    open(path, "w") do io
        for value in values
            write(io, little_endian(value))
        end
    end
end

function validate_provenance(source_sha256, patch_sha256)
    valid_sha256(source_sha256) || throw(
        ArgumentError(
            "source_sha256 must be 64 lowercase hexadecimal characters",
        ),
    )
    valid_sha256(patch_sha256) || throw(
        ArgumentError(
            "patch_sha256 must be 64 lowercase hexadecimal characters",
        ),
    )
end

function write_snapshot(
    directory,
    fields;
    transition,
    site,
    source_sha256,
    patch_sha256,
)
    isempty(fields) && throw(ArgumentError("snapshot must contain fields"))
    validate_provenance(source_sha256, patch_sha256)
    names = [field.name for field in fields]
    length(unique(names)) == length(names) ||
        throw(ArgumentError("snapshot field names must be unique"))
    ispath(directory) &&
        throw(ArgumentError("snapshot already exists: $directory"))

    parent = dirname(abspath(directory))
    mkpath(parent)
    temporary = mktempdir(parent; prefix = ".stage-b-snapshot-")
    try
        payload_directory = joinpath(temporary, "fields")
        mkpath(payload_directory)
        records = Dict{String, Any}[]
        for field in fields
            filename = field.name * ".bin"
            relative_path = joinpath("fields", filename)
            path = joinpath(temporary, relative_path)
            write_payload(path, field.values)
            push!(
                records,
                Dict(
                    "name" => field.name,
                    "phase" => String(field.phase),
                    "role" => String(field.role),
                    "units" => field.units,
                    "dtype" => dtype(eltype(field.values)),
                    "shape" => collect(size(field.values)),
                    "order" => "fortran_column_major",
                    "endianness" => "little",
                    "path" => relative_path,
                    "bytes" => filesize(path),
                    "sha256" => sha256sum(path),
                ),
            )
        end
        manifest = Dict(
            "schema_version" => SCHEMA_VERSION,
            "snapshot" => Dict(
                "site" => String(site),
                "transition" => String(transition),
                "source_sha256" => String(source_sha256),
                "patch_sha256" => String(patch_sha256),
                "required_fields" => names,
            ),
            "field" => records,
        )
        open(joinpath(temporary, "manifest.toml"), "w") do io
            TOML.print(io, manifest; sorted = true)
        end
        mv(temporary, directory)
        return directory
    catch
        ispath(temporary) && rm(temporary; recursive = true)
        rethrow()
    end
end

function manifest_issues(directory)
    issues = String[]
    manifest_path = joinpath(directory, "manifest.toml")
    isfile(manifest_path) || return (nothing, ["missing manifest.toml"])
    manifest = try
        TOML.parsefile(manifest_path)
    catch error
        return (nothing, ["invalid manifest.toml: $(sprint(showerror, error))"])
    end
    get(manifest, "schema_version", nothing) == SCHEMA_VERSION ||
        push!(issues, "unsupported schema_version")
    snapshot = get(manifest, "snapshot", Dict())
    for key in (
        "site",
        "transition",
        "source_sha256",
        "patch_sha256",
        "required_fields",
    )
        haskey(snapshot, key) ||
            push!(issues, "snapshot metadata is missing $key")
    end
    for key in ("source_sha256", "patch_sha256")
        haskey(snapshot, key) &&
            !valid_sha256(snapshot[key]) &&
            push!(issues, "snapshot metadata has invalid $key")
    end
    records = get(manifest, "field", Any[])
    names = [get(record, "name", "") for record in records]
    length(unique(names)) == length(names) ||
        push!(issues, "duplicate snapshot field name")
    required = get(snapshot, "required_fields", Any[])
    for name in required
        name in names || push!(issues, "missing required snapshot field: $name")
    end
    for record in records
        name = get(record, "name", "<unnamed>")
        required_keys = (
            "phase",
            "role",
            "units",
            "dtype",
            "shape",
            "order",
            "endianness",
            "path",
            "bytes",
            "sha256",
        )
        all(haskey(record, key) for key in required_keys) || begin
            push!(issues, "$name has incomplete field metadata")
            continue
        end
        record["order"] == "fortran_column_major" ||
            push!(issues, "$name has unsupported storage order")
        record["endianness"] == "little" ||
            push!(issues, "$name has unsupported endianness")
        element_type = dtype_type(record["dtype"])
        isnothing(element_type) && begin
            push!(issues, "$name has unsupported dtype")
            continue
        end
        path = normpath(joinpath(directory, record["path"]))
        relative = relpath(path, directory)
        (
            relative == ".." ||
            startswith(relative, ".." * Base.Filesystem.path_separator)
        ) && begin
            push!(issues, "$name payload escapes snapshot directory")
            continue
        end
        isfile(path) || begin
            push!(issues, "$name payload is missing")
            continue
        end
        expected_bytes = prod(record["shape"]) * sizeof(element_type)
        record["bytes"] == expected_bytes ||
            push!(issues, "$name metadata byte count is inconsistent")
        filesize(path) == record["bytes"] ||
            push!(issues, "$name payload byte count is inconsistent")
        valid_sha256(record["sha256"]) && sha256sum(path) == record["sha256"] ||
            push!(issues, "$name payload SHA-256 is inconsistent")
    end
    return manifest, issues
end

function verify_snapshot(directory)
    manifest, issues = manifest_issues(directory)
    snapshot = isnothing(manifest) ? Dict() : get(manifest, "snapshot", Dict())
    return (;
        ok = isempty(issues),
        issues,
        site = get(snapshot, "site", nothing),
        transition = get(snapshot, "transition", nothing),
        manifest,
    )
end

function read_field(directory, name)
    report = verify_snapshot(directory)
    report.ok || throw(
        ArgumentError(
            "snapshot failed verification: $(join(report.issues, "; "))",
        ),
    )
    record =
        only(filter(field -> field["name"] == name, report.manifest["field"]))
    element_type = dtype_type(record["dtype"])
    storage = storage_type(element_type)
    count = prod(record["shape"])
    raw = open(joinpath(directory, record["path"]), "r") do io
        read!(io, Vector{storage}(undef, count))
    end
    values = [from_little_endian(element_type, value) for value in raw]
    return reshape(values, Tuple(record["shape"]))
end

function fortran_statement_end(lines, start)
    index = start
    while index < length(lines)
        code = first(split(lines[index], '!'; limit = 2))
        endswith(strip(code), "&") || return index
        index += 1
    end
    return index
end

function instrument_driver(source)
    lines = split(chomp(source), '\n')
    calls = (
        (
            "heterotrophicRespiration",
            "stage_b_snapshot_before_heterotrophic",
            "stage_b_snapshot_after_heterotrophic",
        ),
        (
            "updatePoolsHetResp",
            "stage_b_snapshot_before_pool_update",
            "stage_b_snapshot_after_pool_update",
        ),
        (
            "turbation",
            "stage_b_snapshot_before_turbation",
            "stage_b_snapshot_after_turbation",
        ),
    )
    for (routine, before, after) in calls
        matches = findall(
            line -> occursin(Regex("^\\s*call\\s+$routine\\s*\\("), line),
            lines,
        )
        length(matches) == 1 || throw(
            ArgumentError(
                "expected exactly one unconditional $routine call, found $(length(matches))",
            ),
        )
        start = only(matches)
        stop = fortran_statement_end(lines, start)
        indent = match(r"^\s*", lines[start]).match
        insert!(lines, start, indent * "! $before")
        stop += 1
        insert!(lines, stop + 1, indent * "! $after")
    end
    return join(lines, '\n')
end

function complete_replacement_patch(source, instrumented)
    old = split(chomp(source), '\n')
    new = split(chomp(instrumented), '\n')
    io = IOBuffer()
    println(io, "--- a/src/base/ctemDriver.F90")
    println(io, "+++ b/src/base/ctemDriver.F90")
    println(io, "@@ -1,$(length(old)) +1,$(length(new)) @@")
    foreach(line -> println(io, "-", line), old)
    foreach(line -> println(io, "+", line), new)
    return String(take!(io))
end

function generate_instrumentation_bundle(
    driver_path,
    output_directory;
    source_commit,
)
    valid_git_commit(source_commit) || throw(
        ArgumentError(
            "source_commit must be a 40-character lowercase hexadecimal commit",
        ),
    )
    source = read(driver_path, String)
    instrumented = instrument_driver(source)
    ispath(output_directory) && throw(
        ArgumentError(
            "instrumentation bundle already exists: $output_directory",
        ),
    )
    mkpath(output_directory)
    patch_path = joinpath(output_directory, "classic-stage-b-snapshots.patch")
    write(patch_path, complete_replacement_patch(source, instrumented))
    receipt = Dict(
        "schema_version" => 1,
        "status" => "scaffold",
        "source_commit" => source_commit,
        "source_sha256" => bytes2hex(SHA.sha256(codeunits(source))),
        "patch_path" => basename(patch_path),
        "patch_sha256" => sha256sum(patch_path),
    )
    receipt_path = joinpath(output_directory, "instrumentation_receipt.toml")
    open(receipt_path, "w") do io
        TOML.print(io, receipt; sorted = true)
    end
    return (;
        patch = patch_path,
        receipt = receipt_path,
        patch_sha256 = receipt["patch_sha256"],
    )
end

end
