module CLASSICV5Reference

import SHA
import TOML

export COMPLETE_RECEIPT_SHA256, load_ordinary_snapshot, read_field

const COMPLETE_RECEIPT_SHA256 = "6c4acb8e2e280238794492b20d8dfdbc97cc3d35eb78c96b97a204184e944b9e"
const REQUIRED_FIELD_COUNT = 66
const DTYPES = Dict("float64" => Float64, "int32" => Int32)

sha256sum(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

function contained_payload(root, relative)
    lexical = normpath(joinpath(root, relative))
    rel = relpath(lexical, root)
    (rel == ".." || startswith(rel, ".." * Base.Filesystem.path_separator)) &&
        throw(ArgumentError("snapshot payload escapes its root: $relative"))
    isfile(lexical) ||
        throw(ArgumentError("missing snapshot payload: $relative"))
    resolved_root = realpath(root)
    resolved = realpath(lexical)
    real_rel = relpath(resolved, resolved_root)
    (
        real_rel == ".." ||
        startswith(real_rel, ".." * Base.Filesystem.path_separator)
    ) && throw(
        ArgumentError("snapshot payload symlink escapes its root: $relative"),
    )
    return resolved
end

function verify_manifest(snapshot_root, expected_sha256)
    manifest_path = joinpath(snapshot_root, "manifest.toml")
    isfile(manifest_path) || throw(ArgumentError("missing ordinary manifest"))
    sha256sum(manifest_path) == expected_sha256 || throw(
        ArgumentError(
            "ordinary manifest SHA-256 differs from complete receipt",
        ),
    )
    manifest = TOML.parsefile(manifest_path)
    get(manifest, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported ordinary manifest schema"))
    snapshot = get(manifest, "snapshot", Dict())
    get(snapshot, "transition", nothing) == "ordinary" ||
        throw(ArgumentError("snapshot is not the ordinary transition"))
    get(snapshot, "site", nothing) == "DE-Hai" ||
        throw(ArgumentError("snapshot site is not DE-Hai"))
    fields = get(manifest, "field", Any[])
    length(fields) == REQUIRED_FIELD_COUNT ||
        throw(ArgumentError("ordinary snapshot does not contain 66 fields"))
    names = [get(field, "name", "") for field in fields]
    length(unique(names)) == length(names) ||
        throw(ArgumentError("ordinary snapshot contains duplicate fields"))
    for field in fields
        dtype = get(DTYPES, get(field, "dtype", ""), nothing)
        isnothing(dtype) && throw(
            ArgumentError(
                "unsupported dtype for $(get(field, "name", "<unknown>"))",
            ),
        )
        get(field, "order", nothing) == "fortran_column_major" ||
            throw(ArgumentError("snapshot storage order differs"))
        get(field, "endianness", nothing) == "little" ||
            throw(ArgumentError("snapshot endianness differs"))
        expected_bytes = prod(field["shape"]) * sizeof(dtype)
        field["bytes"] == expected_bytes ||
            throw(ArgumentError("snapshot byte metadata differs"))
        payload = contained_payload(snapshot_root, field["path"])
        filesize(payload) == expected_bytes ||
            throw(ArgumentError("snapshot payload byte count differs"))
        sha256sum(payload) == field["sha256"] ||
            throw(ArgumentError("snapshot payload SHA-256 differs"))
    end
    return manifest
end

function load_ordinary_snapshot(evidence_root)
    receipt_path = joinpath(evidence_root, "complete_receipt.toml")
    isfile(receipt_path) || throw(ArgumentError("missing v5 complete receipt"))
    sha256sum(receipt_path) == COMPLETE_RECEIPT_SHA256 ||
        throw(ArgumentError("v5 complete receipt SHA-256 differs"))
    receipt = TOML.parsefile(receipt_path)
    get(receipt, "status", nothing) == "complete" ||
        throw(ArgumentError("v5 evidence is not complete"))
    snapshot_root = joinpath(evidence_root, "ordinary.raw")
    manifest =
        verify_manifest(snapshot_root, receipt["ordinary_manifest_sha256"])
    return (; evidence_root, snapshot_root, receipt, manifest)
end

function read_field(snapshot, name)
    matches = filter(field -> field["name"] == name, snapshot.manifest["field"])
    length(matches) == 1 ||
        throw(ArgumentError("missing or duplicate field: $name"))
    record = only(matches)
    dtype = DTYPES[record["dtype"]]
    raw_type = dtype == Float64 ? UInt64 : UInt32
    path = contained_payload(snapshot.snapshot_root, record["path"])
    values = open(path, "r") do io
        read!(io, Vector{raw_type}(undef, prod(record["shape"])))
    end
    decoded = if dtype == Float64
        [reinterpret(Float64, ltoh(value)) for value in values]
    else
        [reinterpret(Int32, ltoh(value)) for value in values]
    end
    return reshape(decoded, Tuple(record["shape"]))
end

end
