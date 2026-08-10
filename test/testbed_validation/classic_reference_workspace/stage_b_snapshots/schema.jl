module StageBSnapshotSchema

import TOML

using ..StageBSnapshots

export load_schema, verify_against_schema

const REQUIRED_TOP_LEVEL = (
    "schema_version",
    "scope",
    "site",
    "storage_order",
    "endianness",
    "dimensions",
    "field",
)
const REQUIRED_FIELD =
    ("name", "phase", "role", "units", "dtype", "dimensions", "shape")
const SUPPORTED_DTYPES = Set(("float32", "float64", "int32", "int64", "uint8"))
const PHASES =
    Set(("pre_state", "forcing", "audit", "intermediate_state", "post_state"))
const ROLES = Set((
    "owned_state",
    "external_forcing",
    "parameter",
    "reference_state",
    "audit_diagnostic",
))

function load_schema(path)
    isfile(path) ||
        throw(ArgumentError("snapshot schema does not exist: $path"))
    schema = TOML.parsefile(path)
    all(haskey(schema, key) for key in REQUIRED_TOP_LEVEL) || throw(
        ArgumentError("snapshot schema has incomplete top-level metadata"),
    )
    schema["schema_version"] == 1 ||
        throw(ArgumentError("unsupported snapshot schema_version"))
    schema["storage_order"] == "fortran_column_major" || throw(
        ArgumentError("snapshot schema must use Fortran column-major order"),
    )
    schema["endianness"] == "little" || throw(
        ArgumentError(
            "snapshot schema must use canonical little-endian payloads",
        ),
    )
    dimensions = schema["dimensions"]
    all(value isa Integer && value > 0 for value in values(dimensions)) ||
        throw(
            ArgumentError(
                "snapshot schema dimensions must be positive integers",
            ),
        )
    fields = schema["field"]
    isempty(fields) && throw(ArgumentError("snapshot schema has no fields"))
    names = String[]
    for field in fields
        all(haskey(field, key) for key in REQUIRED_FIELD) || throw(
            ArgumentError("snapshot schema field has incomplete metadata"),
        )
        field["phase"] in PHASES ||
            throw(ArgumentError("invalid schema phase for $(field["name"])"))
        field["role"] in ROLES ||
            throw(ArgumentError("invalid schema role for $(field["name"])"))
        isempty(field["units"]) &&
            throw(ArgumentError("schema field $(field["name"]) has no units"))
        isempty(field["dimensions"]) && throw(
            ArgumentError("schema field $(field["name"]) has no dimensions"),
        )
        field["dtype"] in SUPPORTED_DTYPES ||
            throw(ArgumentError("unsupported dtype for $(field["name"])"))
        all(haskey(dimensions, label) for label in field["dimensions"]) ||
            throw(ArgumentError("undeclared dimension for $(field["name"])"))
        field["shape"] ==
        [dimensions[label] for label in field["dimensions"]] || throw(
            ArgumentError(
                "schema shape does not match dimensions for $(field["name"])",
            ),
        )
        push!(names, field["name"])
    end
    length(unique(names)) == length(names) ||
        throw(ArgumentError("snapshot schema contains duplicate fields"))
    return schema
end

function verify_against_schema(snapshot_directory, schema_path)
    snapshot_report = StageBSnapshots.verify_snapshot(snapshot_directory)
    issues = copy(snapshot_report.issues)
    schema = try
        load_schema(schema_path)
    catch error
        push!(issues, sprint(showerror, error))
        return (;
            ok = false,
            issues,
            schema = nothing,
            snapshot = snapshot_report,
        )
    end
    if snapshot_report.ok
        records = Dict(
            record["name"] => record for
            record in snapshot_report.manifest["field"]
        )
        expected_names = Set(field["name"] for field in schema["field"])
        actual_names = Set(keys(records))
        for name in sort!(collect(setdiff(expected_names, actual_names)))
            push!(issues, "missing schema field: $name")
        end
        for name in sort!(collect(setdiff(actual_names, expected_names)))
            push!(issues, "undeclared snapshot field: $name")
        end
        for field in schema["field"]
            name = field["name"]
            haskey(records, name) || continue
            record = records[name]
            for key in ("phase", "role", "units")
                record[key] == field[key] ||
                    push!(issues, "$name $key does not match schema")
            end
            record["dtype"] == field["dtype"] ||
                push!(issues, "$name dtype does not match schema")
            record["shape"] == field["shape"] ||
                push!(issues, "$name shape does not match schema")
        end
        snapshot_report.site == schema["site"] ||
            push!(issues, "snapshot site does not match schema")
    end
    return (; ok = isempty(issues), issues, schema, snapshot = snapshot_report)
end

end
