import SHA
import TOML

sha256sum(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

function tree_manifest(directory, destination)
    files = sort!([
        relpath(joinpath(root, name), directory) for
        (root, _, names) in walkdir(directory) for
        name in names if endswith(name, ".nc")
    ])
    open(destination, "w") do io
        for relative in files
            println(
                io,
                sha256sum(joinpath(directory, relative)),
                "  ",
                relative,
            )
        end
    end
    return files
end

function record_receipt(
    destination,
    reference_directory,
    candidate_directory,
    comparison_log,
    comparator,
    patch,
    binary,
    job_options,
    parameters,
    initialization,
)
    output_directory = dirname(destination)
    reference_manifest = joinpath(output_directory, "pristine-output.sha256")
    candidate_manifest =
        joinpath(output_directory, "instrumented-output.sha256")
    reference_files = tree_manifest(reference_directory, reference_manifest)
    candidate_files = tree_manifest(candidate_directory, candidate_manifest)
    readlines(comparison_log)[end] == "overall: PASS" ||
        error("comparison log does not end in overall: PASS")
    reference_files == candidate_files || error("output inventories differ")
    length(reference_files) == 57 || error("expected 57 compared NetCDF files")

    receipt = Dict(
        "schema_version" => 1,
        "result" => "pass",
        "criteria" => "exact values, coordinates, masks, dimensions, types, and units",
        "site" => "DE-Hai",
        "compared_files" => 57,
        "failed_files" => 0,
        "record_count_per_daily_file" => 4749,
        "comparison_log_sha256" => sha256sum(comparison_log),
        "comparator_sha256" => sha256sum(comparator),
        "reference_output_manifest_sha256" => sha256sum(reference_manifest),
        "candidate_output_manifest_sha256" => sha256sum(candidate_manifest),
        "instrumentation_patch_sha256" => sha256sum(patch),
        "instrumented_executable_sha256" => sha256sum(binary),
        "job_options_sha256" => sha256sum(job_options),
        "model_parameters_sha256" => sha256sum(parameters),
        "initialization_sha256" => sha256sum(initialization),
    )
    open(destination, "w") do io
        TOML.print(io, receipt; sorted = true)
    end
    return receipt
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 10 || error(
        "usage: record_comparison_receipt.jl RECEIPT REFERENCE CANDIDATE LOG COMPARATOR PATCH BINARY JOB PARAMS INIT",
    )
    record_receipt(ARGS...)
end
