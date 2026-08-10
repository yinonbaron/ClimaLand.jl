#!/usr/bin/env julia

import SHA
import TOML

sha256_file(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

function required_receipt(path)
    isfile(path) || throw(ArgumentError("missing replay receipt: $path"))
    islink(path) &&
        throw(ArgumentError("replay receipt must not be a symlink: $path"))
    receipt = TOML.parsefile(path)
    get(receipt, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported replay receipt"))
    get(receipt, "initialization_count", nothing) == 1 ||
        throw(ArgumentError("replay did not initialize exactly once"))
    get(receipt, "recurrent_state_replacements", nothing) == 0 ||
        throw(ArgumentError("replay replaced recurrent state"))
    return receipt
end

function evidence_identifier(root, path)
    isabspath(root) || throw(ArgumentError("evidence root must be absolute"))
    isdir(root) && !islink(root) ||
        throw(ArgumentError("evidence root must be a regular directory"))
    root = realpath(root)
    path = abspath(path)
    isfile(path) && !islink(path) ||
        throw(ArgumentError("evidence must be a regular file"))
    relative = relpath(realpath(path), root)
    outside =
        relative == ".." ||
        startswith(relative, ".." * Base.Filesystem.path_separator)
    outside && throw(ArgumentError("evidence escapes its declared root"))
    relative == normpath(relative) ||
        throw(ArgumentError("evidence identifier is not canonical"))
    return relative
end

function maximum_fields(receipts, key)
    names = Set(keys(first(receipts)[key]))
    all(Set(keys(receipt[key])) == names for receipt in receipts) ||
        throw(ArgumentError("replay per-field inventories differ"))
    return Dict(
        name => maximum(receipt[key][name] for receipt in receipts) for
        name in names
    )
end

function field_records(family, maxima, safety_factor)
    return [
        Dict(
            "name" => name,
            "family" => family,
            "observed_maximum_absolute_error" => maximum,
            "safety_factor" => safety_factor,
            "absolute_tolerance" => maximum * safety_factor,
        ) for (name, maximum) in sort!(collect(maxima); by = first)
    ]
end

function derive_tolerances(
    output,
    evidence_root,
    receipt_paths;
    safety_factor = 10.0,
)
    safety_factor > 1 || throw(ArgumentError("safety factor must exceed one"))
    receipts = required_receipt.(receipt_paths)
    states = maximum_fields(receipts, "max_state_errors")
    fluxes = maximum_fields(receipts, "max_flux_errors")
    budgets = Dict(
        "carbon_closure" =>
            maximum(receipt["max_carbon_closure"] for receipt in receipts),
        "accumulated_drift" => maximum(
            abs(receipt["accumulated_drift"]) for receipt in receipts
        ),
    )
    records = vcat(
        field_records("state", states, safety_factor),
        field_records("flux", fluxes, safety_factor),
        field_records("budget", budgets, safety_factor),
    )
    contract = Dict{String, Any}(
        "schema_version" => 1,
        "oracle_contract" => "stage_b_v5",
        "rationale" => "Per-field absolute ceilings are ten times the largest measured Float64 error across the accepted DE-Hai seasonal replay and real canonical GF-Guy seasonal replay; fields measured exactly remain exact.",
        "measurement_receipt" => [
            Dict(
                "evidence_id" => evidence_identifier(evidence_root, path),
                "sha256" => sha256_file(path),
            ) for path in receipt_paths
        ],
        "field" => records,
    )
    open(output, "w") do io
        TOML.print(io, contract; sorted = true)
    end
    return output
end

function main(args)
    length(args) >= 4 || error(
        "usage: derive_tolerances.jl OUTPUT EVIDENCE_ROOT REPLAY_RECEIPT REPLAY_RECEIPT [...]",
    )
    derive_tolerances(first(args), args[2], args[3:end])
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
