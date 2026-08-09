module StageBExecutionReceipt

import SHA
import TOML

export record_execution_receipt, verify_execution_receipt

const SCHEMA_VERSION = 1
const SOURCE_COMMIT = "7dd82c9a48a7c8beb6455a229888c90ba20d8eff"
const PROCESS_SWITCHES =
    ("PFTCompetition", "lnduseon", "timberHarvest", "dofire", "prescribedFire")
const LEGACY_DE_HAI_JOB_SHA256 = "f775e4085d7393a9f6b2ad04e99cdeae0999a51f07e9cb4a4575cf381aa96a06"

const REQUIRED_FLAGS = (
    "-O3",
    "-fdefault-real-8",
    "-ffree-line-length-none",
    "-fbacktrace",
    "-ffpe-trap=invalid,zero,overflow",
    "-fbounds-check",
)

sha256sum(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

function file_record(path)
    isfile(path) || error("execution input does not exist: $path")
    return Dict("path" => abspath(path), "sha256" => sha256sum(path))
end

function read_process_switches(path)
    uncommented = join(
        (first(split(line, '!'; limit = 2)) for line in eachline(path)),
        "\n",
    )
    switches = Dict{String, Bool}()
    for name in PROCESS_SWITCHES
        pattern = Regex("(?im)^\\s*$(name)\\s*=\\s*\\.(true|false)\\.")
        matches = collect(eachmatch(pattern, uncommented))
        length(matches) == 1 ||
            error("job options must assign $name exactly once")
        switches[name] = lowercase(only(matches).captures[1]) == "true"
    end
    return switches
end

function process_configuration(inputs)
    matches = filter(
        record -> basename(record["path"]) == "job_options_file.txt",
        inputs,
    )
    length(matches) == 1 ||
        error("forcing inputs must contain one job_options_file.txt")
    configuration = Dict{String, Any}(only(matches))
    configuration["switches"] = read_process_switches(configuration["path"])
    return configuration
end

function execution_record(
    source_archive,
    container_archive,
    sif,
    toolchain_log,
    build_log,
    makefile,
    binary,
    patch,
    input_files,
)
    toolchain = read(toolchain_log, String)
    occursin("GNU Fortran", toolchain) ||
        error("toolchain log does not identify GNU Fortran")
    build = read(build_log, String)
    all(occursin(flag, build) for flag in REQUIRED_FLAGS) ||
        error("build log does not contain the required compiler flags")
    inputs =
        [file_record(path) for path in sort!(abspath.(collect(input_files)))]
    isempty(inputs) && error("forcing-input inventory is empty")
    return Dict(
        "schema_version" => SCHEMA_VERSION,
        "status" => "pass",
        "source_commit" => SOURCE_COMMIT,
        "compiler_flags" => collect(REQUIRED_FLAGS),
        "source_archive" => file_record(source_archive),
        "container_archive" => file_record(container_archive),
        "container_sif" => file_record(sif),
        "toolchain_log" => file_record(toolchain_log),
        "build_log" => file_record(build_log),
        "makefile" => file_record(makefile),
        "binary" => file_record(binary),
        "instrumentation_patch" => file_record(patch),
        "process_configuration" => process_configuration(inputs),
        "input" => inputs,
    )
end

function record_execution_receipt(destination, args...)
    ispath(destination) && error("execution receipt already exists")
    record = execution_record(args...)
    open(destination, "w") do io
        TOML.print(io, record; sorted = true)
    end
    return record
end

function verify_file_record(record, label, issues)
    path = get(record, "path", "")
    isfile(path) || return push!(issues, "$label file is missing")
    get(record, "sha256", nothing) == sha256sum(path) ||
        push!(issues, "$label hash differs")
end

function verify_execution_receipt(path)
    process_switches = Dict{String, Bool}()
    issues = String[]
    receipt = try
        TOML.parsefile(path)
    catch error
        return (;
            ok = false,
            issues = ["invalid execution receipt: $(sprint(showerror, error))"],
        )
    end
    get(receipt, "schema_version", nothing) == SCHEMA_VERSION ||
        push!(issues, "execution receipt schema differs")
    get(receipt, "status", nothing) == "pass" ||
        push!(issues, "execution status is not pass")
    get(receipt, "source_commit", nothing) == SOURCE_COMMIT ||
        push!(issues, "source commit differs")
    get(receipt, "compiler_flags", nothing) == collect(REQUIRED_FLAGS) ||
        push!(issues, "compiler flags differ")
    for key in (
        "source_archive",
        "container_archive",
        "container_sif",
        "toolchain_log",
        "build_log",
        "makefile",
        "binary",
        "instrumentation_patch",
    )
        haskey(receipt, key) ?
        verify_file_record(receipt[key], replace(key, "_" => " "), issues) :
        push!(issues, "execution receipt is missing $key")
    end
    inputs = get(receipt, "input", Any[])
    isempty(inputs) && push!(issues, "forcing-input inventory is empty")
    for (index, record) in enumerate(inputs)
        verify_file_record(record, "forcing input $index", issues)
    end
    if haskey(receipt, "toolchain_log") &&
       isfile(get(receipt["toolchain_log"], "path", ""))
        occursin(
            "GNU Fortran",
            read(receipt["toolchain_log"]["path"], String),
        ) || push!(issues, "toolchain log does not identify GNU Fortran")
    end
    configuration = get(receipt, "process_configuration", nothing)
    if isnothing(configuration)
        legacy = filter(
            record ->
                get(record, "sha256", nothing) == LEGACY_DE_HAI_JOB_SHA256,
            inputs,
        )
        if length(legacy) == 1
            try
                merge!(
                    process_switches,
                    read_process_switches(only(legacy)["path"]),
                )
            catch error
                push!(
                    issues,
                    "invalid process configuration: $(sprint(showerror, error))",
                )
            end
        else
            push!(
                issues,
                "execution receipt does not bind process configuration",
            )
        end
    else
        verify_file_record(configuration, "process configuration", issues)
        bound_inputs = filter(
            record ->
                get(record, "path", nothing) ==
                get(configuration, "path", nothing) &&
                get(record, "sha256", nothing) ==
                get(configuration, "sha256", nothing),
            inputs,
        )
        length(bound_inputs) == 1 || push!(
            issues,
            "process configuration is not bound as a forcing input",
        )
        stored = get(configuration, "switches", Dict())
        if Set(keys(stored)) != Set(PROCESS_SWITCHES) ||
           !all(value isa Bool for value in values(stored))
            push!(issues, "process switch inventory differs")
        else
            try
                current = read_process_switches(configuration["path"])
                current == stored ||
                    push!(issues, "process switch values differ")
                merge!(process_switches, current)
            catch error
                push!(
                    issues,
                    "invalid process configuration: $(sprint(showerror, error))",
                )
            end
        end
    end
    if haskey(receipt, "build_log") &&
       isfile(get(receipt["build_log"], "path", ""))
        build = read(receipt["build_log"]["path"], String)
        all(occursin(flag, build) for flag in REQUIRED_FLAGS) ||
            push!(issues, "build log lacks required compiler flags")
    end
    return (; ok = isempty(issues), issues, process_switches)
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) >= 10 || error(
        "usage: execution_receipt.jl RECEIPT SOURCE_ARCHIVE CONTAINER_ARCHIVE SIF TOOLCHAIN_LOG BUILD_LOG MAKEFILE BINARY PATCH INPUT...",
    )
    record_execution_receipt(
        ARGS[1],
        ARGS[2],
        ARGS[3],
        ARGS[4],
        ARGS[5],
        ARGS[6],
        ARGS[7],
        ARGS[8],
        ARGS[9],
        ARGS[10:end],
    )
end

end
