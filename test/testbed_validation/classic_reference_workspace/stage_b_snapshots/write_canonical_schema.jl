import TOML

include("snapshots.jl")
include("time_index_receipt.jl")
include("execution_receipt.jl")
include("complete_evidence.jl")
using .CompleteStageBEvidence

function field_dimensions(name, shape)
    shape == (1, 13, 20) && return ["tile", "pft_and_bare", "soil_layer"]
    shape == (1, 20) && return ["tile", "soil_layer"]
    shape == (1, 12) && return ["tile", "pft"]
    shape == (1, 13) && return ["tile", "pft_and_bare"]
    shape == (20,) && return ["soil_layer"]
    shape == (12,) && return ["pft"]
    shape == (15,) && return ["parameter_class"]
    shape == (4,) && return ["q10_parameter"]
    shape == (1,) && startswith(name, "static.") && return ["scalar"]
    shape == (1,) && return ["tile"]
    error("no canonical dimension labels for $name with shape $shape")
end

function canonical_schema()
    fields = [
        Dict(
            "name" => name,
            "phase" => contract.phase,
            "role" => contract.role,
            "units" => contract.units,
            "dtype" => contract.dtype,
            "shape" => collect(contract.shape),
            "dimensions" => field_dimensions(name, contract.shape),
        ) for
        (name, contract) in sort!(collect(canonical_fields()); by = first)
    ]
    return Dict(
        "schema_version" => 1,
        "scope" => "CLASSIC Stage B mineral-soil carbon",
        "site" => "DE-Hai",
        "storage_order" => "fortran_column_major",
        "endianness" => "little",
        "required_snapshot_metadata" => [
            "site",
            "transition",
            "time_start",
            "time_end",
            "deltat_days",
            "source_commit",
            "source_sha256",
            "patch_sha256",
            "executable_sha256",
            "job_options_sha256",
            "model_parameters_sha256",
            "initialization_sha256",
        ],
        "dimensions" => Dict(
            "tile" => 1,
            "pft" => 12,
            "pft_and_bare" => 13,
            "soil_layer" => 20,
            "parameter_class" => 15,
            "q10_parameter" => 4,
            "scalar" => 1,
        ),
        "field" => fields,
    )
end

function write_canonical_schema(path)
    open(path, "w") do io
        TOML.print(io, canonical_schema(); sorted = true)
    end
    return path
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 1 || error("usage: write_canonical_schema.jl DESTINATION")
    write_canonical_schema(only(ARGS))
end
