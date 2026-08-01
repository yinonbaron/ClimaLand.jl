if !isdefined(@__MODULE__, :TestbedReferenceHarness)
    include(joinpath(@__DIR__, "reference_harness.jl"))
end
if !isdefined(@__MODULE__, :TestbedCandidateReconstruction)
    include(joinpath(@__DIR__, "candidate_reconstruction.jl"))
end
if !isdefined(@__MODULE__, :GenerateSelectedCORPSEReference)
    include(joinpath(@__DIR__, "generate_selected_corpse_reference.jl"))
end
if !isdefined(@__MODULE__, :finish_representative_worker)
    include(joinpath(@__DIR__, "generate_selected_casa_workflow_reference.jl"))
end

module TestbedCASAFreshWorker

import TOML

import NCDatasets

const Harness = getfield(parentmodule(@__MODULE__), :TestbedReferenceHarness)
const Candidates =
    getfield(parentmodule(@__MODULE__), :TestbedCandidateReconstruction)
const Selected =
    getfield(parentmodule(@__MODULE__), :GenerateSelectedCORPSEReference)
const Generator = parentmodule(@__MODULE__)
const PINNED_SOURCE_COMMIT = "27ae1a0b673411642cd780ecad66d1c8f84e6a58"
const REPRESENTATIVE_SCOPE =
    joinpath(@__DIR__, "validation", "scopes", "representative.toml")
const ACCELERATED_PARAMETERS_SHA256 =
    "9dac2d263b43eb5a2df71ed7dbef398bc58ae55421829af8db97018fa93509e2"
const ANNUAL_FILENAME = "ann_casaclm_pool_flux_1901_2014.nc"
const RETAINED_DAILY_YEARS = Set((1901, 2014))

model_configuration(model) =
    model == "CASA-C" ? :carbon_only :
    model == "CASA-CN" ? :carbon_nitrogen :
    throw(ArgumentError("CASA fresh worker does not support $model"))

function stage_specs(configuration)
    configuration in (:carbon_only, :carbon_nitrogen) ||
        throw(ArgumentError("unsupported CASA configuration"))
    historical_daily = configuration == :carbon_nitrogen
    return (
        (
            name = "prespin",
            loops = 100,
            years = 1901:1901,
            initialization = 0,
            daily = false,
            interval = 100,
        ),
        (
            name = "accelerated_spin",
            loops = 499,
            years = 1901:1920,
            initialization = 3,
            daily = false,
            interval = 9960,
        ),
        (
            name = "normal_spin",
            loops = 499,
            years = 1901:1920,
            initialization = 3,
            daily = false,
            interval = 9960,
        ),
        (
            name = "historical",
            loops = 1,
            years = 1901:2014,
            initialization = 2,
            daily = historical_daily,
            interval = historical_daily ? 1 : 114,
        ),
    )
end

function verified_shared_executable(build_directory)
    metadata_path = joinpath(build_directory, "build_metadata.toml")
    isfile(metadata_path) || error("shared Fortran build metadata is missing")
    metadata = TOML.parsefile(metadata_path)
    get(metadata, "schema_version", nothing) == 1 &&
        get(metadata, "verified", false) === true ||
        error("shared Fortran build is not verified")
    verification = get(metadata, "verification", Dict{String, Any}())
    get(verification, "source_commit", nothing) == PINNED_SOURCE_COMMIT &&
        get(verification, "source_code_clean", false) === true ||
        error("shared Fortran build does not verify the pinned clean source")
    name = get(verification, "executable", nothing)
    name isa AbstractString && basename(name) == name ||
        error("shared Fortran executable name is invalid")
    executable = joinpath(build_directory, name)
    isfile(executable) || error("shared Fortran executable is missing")
    Generator.TestbedNativeWorkflow.sha256sum(executable) ==
    get(verification, "executable_sha256", nothing) ||
        error("shared Fortran executable checksum differs")
    return executable
end

function write_boreal_fixation_parameters(source, destination)
    spec = TOML.parsefile(Candidates.CANDIDATE_SPEC_PATH)
    candidate = only(
        filter(item -> item["id"] == "casa_boreal_nfix", spec["candidate"]),
    )
    Candidates.sha256sum(source) == candidate["expected_source_sha256"] ||
        error("CASA-CN prespin parameter source differs from its pinned hash")
    lines = readlines(source; keep = true)
    for mutation in candidate["mutation"]
        lines, _ = Candidates.apply_mutation(lines, mutation)
    end
    Candidates.write_candidate_atomic(destination, join(lines), candidate)
    return destination
end

function prepare_inputs(configuration, source_root, collection, run_root)
    selected_root = joinpath(run_root, "selected_inputs")
    forcing_root = joinpath(selected_root, "forcing")
    mkpath(forcing_root)
    grid = joinpath(selected_root, "grid.csv")
    Selected.write_fortran_grid(collection.files["grid"], grid)
    for year in 1901:2014
        Selected.write_fortran_meteorology(
            collection.files["forcing"],
            joinpath(forcing_root, "met_$(year)_$(year).nc");
            selected_year = year,
        )
    end
    accelerated = joinpath(
        source_root,
        "GRID_CN",
        "pftlookup_igbp_updated4_exud0AD.csv",
    )
    isfile(accelerated) || error("accelerated CASA parameters are missing")
    Generator.TestbedNativeWorkflow.sha256sum(accelerated) ==
    ACCELERATED_PARAMETERS_SHA256 ||
        error("accelerated CASA parameters differ from the pinned hash")
    prespin = if configuration == :carbon_nitrogen
        write_boreal_fixation_parameters(
            collection.files["casa_cn_parameters"],
            joinpath(selected_root, "casa_prespin_parameters.csv"),
        )
    else
        collection.files["casa_c_parameters"]
    end
    return (;
        selected_root,
        forcing_root,
        grid,
        soil = collection.files["soil"],
        phenology = collection.files["phenology"],
        perturbation = collection.files["perturbation"],
        prespin,
        accelerated,
        normal = collection.files["casa_c_parameters"],
    )
end

function stage_inputs(prepared, stage, parameters, configuration)
    inputs = [
        Harness.workflow_input(prepared.grid, "grid.csv"),
        Harness.workflow_input(parameters, "casa_parameters.csv"),
        Harness.workflow_input(prepared.phenology, "phenology.txt"),
        Harness.workflow_input(prepared.soil, "soil.csv"),
        Harness.workflow_input(prepared.perturbation, "perturbation.txt"),
    ]
    append!(
        inputs,
        [
            Harness.workflow_input(
                joinpath(prepared.forcing_root, "met_$(year)_$(year).nc"),
                "met_$(year)_$(year).nc";
                mode = "symlink",
            ) for year in stage.years
        ],
    )
    if stage.name != "prespin"
        predecessor = Dict(
            "accelerated_spin" => "prespin",
            "normal_spin" => "accelerated_spin",
            "historical" => "normal_spin",
        )[stage.name]
        transform = if stage.name == "normal_spin"
            configuration == :carbon_only ?
            "casa_passive_carbon_x10" :
            "casa_passive_carbon_nitrogen_x10"
        else
            "none"
        end
        push!(
            inputs,
            Harness.workflow_input(
                "stage:$predecessor/casa_final.csv",
                "casa_initial.csv";
                transform,
            ),
        )
    end
    return inputs
end

daily_name(year) = "casaclm_pool_flux_$(year)_daily.nc"

function historical_outputs(configuration)
    outputs = ["casa_final.csv", "casa_flux_final.csv"]
    configuration == :carbon_nitrogen &&
        append!(outputs, daily_name.(sort!(collect(RETAINED_DAILY_YEARS))))
    return outputs
end

function daily_file_complete(path)
    isfile(path) || return false
    return try
        NCDatasets.NCDataset(path) do dataset
            haskey(dataset.dim, "time") && dataset.dim["time"] == 365
        end
    catch
        false
    end
end

function initialize_annual(path, daily_path)
    mkpath(dirname(path))
    NCDatasets.NCDataset(daily_path) do daily
        NCDatasets.NCDataset(path, "c"; format = :netcdf4) do annual
            NCDatasets.defDim(annual, "lon", Int(daily.dim["lon"]))
            NCDatasets.defDim(annual, "lat", Int(daily.dim["lat"]))
            NCDatasets.defDim(annual, "time", 114)
            cellid = NCDatasets.defVar(annual, "cellid", Int32, ("lon", "lat"))
            cellid[:, :] = Int32.(daily["cellid"][:, :])
            for (reference_name, _) in
                Generator.NativeCASACN.historical_variables()
                reference_name == "nLitInptStruc" && continue
                source = daily[reference_name]
                attributes = Dict(source.attrib)
                pop!(attributes, "_FillValue", nothing)
                NCDatasets.defVar(
                    annual,
                    reference_name,
                    Float64,
                    ("lon", "lat", "time");
                    attrib = attributes,
                    deflatelevel = 1,
                )
            end
        end
    end
    return path
end

function write_annual_year!(annual_path, daily_path, year)
    isfile(annual_path) || initialize_annual(annual_path, daily_path)
    NCDatasets.NCDataset(annual_path, "a") do annual
        NCDatasets.NCDataset(daily_path) do daily
            index = year - 1900
            for (reference_name, _) in
                Generator.NativeCASACN.historical_variables()
                reference_name == "nLitInptStruc" && continue
                values = Float64.(coalesce.(daily[reference_name][:, :, :], NaN))
                annual[reference_name][:, :, index] =
                    dropdims(sum(values; dims = 3) ./ 365; dims = 3)
            end
        end
    end
    return annual_path
end

function stream_historical!(stage_dir, annual_path, finished, completed)
    years = collect(1901:2014)
    for (position, year) in enumerate(years)
        path = joinpath(stage_dir, daily_name(year))
        next_path =
            position == length(years) ? nothing :
            joinpath(stage_dir, daily_name(years[position + 1]))
        while !isfile(path) && !finished[]
            sleep(0.25)
        end
        isfile(path) || return nothing
        if isnothing(next_path)
            while !finished[]
                sleep(0.25)
            end
        else
            while !isfile(next_path) && !finished[]
                sleep(0.25)
            end
            isfile(next_path) || return nothing
        end
        daily_file_complete(path) || error("incomplete CASA-CN daily output: $path")
        write_annual_year!(annual_path, path, year)
        push!(completed, year)
        year in RETAINED_DAILY_YEARS || rm(path; force = true)
    end
    return nothing
end

function casa_cn_stage_hook(run_root)
    annual_path = joinpath(run_root, "fresh_reference", ANNUAL_FILENAME)
    state = Dict{String, Any}()
    return function (_, name, stage_dir, event)
        name == "historical" || return nothing
        if event == :before_run
            finished = Ref(false)
            completed = Int[]
            state["finished"] = finished
            state["completed"] = completed
            state["task"] = @async stream_historical!(
                stage_dir,
                annual_path,
                finished,
                completed,
            )
        elseif event == :after_run
            state["finished"][] = true
            wait(state["task"])
            state["completed"] == collect(1901:2014) ||
                error("CASA-CN historical stream did not complete 114 years")
        end
        return nothing
    end
end

function write_workflow(configuration, source_root, collection, run_root)
    prepared = prepare_inputs(configuration, source_root, collection, run_root)
    controls = joinpath(run_root, "configuration", "controls")
    mkpath(controls)
    stages = Dict{String, Any}[]
    for stage in stage_specs(configuration)
        parameters =
            stage.name == "prespin" ? prepared.prespin :
            stage.name == "accelerated_spin" ? prepared.accelerated :
            prepared.normal
        control = Harness.write_smoke_control(
            controls;
            points = 80,
            daily_output = stage.daily ? 1 : 0,
            soil_model = 1,
            loops = stage.loops,
            initialization = stage.initialization,
            years = (first(stage.years), last(stage.years)),
            cycle = configuration == :carbon_only ? 1 : 2,
            meteorology = "met_1901_1901.nc",
            casa_initial = "casa_initial.csv",
            netcdf_interval = stage.interval,
        )
        control_name = "$(stage.name).lst"
        mv(control, joinpath(controls, control_name); force = true)
        outputs =
            stage.name == "historical" ? historical_outputs(configuration) :
            ["casa_final.csv", "casa_flux_final.csv"]
        push!(
            stages,
            Dict(
                "name" => stage.name,
                "control" => joinpath("controls", control_name),
                "outputs" => outputs,
                "input" =>
                    stage_inputs(prepared, stage, parameters, configuration),
            ),
        )
    end
    workflow_path = joinpath(run_root, "configuration", "workflow.toml")
    Harness.write_toml_atomic(
        workflow_path,
        Dict(
            "schema_version" => 1,
            "name" => "representative-$(String(configuration))-fresh-worker",
            "source_commit" => PINNED_SOURCE_COMMIT,
            "stage" => stages,
        ),
    )
    stage_hook =
        configuration == :carbon_nitrogen ? casa_cn_stage_hook(run_root) :
        nothing
    return (; workflow_path, stage_hook)
end

function require_empty_directory(path)
    if isdir(path)
        isempty(readdir(path)) || error("CASA fresh run directory is not empty")
    elseif ispath(path)
        error("CASA fresh run path is not a directory")
    else
        mkpath(path)
    end
    return path
end

function validate_reference_template(path, configuration, collection)
    isfile(path) || error("CASA Representative reference template is missing")
    reference = TOML.parsefile(path)
    get(reference, "schema_version", nothing) == 1 &&
        get(reference, "tier", nothing) == "representative" ||
        error("CASA reference template is not Representative")
    Int.(get(reference, "cell_ids", Int[])) ==
    getproperty.(collection.cells, :id) ||
        error("CASA reference template differs from the Representative scope")
    haskey(
        get(reference, "configuration", Dict{String, Any}()),
        String(configuration),
    ) || error("CASA reference template lacks $(String(configuration))")
    return reference
end

function write_nonfinite_results(run_root, model, records)
    isempty(records) && error("CASA nonfinite results are empty")
    path = joinpath(run_root, "nonfinite_results.toml")
    Harness.write_toml_atomic(
        path,
        Dict(
            "schema_version" => 1,
            "model" => model,
            "scope" => "representative",
            "nonfinite" => records,
        ),
    )
    return path
end

function scientific_pass(report, configuration)
    initialization = get(
        report,
        "initialization_comparison",
        Dict{String, Any}(),
    )
    boundaries = get(report, "boundary_comparison", Dict{String, Any}())
    historical = get(report, "historical_comparison", Dict{String, Any}())
    passive = get(report, "passive_restoration", Dict{String, Any}())
    carbon = get(report, "carbon_budget", Dict{String, Any}())
    passed =
        get(initialization, "all_match", false) &&
        Set(keys(boundaries)) == Set(getproperty.(stage_specs(configuration), :name)) &&
        all(get(boundary, "all_match", false) for boundary in values(boundaries)) &&
        get(historical, "all_match", false) &&
        get(passive, "verified", false) &&
        get(passive, "unaffected_verified", false) &&
        get(passive, "checkpoint_roundtrip_verified", false) &&
        get(carbon, "all_close", false)
    if configuration == :carbon_nitrogen
        nitrogen = get(report, "nitrogen_budget", Dict{String, Any}())
        passed &= get(nitrogen, "all_close", false)
    end
    return passed
end

function write_comparison(run_root, model, configuration, report_path, oracle_path)
    report = TOML.parsefile(report_path)
    passed = scientific_pass(report, configuration)
    report["model"] = model
    report["scope"] = "representative"
    report["outcome"] = passed ? "passed" : "failed"
    report["coverage"] = Dict(
        "scope_cells" => 80,
        "eligible_cells" => 80,
        "compared_cells" => 80,
    )
    report["reference"] = Dict(
        "path" => abspath(oracle_path),
        "sha256" => Generator.TestbedNativeWorkflow.sha256sum(oracle_path),
        "kind" => "fresh_reduced_oracle",
    )
    path = joinpath(run_root, "comparison.toml")
    Harness.write_toml_atomic(path, report)
    return (; path, passed)
end

function run_worker(
    model,
    source_root,
    forcing_root,
    reference_template,
    run_root,
    build_directory;
    scope_manifest_path = REPRESENTATIVE_SCOPE,
    executable_resolver = verified_shared_executable,
    workflow_writer = write_workflow,
    fortran_runner = Harness.run_stage_workflow,
    finisher = Generator.finish_representative_worker,
)
    configuration = model_configuration(model)
    source_root = abspath(source_root)
    forcing_root = abspath(forcing_root)
    reference_template = abspath(reference_template)
    run_root = abspath(run_root)
    require_empty_directory(run_root)
    fixture_manifest = joinpath(forcing_root, "fixture.toml")
    collection = Generator.representative_collection(
        fixture_manifest,
        scope_manifest_path,
    )
    validate_reference_template(reference_template, configuration, collection)
    executable = executable_resolver(build_directory)
    prepared = workflow_writer(configuration, source_root, collection, run_root)
    stages = fortran_runner(
        executable,
        prepared.workflow_path,
        run_root;
        stage_hook = prepared.stage_hook,
    )
    build_metadata_path = joinpath(build_directory, "build_metadata.toml")
    Harness.write_toml_atomic(
        joinpath(run_root, "fortran_output.toml"),
        Dict(
            "schema_version" => 1,
            "model" => model,
            "scope" => "representative",
            "shared_executable_sha256" =>
                Generator.TestbedNativeWorkflow.sha256sum(executable),
            "workflow" => prepared.workflow_path,
            "stages" => length(stages),
        ),
    )
    finished = finisher(
        configuration,
        fixture_manifest,
        scope_manifest_path,
        run_root,
        joinpath(run_root, "julia"),
        reference_template;
        build_metadata_path,
        oracle_path = joinpath(run_root, "reduced_oracle.toml"),
    )
    if !isempty(finished.nonfinite_records)
        write_nonfinite_results(run_root, model, finished.nonfinite_records)
        return (;
            stages,
            finish = finished,
            comparison = nothing,
            nonfinite = finished.nonfinite_records,
        )
    end
    comparison = write_comparison(
        run_root,
        model,
        configuration,
        finished.report_path,
        finished.oracle_path,
    )
    Harness.write_toml_atomic(
        joinpath(run_root, "julia_output.toml"),
        Dict(
            "schema_version" => 1,
            "model" => model,
            "scope" => "representative",
            "report" => comparison.path,
            "report_sha256" =>
                Generator.TestbedNativeWorkflow.sha256sum(comparison.path),
            "reduced_oracle" => finished.oracle_path,
            "reduced_oracle_sha256" =>
                Generator.TestbedNativeWorkflow.sha256sum(finished.oracle_path),
        ),
    )
    return (;
        stages,
        finish = finished,
        comparison,
        nonfinite = Dict{String, Any}[],
    )
end

worker_exit_code(result) =
    !isempty(result.nonfinite) || isnothing(result.comparison) ||
    !result.comparison.passed ? 1 : 0

function main(args = ARGS; runner = run_worker)
    length(args) == 6 || error(
        "usage: casa_fresh_worker.jl MODEL SOURCE_ROOT FORCING_ROOT REFERENCE_TEMPLATE RUN_ROOT BUILD_DIRECTORY",
    )
    return worker_exit_code(runner(args...))
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(TestbedCASAFreshWorker.main())
end
