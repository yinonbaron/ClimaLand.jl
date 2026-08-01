if !isdefined(@__MODULE__, :TestbedModelProcessOrchestration)
    include(joinpath(@__DIR__, "model_process_orchestration.jl"))
end
if !isdefined(@__MODULE__, :TestbedReferenceHarness)
    include(joinpath(@__DIR__, "reference_harness.jl"))
end

module TestbedFreshReferenceAdapter

import SHA
import TOML

const ModelProcesses =
    getfield(parentmodule(@__MODULE__), :TestbedModelProcessOrchestration)
const Harness = getfield(parentmodule(@__MODULE__), :TestbedReferenceHarness)
const SCRIPT_PATH = @__FILE__
const PINNED_SOURCE_COMMIT = "27ae1a0b673411642cd780ecad66d1c8f84e6a58"
const CASA_C_TRACER_MODEL = "CASA-C"
const CASA_C_TRACER_SCOPE = "one-cell-boundary"
const CASA_C_TRACER_CONTRACT = "fortran-archive-integrity-tracer"
const CASA_C_TRACER_FIXTURE = joinpath(@__DIR__, "fixtures", "casa_c_cell_51")

const MISSING_MODEL_COMMANDS = Dict(
    "CASA-C" => "no command generates the 80-cell Representative Fortran workflow and compares its Julia trajectory without publishing",
    "CASA-CN" => "no command generates the 80-cell Representative Fortran workflow and compares its Julia trajectory without publishing",
    "MIMICS-C" => "no command generates the 80-cell Representative Fortran CASA/MIMICS workflow and invokes the selected Julia comparison",
    "MIMICS-CN" => "selected_mimics_cn_validation.jl is tied to the 37-cell issue-43 template, not the 80-cell Representative report contract",
    "CORPSE" => "generate_complete_selected_corpse_reference.jl is tied to the selected CORPSE fixture and a publication destination, not the 80-cell Representative report contract",
)

struct AdapterError <: Exception
    message::String
end

Base.showerror(io::IO, error::AdapterError) = print(io, error.message)

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

function verified_executable(build_directory)
    metadata_path = joinpath(build_directory, "build_metadata.toml")
    isfile(metadata_path) ||
        throw(AdapterError("shared Fortran build metadata is missing"))
    metadata = try
        TOML.parsefile(metadata_path)
    catch error
        throw(
            AdapterError(
                "shared Fortran build metadata is unreadable: " *
                sprint(showerror, error),
            ),
        )
    end
    get(metadata, "schema_version", nothing) == 1 &&
        get(metadata, "verified", false) === true ||
        throw(AdapterError("shared Fortran build is not verified"))
    verification = get(metadata, "verification", Dict{String, Any}())
    get(verification, "source_commit", nothing) == PINNED_SOURCE_COMMIT ||
        throw(AdapterError("shared Fortran build source is not pinned"))
    get(verification, "source_code_clean", false) === true ||
        throw(AdapterError("shared Fortran build source is not clean"))
    name = get(verification, "executable", nothing)
    name isa AbstractString && basename(name) == name ||
        throw(AdapterError("shared Fortran executable name is invalid"))
    executable = joinpath(build_directory, name)
    isfile(executable) ||
        throw(AdapterError("shared Fortran executable is missing"))
    sha256sum(executable) == get(verification, "executable_sha256", nothing) ||
        throw(AdapterError("shared Fortran executable checksum differs"))
    return executable
end

function build_shared_fortran(source_root, build_directory)
    source_root = abspath(source_root)
    Harness.source_commit(source_root) == PINNED_SOURCE_COMMIT || throw(
        AdapterError("Fortran source must be pinned to $PINNED_SOURCE_COMMIT"),
    )
    isempty(Harness.source_code_status(source_root)) || throw(
        AdapterError("pinned Fortran SOURCE_CODE has local modifications"),
    )
    executable = Harness.build_fortran_at(source_root, build_directory)
    metadata_path = joinpath(build_directory, "build_metadata.toml")
    metadata = TOML.parsefile(metadata_path)
    metadata["schema_version"] = 1
    metadata["verified"] = true
    metadata["verification"] = Dict(
        "executable" => basename(executable),
        "executable_sha256" => sha256sum(executable),
        "source_commit" => PINNED_SOURCE_COMMIT,
        "source_code_clean" => true,
    )
    Harness.write_toml_atomic(metadata_path, metadata)
    verified_executable(build_directory)
    return executable
end

function commands(source_root)
    source_root = abspath(source_root)
    project = dirname(Base.active_project())
    build =
        build_directory ->
            `$(Base.julia_cmd()) --startup-file=no $SCRIPT_PATH build $source_root $build_directory`
    worker =
        (model, run_directory, build_directory) ->
            `$(Base.julia_cmd()) --startup-file=no --project=$project $SCRIPT_PATH worker $model $run_directory $build_directory`
    return (; build, worker)
end

function require_model_command(model)
    model in ModelProcesses.MODELS ||
        throw(AdapterError("unknown fresh-reference model: $model"))
    throw(
        AdapterError(
            "$model Representative fresh worker is unavailable: " *
            MISSING_MODEL_COMMANDS[model],
        ),
    )
end

function require_clean_source_paths(source_root, relative_paths)
    Harness.source_commit(source_root) == PINNED_SOURCE_COMMIT ||
        throw(AdapterError("CASA-C tracer source is not pinned"))
    git = Harness.require_tool("git")
    status = readchomp(
        Cmd([
            git,
            "-C",
            source_root,
            "status",
            "--porcelain",
            "--",
            relative_paths...,
        ]),
    )
    isempty(status) || throw(
        AdapterError("CASA-C tracer source inputs have local modifications"),
    )
    return true
end

function require_empty_directory(path)
    if isdir(path)
        isempty(readdir(path)) ||
            throw(AdapterError("fresh run directory is not empty: $path"))
    elseif ispath(path)
        throw(AdapterError("fresh run path is not a directory: $path"))
    else
        mkpath(path)
    end
    return path
end

function verify_fixture(fixture_directory, manifest)
    get(manifest, "schema_version", nothing) == 1 ||
        throw(AdapterError("CASA-C tracer fixture schema is incompatible"))
    get(manifest["generation"], "roundtrip_exact", false) === true ||
        throw(AdapterError("CASA-C tracer fixture lacks a round-trip audit"))
    for record in values(manifest["fixture"])
        path = joinpath(fixture_directory, record["filename"])
        isfile(path) ||
            throw(AdapterError("CASA-C tracer input is missing: $path"))
        filesize(path) == record["bytes"] ||
            throw(AdapterError("CASA-C tracer input size differs: $path"))
        sha256sum(path) == record["sha256"] ||
            throw(AdapterError("CASA-C tracer input checksum differs: $path"))
    end
    return true
end

function run_casa_c_tracer(
    source_root,
    run_directory,
    build_directory;
    fixture_directory = CASA_C_TRACER_FIXTURE,
)
    source_root = abspath(source_root)
    run_directory = abspath(run_directory)
    fixture_directory = abspath(fixture_directory)
    executable = verified_executable(build_directory)
    manifest = TOML.parsefile(joinpath(fixture_directory, "fixture.toml"))
    verify_fixture(fixture_directory, manifest)
    files = manifest["fixture"]
    source_inputs = (
        "GRID_CN/pftlookup_igbp_updated4_exud0.csv",
        "GRID_CN/modis_phenology_wtundra.txt",
        "GRID_CN/co2delta_control.txt",
    )
    require_clean_source_paths(source_root, source_inputs)
    require_empty_directory(run_directory)
    cp(
        joinpath(fixture_directory, files["grid"]["filename"]),
        joinpath(run_directory, "grid.csv");
        force = true,
    )
    cp(
        joinpath(fixture_directory, files["soil"]["filename"]),
        joinpath(run_directory, "soil.csv");
        force = true,
    )
    cp(
        joinpath(fixture_directory, files["driver"]["filename"]),
        joinpath(run_directory, "met.nc");
        force = true,
    )
    for (relative, name) in zip(
        source_inputs,
        ("casa_parameters.csv", "phenology.txt", "perturbation.txt"),
    )
        cp(
            joinpath(source_root, relative),
            joinpath(run_directory, name);
            force = true,
        )
    end
    control =
        Harness.write_smoke_control(run_directory; points = 1, daily_output = 1)
    log_path = joinpath(run_directory, "fortran.log")
    open(log_path, "w") do io
        run(
            pipeline(
                Cmd(Cmd([executable]); dir = run_directory);
                stdout = io,
                stderr = io,
            ),
        )
    end
    warning_count = count(
        line -> occursin("Data alignment problem in ReadMetNcFile", line),
        eachline(log_path),
    )
    expected_warnings = manifest["comparison"]["expected_alignment_warnings"]
    warning_count == expected_warnings || throw(
        AdapterError(
            "CASA-C tracer expected $expected_warnings alignment warnings; found $warning_count",
        ),
    )

    candidate = joinpath(run_directory, "casaclm_pool_flux_0001_daily.nc")
    reference = joinpath(fixture_directory, files["output"]["filename"])
    isfile(candidate) ||
        throw(AdapterError("CASA-C tracer did not produce its daily output"))
    comparison_script = joinpath(@__DIR__, "netcdf_compare.jl")
    comparison_path = joinpath(run_directory, "comparison.toml")
    comparison = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) -e $(_comparison_expression(comparison_script, reference, candidate, comparison_path, manifest))`
    success(run(ignorestatus(comparison))) || throw(
        AdapterError("CASA-C tracer comparison failed; see $comparison_path"),
    )
    Harness.write_toml_atomic(
        joinpath(run_directory, "fortran_output.toml"),
        Dict(
            "schema_version" => 1,
            "model" => CASA_C_TRACER_MODEL,
            "scope" => CASA_C_TRACER_SCOPE,
            "output" => candidate,
            "output_sha256" => sha256sum(candidate),
            "shared_executable_sha256" => sha256sum(executable),
            "control_sha256" => sha256sum(control),
        ),
    )
    return comparison_path
end

function _comparison_expression(script, reference, candidate, report, manifest)
    start = manifest["comparison"]["reference_time_start"]
    stop = manifest["comparison"]["reference_time_stop"]
    offset = manifest["comparison"]["candidate_time_offset"]
    return """
    include($(repr(script)))
    import TOML
    result = TestbedNetCDFCompare.compare_netcdf(
        $(repr(reference)), $(repr(candidate));
        reference_selectors = Dict("time" => $start:$stop),
        candidate_offsets = Dict("time" => $offset),
    )
    report = Dict(
        "schema_version" => 1,
        "model" => $(repr(CASA_C_TRACER_MODEL)),
        "scope" => $(repr(CASA_C_TRACER_SCOPE)),
        "contract" => $(repr(CASA_C_TRACER_CONTRACT)),
        "outcome" => result.ok ? "passed" : "failed",
        "failed_variables" => result.failed_variables,
        "metadata_mismatches" => result.metadata_mismatches,
    )
    open($(repr(report)), "w") do io
        TOML.print(io, report; sorted = true)
    end
    exit(result.ok ? 0 : 1)
    """
end

function main(args = ARGS)
    isempty(args) &&
        throw(AdapterError("expected build, worker, status, or trace-casa-c"))
    mode = first(args)
    if mode == "build"
        length(args) == 3 || throw(
            AdapterError(
                "usage: fresh_reference_adapter.jl build SOURCE_ROOT BUILD_DIRECTORY",
            ),
        )
        build_shared_fortran(args[2], args[3])
        return 0
    elseif mode == "worker"
        length(args) == 4 || throw(
            AdapterError(
                "usage: fresh_reference_adapter.jl worker MODEL RUN_DIRECTORY BUILD_DIRECTORY",
            ),
        )
        verified_executable(args[4])
        require_model_command(args[2])
    elseif mode == "trace-casa-c"
        length(args) in (4, 5) || throw(
            AdapterError(
                "usage: fresh_reference_adapter.jl trace-casa-c SOURCE_ROOT RUN_DIRECTORY BUILD_DIRECTORY [FIXTURE_DIRECTORY]",
            ),
        )
        fixture = length(args) == 5 ? args[5] : CASA_C_TRACER_FIXTURE
        run_casa_c_tracer(
            args[2],
            args[3],
            args[4];
            fixture_directory = fixture,
        )
        return 0
    elseif mode == "status"
        TOML.print(
            stdout,
            Dict(
                "schema_version" => 1,
                "representative_workers_ready" => false,
                "missing_model_command" => MISSING_MODEL_COMMANDS,
                "available_tracer" => Dict(
                    "model" => CASA_C_TRACER_MODEL,
                    "scope" => CASA_C_TRACER_SCOPE,
                    "contract" => CASA_C_TRACER_CONTRACT,
                ),
            );
            sorted = true,
        )
        println()
        return 0
    end
    throw(AdapterError("unknown fresh-reference adapter mode: $mode"))
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    try
        exit(TestbedFreshReferenceAdapter.main())
    catch error
        println(stderr, "Fresh Reference Adapter: ", sprint(showerror, error))
        exit(error isa TestbedFreshReferenceAdapter.AdapterError ? 2 : 1)
    end
end
