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
const MIMICS_C_BOUNDARY_CALIBRATION =
    joinpath(@__DIR__, "validation", "mimics_c_full_grid_calibration.toml")
const MIMICS_C_HISTORICAL_CALIBRATION =
    joinpath(@__DIR__, "validation", "mimics_c_historical_calibration.toml")
const MIMICS_C_STAGE_DIRECTORIES = (
    "prespin" => "01-prespin",
    "spin" => "02-spin",
    "historical" => "03-historical",
)
const MIMICS_C_STAGE_END_DATES = Dict(
    "prespin" => "1901-12-31",
    "spin" => "1920-12-31",
    "historical" => "2014-12-31",
)
const MIMICS_CN_BOUNDARY_CALIBRATION =
    joinpath(@__DIR__, "validation", "mimics_cn_boundary_calibration.toml")
const MIMICS_CN_HISTORICAL_CALIBRATION =
    joinpath(@__DIR__, "validation", "mimics_cn_historical_calibration.toml")
const MIMICS_CN_STAGE_DIRECTORIES = (
    "prespin" => "01-prespin",
    "spin" => "02-spin",
    "spin_continuation" => "03-spin_continuation",
    "historical" => "04-historical",
)
const MIMICS_CN_STAGE_END_DATES = Dict(
    "prespin" => "1901-12-31",
    "spin" => "1920-12-31",
    "spin_continuation" => "1920-12-31",
    "historical" => "2014-12-31",
)
const CORPSE_CALIBRATION =
    joinpath(@__DIR__, "validation", "corpse_c_representative_calibration.toml")
const REPRESENTATIVE_SCOPE =
    joinpath(@__DIR__, "validation", "scopes", "representative.toml")

const MODEL_CAPABILITIES = Dict(
    "CASA-C" => (
        runner = joinpath(@__DIR__, "casa_fresh_worker.jl"),
        entrypoint = "run_worker",
        deepest_scope = "representative",
        shared_build = true,
        completed_phases = (
            "fortran",
            "julia",
            "comparison",
            "eligibility_gap_proposal",
        ),
        representative_ready = true,
        blocker = "",
    ),
    "CASA-CN" => (
        runner = joinpath(@__DIR__, "casa_fresh_worker.jl"),
        entrypoint = "run_worker",
        deepest_scope = "representative",
        shared_build = true,
        completed_phases = (
            "fortran",
            "julia",
            "comparison",
            "eligibility_gap_proposal",
        ),
        representative_ready = true,
        blocker = "",
    ),
    "MIMICS-C" => (
        runner = joinpath(@__DIR__, "selected_mimics_c_validation.jl"),
        entrypoint = "run_mimics_c_80",
        deepest_scope = "representative",
        shared_build = true,
        completed_phases = (
            "fortran",
            "julia",
            "comparison",
            "eligibility_gap_proposal",
        ),
        representative_ready = true,
        blocker = "",
    ),
    "MIMICS-CN" => (
        runner = joinpath(@__DIR__, "selected_mimics_cn_validation.jl"),
        entrypoint = "run_mimics_cn_80",
        deepest_scope = "representative",
        shared_build = true,
        completed_phases = (
            "fortran",
            "julia",
            "comparison",
            "eligibility_gap_proposal",
        ),
        representative_ready = true,
        blocker = "",
    ),
    "CORPSE" => (
        runner = joinpath(@__DIR__, "corpse_fresh_worker.jl"),
        entrypoint = "run_worker",
        deepest_scope = "representative",
        shared_build = true,
        completed_phases = (
            "fortran",
            "julia",
            "comparison",
            "eligibility_gap_proposal",
        ),
        representative_ready = true,
        blocker = "",
    ),
)
const MISSING_MODEL_COMMANDS = Dict(
    model => capability.blocker for
    (model, capability) in MODEL_CAPABILITIES if
    !capability.representative_ready
)

struct AdapterError <: Exception
    message::String
end

Base.showerror(io::IO, error::AdapterError) = print(io, error.message)

struct MIMICSCNNonfiniteError <: Exception
    records::Vector{Dict{String, Any}}
end

struct MIMICSCNonfiniteError <: Exception
    records::Vector{Dict{String, Any}}
end

Base.showerror(io::IO, error::MIMICSCNonfiniteError) = print(
    io,
    "Julia MIMICS-C trajectory became nonfinite for $(length(error.records)) cell(s)",
)

Base.showerror(io::IO, error::MIMICSCNNonfiniteError) = print(
    io,
    "Julia MIMICS-CN trajectory became nonfinite for $(length(error.records)) cell(s)",
)

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

function commands(
    source_root;
    casa_forcing_root = nothing,
    casa_c_reference_template = nothing,
    casa_cn_reference_template = nothing,
    corpse_forcing_root = nothing,
    mimics_c_forcing_root = nothing,
    mimics_cn_forcing_root = nothing,
    mimics_cn_reference_template = nothing,
)
    source_root = abspath(source_root)
    project = dirname(Base.active_project())
    build =
        build_directory ->
            `$(Base.julia_cmd()) --startup-file=no $SCRIPT_PATH build $source_root $build_directory`
    worker = (model, run_directory, build_directory) -> begin
        arguments = String[
            "worker",
            model,
            run_directory,
            build_directory,
            source_root,
        ]
        if model in ("CASA-C", "CASA-CN")
            reference_template =
                model == "CASA-C" ? casa_c_reference_template :
                casa_cn_reference_template
            isnothing(casa_forcing_root) ||
                push!(arguments, abspath(casa_forcing_root))
            isnothing(reference_template) ||
                push!(arguments, abspath(reference_template))
        elseif model == "CORPSE"
            isnothing(corpse_forcing_root) ||
                push!(arguments, abspath(corpse_forcing_root))
        elseif model == "MIMICS-C"
            isnothing(mimics_c_forcing_root) ||
                push!(arguments, abspath(mimics_c_forcing_root))
        elseif model == "MIMICS-CN"
            isnothing(mimics_cn_forcing_root) ||
                push!(arguments, abspath(mimics_cn_forcing_root))
            isnothing(mimics_cn_reference_template) ||
                push!(arguments, abspath(mimics_cn_reference_template))
        end
        `$(Base.julia_cmd()) --startup-file=no --project=$project $SCRIPT_PATH $arguments`
    end
    preflight = models -> begin
        selected = ModelProcesses.select_models(models)
        foreach(require_model_command, selected)
        for (model, reference_template) in (
            "CASA-C" => casa_c_reference_template,
            "CASA-CN" => casa_cn_reference_template,
        )
            model in selected || continue
            !isnothing(casa_forcing_root) &&
                !isnothing(reference_template) || throw(
                AdapterError(
                    "$model Representative fresh worker requires forcing and reference-template paths",
                ),
            )
        end
        if "CORPSE" in selected
            !isnothing(corpse_forcing_root) || throw(
                AdapterError(
                    "CORPSE Representative fresh worker requires a forcing-fixture path",
                ),
            )
        end
        if "MIMICS-C" in selected
            !isnothing(mimics_c_forcing_root) || throw(
                AdapterError(
                    "MIMICS-C Representative fresh worker requires a forcing path",
                ),
            )
        end
        if "MIMICS-CN" in selected
            !isnothing(mimics_cn_forcing_root) &&
                !isnothing(mimics_cn_reference_template) || throw(
                AdapterError(
                    "MIMICS-CN Representative fresh worker requires forcing and reference-template paths",
                ),
            )
        end
        nothing
    end
    mimics_cn =
        (forcing_root, reference_template, run_directory, build_directory) ->
            `$(Base.julia_cmd()) --startup-file=no --project=$project $SCRIPT_PATH run-mimics-cn-80 $source_root $forcing_root $reference_template $run_directory $build_directory`
    return (; build, worker, preflight, mimics_cn)
end

function model_capability(model)
    model in ModelProcesses.MODELS ||
        throw(AdapterError("unknown fresh-reference model: $model"))
    return MODEL_CAPABILITIES[model]
end

function casa_modules()
    parent = parentmodule(@__MODULE__)
    isdefined(parent, :TestbedCASAFreshWorker) || Base.include(
        parent,
        joinpath(@__DIR__, "casa_fresh_worker.jl"),
    )
    return Base.invokelatest(getproperty, parent, :TestbedCASAFreshWorker)
end

function run_casa_80(
    model,
    source_root,
    forcing_root,
    reference_template,
    run_directory,
    build_directory,
)
    worker = casa_modules()
    run_worker = Base.invokelatest(getproperty, worker, :run_worker)
    return Base.invokelatest(
        run_worker,
        model,
        source_root,
        forcing_root,
        reference_template,
        run_directory,
        build_directory,
    )
end

function corpse_modules()
    parent = parentmodule(@__MODULE__)
    for (name, file) in (
        :TestbedCORPSEFreshWorker => "corpse_fresh_worker.jl",
        :TestbedRepresentativeCORPSEFortran =>
            "representative_corpse_fortran.jl",
        :GenerateRepresentativeCORPSEReference =>
            "generate_representative_corpse_reference.jl",
        :GeneratePinnedCORPSEPayload => "generate_pinned_corpse_payload.jl",
        :TestbedCORPSEFreshJuliaExecutor =>
            "corpse_fresh_julia_executor.jl",
    )
        isdefined(parent, name) || Base.include(parent, joinpath(@__DIR__, file))
    end
    return (;
        worker = Base.invokelatest(
            getproperty,
            parent,
            :TestbedCORPSEFreshWorker,
        ),
        fortran = Base.invokelatest(
            getproperty,
            parent,
            :TestbedRepresentativeCORPSEFortran,
        ),
        reducer = Base.invokelatest(
            getproperty,
            parent,
            :GenerateRepresentativeCORPSEReference,
        ),
        payload = Base.invokelatest(
            getproperty,
            parent,
            :GeneratePinnedCORPSEPayload,
        ),
        julia = Base.invokelatest(
            getproperty,
            parent,
            :TestbedCORPSEFreshJuliaExecutor,
        ),
    )
end

function build_corpse_fresh_payload(modules, boundary_root, oracle, destination)
    boundaries = Base.invokelatest(
        getproperty(modules.payload, :create_boundary_payload),
        boundary_root,
        joinpath(destination, "boundaries.tar"),
        joinpath(destination, "boundaries.toml"),
    )
    reduced_history = joinpath(destination, "reduced_history.nc")
    reduced_history_manifest = joinpath(destination, "reduced_history.toml")
    cp(oracle, reduced_history; force = true)
    cp(oracle * ".toml", reduced_history_manifest; force = true)
    return (; boundaries..., reduced_history, reduced_history_manifest)
end

function run_corpse_80(
    source_root,
    forcing_root,
    run_directory,
    build_directory;
    worker_runner = nothing,
)
    modules = corpse_modules()
    selected_runner =
        isnothing(worker_runner) ?
        Base.invokelatest(getproperty, modules.worker, :run_worker) :
        worker_runner
    fixture_manifest = joinpath(abspath(forcing_root), "fixture.toml")
    fortran_runner = (; kwargs...) ->
        Base.invokelatest(
            Base.invokelatest(getproperty, modules.fortran, :run);
            kwargs...,
        )
    reference_reducer = (scope, historical, output) -> Base.invokelatest(
        Base.invokelatest(getproperty, modules.reducer, :generate),
        scope,
        historical,
        output,
    )
    payload_builder = (boundaries, oracle, destination) ->
        build_corpse_fresh_payload(modules, boundaries, oracle, destination)
    julia_runner = function (;
        output_root,
        bundle,
        boundary_root,
        fixture_manifest,
        scope_manifest,
        calibration_manifest,
        observer,
        kwargs...,
    )
        return Base.invokelatest(
            Base.invokelatest(getproperty, modules.julia, :execute),
            output_root;
            boundary_root,
            reduced_reference = bundle.reduced_history,
            fixture_manifest,
            scope_manifest,
            calibration_manifest,
            observer,
        )
    end
    return Base.invokelatest(
        selected_runner,
        source_root,
        fixture_manifest,
        run_directory,
        build_directory;
        scope_manifest = REPRESENTATIVE_SCOPE,
        calibration_manifest = CORPSE_CALIBRATION,
        executable_resolver = verified_executable,
        fortran_runner,
        reference_reducer,
        payload_builder,
        julia_runner,
    )
end

function require_model_command(model)
    capability = model_capability(model)
    capability.representative_ready && return capability
    throw(
        AdapterError(
            "$model Representative fresh worker is unavailable: " *
            capability.blocker,
        ),
    )
end

function status_document()
    models = Dict(
        model => Dict(
            "runner" => capability.runner,
            "entrypoint" => capability.entrypoint,
            "deepest_scope" => capability.deepest_scope,
            "shared_build" => capability.shared_build,
            "completed_phases" => collect(capability.completed_phases),
            "representative_ready" => capability.representative_ready,
            "blocker" => capability.blocker,
        ) for (model, capability) in MODEL_CAPABILITIES
    )
    return Dict(
        "schema_version" => 1,
        "representative_workers_ready" => all(
            capability.representative_ready for
            capability in values(MODEL_CAPABILITIES)
        ),
        "model" => models,
        "available_tracer" => Dict(
            "model" => CASA_C_TRACER_MODEL,
            "scope" => CASA_C_TRACER_SCOPE,
            "contract" => CASA_C_TRACER_CONTRACT,
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

function pin_workflow_source!(path)
    workflow = TOML.parsefile(path)
    get(workflow, "schema_version", nothing) == 1 ||
        throw(AdapterError("MIMICS-CN workflow schema is incompatible"))
    workflow["source_commit"] = PINNED_SOURCE_COMMIT
    Harness.write_toml_atomic(path, workflow)
    return path
end

function first_mimics_cn_boundary_nonfinites(boundaries, cell_ids)
    records = Dict{String, Any}[]
    seen = Set{Int}()
    for (stage, _) in MIMICS_CN_STAGE_DIRECTORIES
        values = get(boundaries, stage, nothing)
        values isa AbstractDict ||
            throw(AdapterError("MIMICS-CN boundary output lacks $stage"))
        for position in eachindex(cell_ids)
            cell_id = cell_ids[position]
            cell_id in seen && continue
            for variable in sort!(String.(collect(keys(values))))
                data = values[variable]
                data isa AbstractVector && length(data) == length(cell_ids) ||
                    throw(
                        AdapterError(
                            "MIMICS-CN boundary output has incompatible $stage.$variable values",
                        ),
                    )
                isfinite(data[position]) && continue
                push!(
                    records,
                    Dict(
                        "cell_id" => cell_id,
                        "evidence_side" => "fortran",
                        "first_nonfinite_date" =>
                            MIMICS_CN_STAGE_END_DATES[stage],
                        "first_nonfinite_stage" => stage,
                        "first_nonfinite_variable" => variable,
                        "reason" =>
                            "fresh Fortran MIMICS-CN boundary became nonfinite",
                    ),
                )
                push!(seen, cell_id)
                break
            end
        end
    end
    sort!(records; by = record -> record["cell_id"])
    return records
end

function earliest_mimics_cn_nonfinites(record_groups...)
    stage_rank = Dict(
        stage => rank for
        (rank, (stage, _)) in enumerate(MIMICS_CN_STAGE_DIRECTORIES)
    )
    earliest = Dict{Int, Dict{String, Any}}()
    for record in Iterators.flatten(record_groups)
        cell_id = record["cell_id"]
        candidate_key = (
            stage_rank[record["first_nonfinite_stage"]],
            record["first_nonfinite_date"],
            record["first_nonfinite_variable"],
        )
        previous = get(earliest, cell_id, nothing)
        previous_key = isnothing(previous) ? nothing : (
            stage_rank[previous["first_nonfinite_stage"]],
            previous["first_nonfinite_date"],
            previous["first_nonfinite_variable"],
        )
        if isnothing(previous_key) || candidate_key < previous_key
            earliest[cell_id] = record
        end
    end
    return sort!(collect(values(earliest)); by = record -> record["cell_id"])
end

function noleap_date(year, day_of_year)
    1 <= day_of_year <= 365 ||
        throw(AdapterError("MIMICS-CN day is outside the no-leap calendar"))
    month_lengths = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
    month = 1
    day = day_of_year
    while day > month_lengths[month]
        day -= month_lengths[month]
        month += 1
    end
    return "$(lpad(year, 4, '0'))-$(lpad(month, 2, '0'))-$(lpad(day, 2, '0'))"
end

function mimics_cn_stage_date(stage, step)
    name = String(stage.name)
    start_year, forcing_days = get(
        Dict(
            "prespin" => (1901, 365),
            "spin" => (1901, 20 * 365),
            "spin_continuation" => (1901, 20 * 365),
            "historical" => (1901, 114 * 365),
        ),
        name,
    ) do
        throw(AdapterError("unknown MIMICS-CN stage $name"))
    end
    forcing_index = mod1(step, forcing_days)
    year = start_year + div(forcing_index - 1, 365)
    return noleap_date(year, mod1(forcing_index, 365))
end

function mimics_cn_nonfinite_records(
    values,
    cell_ids;
    evidence_side,
    stage,
    date,
    reason,
)
    records = Dict{String, Any}[]
    variables = sort!(String.(collect(keys(values))))
    for position in eachindex(cell_ids)
        variable = findfirst(variables) do name
            data = values[name]
            data isa AbstractVector && length(data) == length(cell_ids) ||
                throw(
                    AdapterError(
                        "MIMICS-CN trajectory has incompatible $name values",
                    ),
                )
            value = data[position]
            value isa Real && !isfinite(value)
        end
        isnothing(variable) && continue
        push!(
            records,
            Dict(
                "cell_id" => cell_ids[position],
                "evidence_side" => evidence_side,
                "first_nonfinite_date" => date,
                "first_nonfinite_stage" => stage,
                "first_nonfinite_variable" => variables[variable],
                "reason" => reason,
            ),
        )
    end
    return records
end

function mimics_cn_julia_nonfinite_observer(cell_ids)
    return (stage, step, Y, p, diagnostics) -> begin
        values = Dict{String, Any}(
            "$(component).$(variable)" => vec(
                parent(getproperty(getproperty(Y, component), variable)),
            ) for component in propertynames(Y) for
            variable in propertynames(getproperty(Y, component))
        )
        for diagnostic in diagnostics
            values[replace(diagnostic.name, "__" => ".")] = vec(
                parent(diagnostic.compute(Y, p)),
            )
        end
        records = mimics_cn_nonfinite_records(
            values,
            cell_ids;
            evidence_side = "julia",
            stage = String(stage.name),
            date = mimics_cn_stage_date(stage, step),
            reason = "fresh Julia MIMICS-CN trajectory became nonfinite",
        )
        isempty(records) || throw(MIMICSCNNonfiniteError(records))
        return nothing
    end
end

function first_mimics_cn_historical_nonfinites(
    years,
    cell_ids,
    read_year,
)
    records = Dict{String, Any}[]
    seen = Set{Int}()
    for year in years
        values = read_year(year)
        variables = sort!(String.(collect(keys(values))))
        first_days = fill(typemax(Int), length(cell_ids))
        first_variables = fill("", length(cell_ids))
        for variable in variables
            matrix = values[variable]
            matrix isa AbstractMatrix && size(matrix, 1) == length(cell_ids) &&
                size(matrix, 2) == 365 || throw(
                AdapterError(
                    "MIMICS-CN historical trajectory has incompatible $variable values",
                ),
            )
            for position in eachindex(cell_ids)
                cell_ids[position] in seen && continue
                day = findfirst(
                    value -> value isa Real && !isfinite(value),
                    view(matrix, position, :),
                )
                isnothing(day) && continue
                if day < first_days[position]
                    first_days[position] = day
                    first_variables[position] = variable
                end
            end
        end
        for position in eachindex(cell_ids)
            first_days[position] == typemax(Int) && continue
            push!(
                records,
                Dict(
                    "cell_id" => cell_ids[position],
                    "evidence_side" => "fortran",
                    "first_nonfinite_date" =>
                        noleap_date(year, first_days[position]),
                    "first_nonfinite_stage" => "historical",
                    "first_nonfinite_variable" => first_variables[position],
                    "reason" =>
                        "fresh Fortran MIMICS-CN historical trajectory became nonfinite",
                ),
            )
            push!(seen, cell_ids[position])
        end
        length(seen) == length(cell_ids) && break
    end
    sort!(records; by = record -> record["cell_id"])
    return records
end

function mimics_cn_boundary_values(selected, run_directory, cell_ids)
    native = selected.NATIVE
    grid = native.native_casa().parse_rows(
        joinpath(run_directory, "stages", "01-prespin", "grid.csv"),
    )
    by_id = Dict(
        parse(Int, strip(row.ijcam)) => index for
        (index, row) in enumerate(grid)
    )
    indices = map(cell_ids) do cell_id
        get(by_id, cell_id) do
            throw(
                AdapterError(
                    "MIMICS-CN Fortran grid has no Representative cell $cell_id",
                ),
            )
        end
    end
    return Dict(
        stage => begin
            root = joinpath(run_directory, "stages", directory)
            casa_columns, casa_rows = native.native_mimics().read_boundary_csv(
                joinpath(root, "casa_final.csv"),
            )
            mimics_columns, mimics_rows =
                native.native_mimics().read_boundary_csv(
                    joinpath(root, "mimics_final.csv"),
                )
            Dict(
                "$(component).$(variable)" => begin
                    columns, rows =
                        source == :casa ? (casa_columns, casa_rows) :
                        (mimics_columns, mimics_rows)
                    [
                        parse(Float64, rows[index][columns[fortran_name]]) for
                        index in indices
                    ]
                end for (fortran_name, source, component, variable) in
                native.BOUNDARY_VARIABLES
            )
        end for (stage, directory) in MIMICS_CN_STAGE_DIRECTORIES
    )
end

function first_mimics_cn_fortran_historical_nonfinites(
    generator,
    run_directory,
    grid,
    cell_ids,
)
    locations = [
        (;
            cell_id = point.cell_id,
            lon_index = point.longitude_index,
            lat_index = point.latitude_index,
        ) for point in grid
    ]
    read_year = year -> begin
        paths = Dict(
            source => generator.reference_dataset(run_directory, source, year) for
            source in (:casa, :mimics)
        )
        generator.NCDatasets.NCDataset(paths[:casa]) do casa
            generator.NCDatasets.NCDataset(paths[:mimics]) do mimics
                return Dict(
                    replace(native_name, "__" => ".") => begin
                        dataset = source == :casa ? casa : mimics
                        selected = generator.Fixtures.selected_values(
                            dataset[fortran_name],
                            locations,
                        )
                        permutedims(Float64.(selected))
                    end for (fortran_name, source, native_name, _) in
                    generator.Native.HISTORICAL_VARIABLES
                )
            end
        end
    end
    return first_mimics_cn_historical_nonfinites(
        generator.Workflow.HISTORICAL_YEARS,
        cell_ids,
        read_year,
    )
end

function write_mimics_cn_nonfinite_results(run_directory, records)
    isempty(records) &&
        throw(AdapterError("MIMICS-CN nonfinite results are empty"))
    path = joinpath(run_directory, "nonfinite_results.toml")
    Harness.write_toml_atomic(
        path,
        Dict(
            "schema_version" => 1,
            "model" => "MIMICS-CN",
            "scope" => "representative",
            "nonfinite" => records,
        ),
    )
    return path
end

function run_mimics_cn_julia(run_directory, runner; kwargs...)
    try
        return (; julia = runner(; kwargs...), nonfinite = Dict{String, Any}[])
    catch error
        error isa MIMICSCNNonfiniteError || rethrow()
        write_mimics_cn_nonfinite_results(run_directory, error.records)
        return (; julia = nothing, nonfinite = error.records)
    end
end

function write_mimics_cn_comparison(run_directory, scientific_path, oracle_path)
    report = TOML.parsefile(scientific_path)
    get(report, "schema_version", nothing) == 1 ||
        throw(AdapterError("MIMICS-CN comparison report schema is incompatible"))
    coverage = get(report, "coverage", Dict{String, Any}())
    get(coverage, "scope_cells", nothing) == 80 &&
        get(coverage, "compared_cells", nothing) == 80 ||
        throw(AdapterError("MIMICS-CN comparison report is not Representative"))
    boundaries = get(report, "boundary_comparison", Dict{String, Any}())
    Set(String.(keys(boundaries))) ==
    Set(first.(MIMICS_CN_STAGE_DIRECTORIES)) || throw(
        AdapterError("MIMICS-CN comparison report lacks stage boundaries"),
    )
    historical = get(report, "historical_comparison", Dict{String, Any}())
    carbon = get(report, "carbon_budget", Dict{String, Any}())
    nitrogen = get(report, "nitrogen_budget", Dict{String, Any}())
    passed =
        all(get(boundary, "all_match", false) for boundary in values(boundaries)) &&
        get(historical, "all_match", false) &&
        get(carbon, "all_close", false) &&
        get(nitrogen, "all_close", false)
    report["model"] = "MIMICS-CN"
    report["scope"] = "representative"
    report["outcome"] = passed ? "passed" : "failed"
    report["reference"] = Dict(
        "path" => abspath(oracle_path),
        "sha256" => sha256sum(oracle_path),
        "kind" => "fresh_reduced_oracle",
    )
    path = joinpath(run_directory, "comparison.toml")
    Harness.write_toml_atomic(path, report)
    return (; path, passed)
end

function mimics_cn_modules()
    parent = parentmodule(@__MODULE__)
    isdefined(parent, :SelectedMIMICSCNValidation) || Base.include(
        parent,
        joinpath(@__DIR__, "selected_mimics_cn_validation.jl"),
    )
    isdefined(parent, :GenerateSelectedMIMICSCNReference) || Base.include(
        parent,
        joinpath(@__DIR__, "generate_selected_mimics_cn_reference.jl"),
    )
    return nothing
end

function run_mimics_cn_80(args...)
    mimics_cn_modules()
    return Base.invokelatest(_run_mimics_cn_80, args...)
end

function first_mimics_c_boundary_nonfinites(boundaries, cell_ids)
    records = Dict{String, Any}[]
    seen = Set{Int}()
    for (stage, _) in MIMICS_C_STAGE_DIRECTORIES
        values = get(boundaries, stage, nothing)
        values isa AbstractDict ||
            throw(AdapterError("MIMICS-C boundary output lacks $stage"))
        for position in eachindex(cell_ids)
            cell_id = cell_ids[position]
            cell_id in seen && continue
            for variable in sort!(String.(collect(keys(values))))
                data = values[variable]
                data isa AbstractVector && length(data) == length(cell_ids) ||
                    throw(
                        AdapterError(
                            "MIMICS-C boundary output has incompatible $stage.$variable values",
                        ),
                    )
                isfinite(data[position]) && continue
                push!(
                    records,
                    Dict(
                        "cell_id" => cell_id,
                        "evidence_side" => "fortran",
                        "first_nonfinite_date" =>
                            MIMICS_C_STAGE_END_DATES[stage],
                        "first_nonfinite_stage" => stage,
                        "first_nonfinite_variable" => variable,
                        "reason" =>
                            "fresh Fortran MIMICS-C boundary became nonfinite",
                    ),
                )
                push!(seen, cell_id)
                break
            end
        end
    end
    sort!(records; by = record -> record["cell_id"])
    return records
end

function mimics_c_stage_date(stage, step)
    start_year, forcing_days = get(
        Dict(
            "prespin" => (1901, 365),
            "spin" => (1901, 20 * 365),
            "historical" => (1901, 114 * 365),
        ),
        String(stage.name),
    ) do
        throw(AdapterError("unknown MIMICS-C stage $(stage.name)"))
    end
    forcing_index = mod1(step, forcing_days)
    return noleap_date(
        start_year + div(forcing_index - 1, 365),
        mod1(forcing_index, 365),
    )
end

function mimics_c_julia_nonfinite_observer(cell_ids)
    return (stage, step, Y, p, diagnostics) -> begin
        values = Dict{String, Any}(
            "$(component).$(variable)" => vec(
                parent(getproperty(getproperty(Y, component), variable)),
            ) for component in propertynames(Y) for
            variable in propertynames(getproperty(Y, component))
        )
        for diagnostic in diagnostics
            values[replace(diagnostic.name, "__" => ".")] =
                vec(parent(diagnostic.compute(Y, p)))
        end
        records = mimics_cn_nonfinite_records(
            values,
            cell_ids;
            evidence_side = "julia",
            stage = String(stage.name),
            date = mimics_c_stage_date(stage, step),
            reason = "fresh Julia MIMICS-C trajectory became nonfinite",
        )
        isempty(records) || throw(MIMICSCNonfiniteError(records))
        return nothing
    end
end

function first_mimics_c_historical_nonfinites(years, cell_ids, read_year)
    records = Dict{String, Any}[]
    seen = Set{Int}()
    for year in years
        values = read_year(year)
        first_days = fill(typemax(Int), length(cell_ids))
        first_variables = fill("", length(cell_ids))
        for variable in sort!(String.(collect(keys(values))))
            matrix = values[variable]
            matrix isa AbstractMatrix && size(matrix) == (length(cell_ids), 365) ||
                throw(
                    AdapterError(
                        "MIMICS-C historical trajectory has incompatible $variable values",
                    ),
                )
            for position in eachindex(cell_ids)
                cell_ids[position] in seen && continue
                day = findfirst(
                    value -> value isa Real && !isfinite(value),
                    view(matrix, position, :),
                )
                isnothing(day) && continue
                if day < first_days[position]
                    first_days[position] = day
                    first_variables[position] = variable
                end
            end
        end
        for position in eachindex(cell_ids)
            first_days[position] == typemax(Int) && continue
            push!(
                records,
                Dict(
                    "cell_id" => cell_ids[position],
                    "evidence_side" => "fortran",
                    "first_nonfinite_date" =>
                        noleap_date(year, first_days[position]),
                    "first_nonfinite_stage" => "historical",
                    "first_nonfinite_variable" => first_variables[position],
                    "reason" =>
                        "fresh Fortran MIMICS-C historical trajectory became nonfinite",
                ),
            )
            push!(seen, cell_ids[position])
        end
        length(seen) == length(cell_ids) && break
    end
    return sort!(records; by = record -> record["cell_id"])
end

function mimics_c_boundary_values(generator, run_directory, cell_ids)
    indices = generator.source_indices(run_directory, cell_ids)
    native = generator.Native
    return Dict(
        stage => begin
            root = joinpath(run_directory, "stages", directory)
            casa_columns, casa_rows =
                native.read_boundary_csv(joinpath(root, "casa_final.csv"))
            mimics_columns, mimics_rows =
                native.read_boundary_csv(joinpath(root, "mimics_final.csv"))
            Dict(
                "$(component).$(variable)" => begin
                    columns, rows = source == :casa ?
                                    (casa_columns, casa_rows) :
                                    (mimics_columns, mimics_rows)
                    [
                        parse(Float64, rows[index][columns[fortran_name]]) for
                        index in indices
                    ]
                end for (fortran_name, source, component, variable) in
                native.BOUNDARY_VARIABLES
            )
        end for (stage, directory) in MIMICS_C_STAGE_DIRECTORIES
    )
end

function first_mimics_c_fortran_historical_nonfinites(
    generator,
    run_directory,
    grid,
    cell_ids,
)
    locations = [
        (;
            cell_id = point.cell_id,
            lon_index = point.longitude_index,
            lat_index = point.latitude_index,
        ) for point in grid
    ]
    read_year = year -> begin
        paths = Dict(
            source => generator.reference_dataset(run_directory, source, year) for
            source in (:casa, :mimics)
        )
        generator.NCDatasets.NCDataset(paths[:casa]) do casa
            generator.NCDatasets.NCDataset(paths[:mimics]) do mimics
                return Dict(
                    replace(native_name, "__" => ".") => begin
                        dataset = source == :casa ? casa : mimics
                        selected = generator.Fixtures.selected_values(
                            dataset[fortran_name],
                            locations,
                        )
                        permutedims(Float64.(selected))
                    end for (fortran_name, source, native_name, _) in
                    generator.Native.HISTORICAL_VARIABLES
                )
            end
        end
    end
    return first_mimics_c_historical_nonfinites(
        generator.Workflow.HISTORICAL_YEARS,
        cell_ids,
        read_year,
    )
end

function earliest_mimics_c_nonfinites(record_groups...)
    stage_rank = Dict(
        stage => rank for
        (rank, (stage, _)) in enumerate(MIMICS_C_STAGE_DIRECTORIES)
    )
    earliest = Dict{Int, Dict{String, Any}}()
    for record in Iterators.flatten(record_groups)
        key = (
            stage_rank[record["first_nonfinite_stage"]],
            record["first_nonfinite_date"],
            record["first_nonfinite_variable"],
        )
        previous = get(earliest, record["cell_id"], nothing)
        previous_key = isnothing(previous) ? nothing : (
            stage_rank[previous["first_nonfinite_stage"]],
            previous["first_nonfinite_date"],
            previous["first_nonfinite_variable"],
        )
        if isnothing(previous_key) || key < previous_key
            earliest[record["cell_id"]] = record
        end
    end
    return sort!(collect(values(earliest)); by = record -> record["cell_id"])
end

function write_mimics_c_nonfinite_results(run_directory, records)
    isempty(records) && throw(AdapterError("MIMICS-C nonfinite results are empty"))
    path = joinpath(run_directory, "nonfinite_results.toml")
    Harness.write_toml_atomic(
        path,
        Dict(
            "schema_version" => 1,
            "model" => "MIMICS-C",
            "scope" => "representative",
            "nonfinite" => records,
        ),
    )
    return path
end

function run_mimics_c_julia(run_directory, runner; kwargs...)
    try
        return (; julia = runner(; kwargs...), nonfinite = Dict{String, Any}[])
    catch error
        error isa MIMICSCNonfiniteError || rethrow()
        write_mimics_c_nonfinite_results(run_directory, error.records)
        return (; julia = nothing, nonfinite = error.records)
    end
end

function write_mimics_c_comparison(run_directory, scientific_path, oracle_path)
    report = TOML.parsefile(scientific_path)
    get(report, "schema_version", nothing) == 1 ||
        throw(AdapterError("MIMICS-C comparison report schema is incompatible"))
    coverage = get(report, "coverage", Dict{String, Any}())
    get(coverage, "scope_cells", nothing) == 80 &&
        get(coverage, "compared_cells", nothing) == 80 ||
        throw(AdapterError("MIMICS-C comparison report is not Representative"))
    boundaries = get(report, "boundary_comparison", Dict{String, Any}())
    Set(String.(keys(boundaries))) == Set(first.(MIMICS_C_STAGE_DIRECTORIES)) ||
        throw(AdapterError("MIMICS-C comparison report lacks stage boundaries"))
    historical = get(report, "historical_comparison", Dict{String, Any}())
    carbon = get(report, "carbon_budget", Dict{String, Any}())
    passed =
        all(get(boundary, "all_match", false) for boundary in values(boundaries)) &&
        get(historical, "all_match", false) &&
        get(carbon, "all_close", false)
    report["model"] = "MIMICS-C"
    report["scope"] = "representative"
    report["outcome"] = passed ? "passed" : "failed"
    report["reference"] = Dict(
        "path" => abspath(oracle_path),
        "sha256" => sha256sum(oracle_path),
        "kind" => "fresh_reduced_oracle",
    )
    path = joinpath(run_directory, "comparison.toml")
    Harness.write_toml_atomic(path, report)
    return (; path, passed)
end

function mimics_c_modules()
    parent = parentmodule(@__MODULE__)
    isdefined(parent, :SelectedMIMICSCValidation) || Base.include(
        parent,
        joinpath(@__DIR__, "selected_mimics_c_validation.jl"),
    )
    isdefined(parent, :GenerateSelectedMIMICSCReference) || Base.include(
        parent,
        joinpath(@__DIR__, "generate_selected_mimics_c_reference.jl"),
    )
    return nothing
end

function run_mimics_c_80(args...)
    mimics_c_modules()
    return Base.invokelatest(_run_mimics_c_80, args...)
end

function _run_mimics_c_80(
    source_root,
    forcing_root,
    run_directory,
    build_directory,
)
    source_root = abspath(source_root)
    forcing_root = abspath(forcing_root)
    run_directory = abspath(run_directory)
    executable = verified_executable(build_directory)
    Harness.source_commit(source_root) == PINNED_SOURCE_COMMIT ||
        throw(AdapterError("MIMICS-C source is not pinned"))
    isempty(Harness.source_code_status(source_root)) ||
        throw(AdapterError("MIMICS-C SOURCE_CODE has local modifications"))
    fixture_manifest = joinpath(forcing_root, "fixture.toml")
    scope_manifest = joinpath(
        @__DIR__,
        "validation",
        "scopes",
        "representative.toml",
    )
    fixture = TOML.parsefile(fixture_manifest)
    scope = TOML.parsefile(scope_manifest)
    fixture_ids = Int.(fixture["selection"]["representative_cell_ids"])
    fixture_ids == Int.(scope["cell_ids"]) && length(fixture_ids) == 80 ||
        throw(AdapterError("MIMICS-C forcing is not the Representative scope"))
    require_empty_directory(run_directory)

    parent = parentmodule(@__MODULE__)
    selected = getfield(parent, :SelectedMIMICSCValidation)
    generator = getfield(parent, :GenerateSelectedMIMICSCReference)
    prepared = selected.write_workflow(
        source_root,
        run_directory;
        fixture_root = forcing_root,
        points = 80,
        source_commit = PINNED_SOURCE_COMMIT,
    )
    stages = selected.run_fortran(
        executable,
        prepared.workflow_path,
        run_directory,
    )
    Harness.write_toml_atomic(
        joinpath(run_directory, "fortran_output.toml"),
        Dict(
            "schema_version" => 1,
            "model" => "MIMICS-C",
            "scope" => "representative",
            "shared_executable_sha256" => sha256sum(executable),
            "workflow" => prepared.workflow_path,
            "stages" => length(stages),
        ),
    )
    boundary_nonfinite = first_mimics_c_boundary_nonfinites(
        mimics_c_boundary_values(generator, run_directory, fixture_ids),
        fixture_ids,
    )
    collection = generator.Cells.selected_cell_collection(
        "representative",
        fixture_ids;
        manifest_path = fixture_manifest,
    )
    grid = generator.Workflow.selected_casa.selected_grid(
        collection.files["grid"],
        fixture_ids,
    )
    historical_nonfinite = first_mimics_c_fortran_historical_nonfinites(
        generator,
        run_directory,
        grid,
        fixture_ids,
    )
    fortran_nonfinite = earliest_mimics_c_nonfinites(
        boundary_nonfinite,
        historical_nonfinite,
    )
    if !isempty(fortran_nonfinite)
        write_mimics_c_nonfinite_results(run_directory, fortran_nonfinite)
        return (;
            stages,
            julia = nothing,
            comparison = nothing,
            nonfinite = fortran_nonfinite,
        )
    end

    oracle_path = joinpath(run_directory, "reduced_oracle.toml")
    generator.write_reference(
        collection,
        scope_manifest,
        run_directory,
        oracle_path;
        build_metadata_path = joinpath(build_directory, "build_metadata.toml"),
    )
    policy = generator.Workflow.calibration.comparison_policy(
        MIMICS_C_BOUNDARY_CALIBRATION,
        MIMICS_C_HISTORICAL_CALIBRATION,
    )
    julia_result = run_mimics_c_julia(
        run_directory,
        (;
            collection,
            reference_path,
            comparison_policy,
            scope_manifest_path,
            nonfinite_observer,
        ) -> generator.Workflow.run_selected_case(
            joinpath(run_directory, "julia");
            collection,
            reference_path,
            comparison_policy,
            scope_manifest_path,
            nonfinite_observer,
        );
        collection,
        reference_path = oracle_path,
        comparison_policy = policy,
        scope_manifest_path = scope_manifest,
        nonfinite_observer = mimics_c_julia_nonfinite_observer(fixture_ids),
    )
    if !isempty(julia_result.nonfinite)
        return (;
            stages,
            julia = nothing,
            comparison = nothing,
            nonfinite = julia_result.nonfinite,
        )
    end
    julia = julia_result.julia
    comparison = write_mimics_c_comparison(
        run_directory,
        julia.report,
        oracle_path,
    )
    Harness.write_toml_atomic(
        joinpath(run_directory, "julia_output.toml"),
        Dict(
            "schema_version" => 1,
            "model" => "MIMICS-C",
            "scope" => "representative",
            "report" => comparison.path,
            "report_sha256" => sha256sum(comparison.path),
            "reduced_oracle" => oracle_path,
            "reduced_oracle_sha256" => sha256sum(oracle_path),
        ),
    )
    return (;
        stages,
        julia,
        comparison,
        nonfinite = Dict{String, Any}[],
    )
end

function _run_mimics_cn_80(
    source_root,
    forcing_root,
    reference_template,
    run_directory,
    build_directory,
)
    source_root = abspath(source_root)
    forcing_root = abspath(forcing_root)
    reference_template = abspath(reference_template)
    run_directory = abspath(run_directory)
    executable = verified_executable(build_directory)
    Harness.source_commit(source_root) == PINNED_SOURCE_COMMIT || throw(
        AdapterError("MIMICS-CN source is not pinned"),
    )
    isempty(Harness.source_code_status(source_root)) || throw(
        AdapterError("MIMICS-CN SOURCE_CODE has local modifications"),
    )
    fixture_manifest = joinpath(forcing_root, "fixture.toml")
    scope_manifest = joinpath(
        @__DIR__,
        "validation",
        "scopes",
        "representative.toml",
    )
    fixture = TOML.parsefile(fixture_manifest)
    scope = TOML.parsefile(scope_manifest)
    fixture_ids = Int.(fixture["selection"]["representative_cell_ids"])
    fixture_ids == Int.(scope["cell_ids"]) && length(fixture_ids) == 80 ||
        throw(AdapterError("MIMICS-CN forcing is not the Representative scope"))
    isfile(joinpath(reference_template, "configuration", "workflow.toml")) ||
        throw(AdapterError("MIMICS-CN reference template is incomplete"))
    require_empty_directory(run_directory)

    parent = parentmodule(@__MODULE__)
    selected = getfield(parent, :SelectedMIMICSCNValidation)
    generator = getfield(parent, :GenerateSelectedMIMICSCNReference)
    prepared = selected.write_workflow(
        source_root,
        reference_template,
        run_directory;
        fixture_root = forcing_root,
        points = 80,
    )
    pin_workflow_source!(prepared.workflow_path)
    stages = selected.run_fortran(
        executable,
        prepared.workflow_path,
        run_directory,
    )
    Harness.write_toml_atomic(
        joinpath(run_directory, "fortran_output.toml"),
        Dict(
            "schema_version" => 1,
            "model" => "MIMICS-CN",
            "scope" => "representative",
            "shared_executable_sha256" => sha256sum(executable),
            "workflow" => prepared.workflow_path,
            "stages" => length(stages),
        ),
    )
    boundary_values =
        mimics_cn_boundary_values(selected, run_directory, fixture_ids)
    boundary_nonfinite =
        first_mimics_cn_boundary_nonfinites(boundary_values, fixture_ids)

    collection = generator.Cells.selected_cell_collection(
        "representative",
        fixture_ids;
        manifest_path = fixture_manifest,
    )
    selected_grid = generator.Workflow.selected_casa.selected_grid(
        collection.files["grid"],
        fixture_ids,
    )
    historical_nonfinite =
        first_mimics_cn_fortran_historical_nonfinites(
            generator,
            run_directory,
            generator.reference_grid(run_directory, selected_grid),
            fixture_ids,
        )
    fortran_nonfinite = earliest_mimics_cn_nonfinites(
        boundary_nonfinite,
        historical_nonfinite,
    )
    if !isempty(fortran_nonfinite)
        write_mimics_cn_nonfinite_results(
            run_directory,
            fortran_nonfinite,
        )
        return (;
            stages,
            julia = nothing,
            comparison = nothing,
            nonfinite = fortran_nonfinite,
        )
    end
    oracle_path = joinpath(run_directory, "reduced_oracle.toml")
    generator.write_reference(
        collection,
        scope_manifest,
        run_directory,
        oracle_path;
        build_metadata_path = joinpath(build_directory, "build_metadata.toml"),
    )
    policy = generator.Workflow.calibration.comparison_policy(
        MIMICS_CN_BOUNDARY_CALIBRATION,
        MIMICS_CN_HISTORICAL_CALIBRATION,
    )
    julia_result = run_mimics_cn_julia(
        run_directory,
        (;
            collection,
            reference_path,
            comparison_policy,
            nonfinite_observer,
        ) -> generator.Workflow.run_selected_case(
            joinpath(run_directory, "julia");
            collection,
            reference_path,
            comparison_policy,
            nonfinite_observer,
        );
        collection,
        reference_path = oracle_path,
        comparison_policy = policy,
        nonfinite_observer = mimics_cn_julia_nonfinite_observer(fixture_ids),
    )
    if !isempty(julia_result.nonfinite)
        return (;
            stages,
            julia = nothing,
            comparison = nothing,
            nonfinite = julia_result.nonfinite,
        )
    end
    julia = julia_result.julia
    comparison = write_mimics_cn_comparison(
        run_directory,
        julia.report,
        oracle_path,
    )
    Harness.write_toml_atomic(
        joinpath(run_directory, "julia_output.toml"),
        Dict(
            "schema_version" => 1,
            "model" => "MIMICS-CN",
            "scope" => "representative",
            "report" => comparison.path,
            "report_sha256" => sha256sum(comparison.path),
            "reduced_oracle" => oracle_path,
            "reduced_oracle_sha256" => sha256sum(oracle_path),
        ),
    )
    return (;
        stages,
        julia,
        comparison,
        nonfinite = Dict{String, Any}[],
    )
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
        throw(
            AdapterError(
                "expected build, worker, status, trace-casa-c, run-mimics-c-80, or run-mimics-cn-80",
            ),
        )
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
        length(args) in (5, 6, 7) || throw(
            AdapterError(
                "usage: fresh_reference_adapter.jl worker MODEL RUN_DIRECTORY BUILD_DIRECTORY SOURCE_ROOT [FORCING_ROOT [REFERENCE_TEMPLATE]]",
            ),
        )
        model = args[2]
        require_model_command(model)
        if model in ("CASA-C", "CASA-CN")
            length(args) == 7 || throw(
                AdapterError(
                    "$model Representative fresh worker requires forcing and reference-template paths",
                ),
            )
            result = run_casa_80(
                model,
                args[5],
                args[6],
                args[7],
                args[3],
                args[4],
            )
            worker = casa_modules()
            worker_exit_code =
                Base.invokelatest(getproperty, worker, :worker_exit_code)
            return Base.invokelatest(worker_exit_code, result)
        elseif model == "CORPSE"
            length(args) == 6 || throw(
                AdapterError(
                    "CORPSE Representative fresh worker requires a forcing-fixture path",
                ),
            )
            result = run_corpse_80(args[5], args[6], args[3], args[4])
            return result.status in (:passed, :nonfinite) ? 0 : 1
        elseif model == "MIMICS-C"
            length(args) == 6 || throw(
                AdapterError(
                    "MIMICS-C Representative fresh worker requires a forcing path",
                ),
            )
            result = run_mimics_c_80(args[5], args[6], args[3], args[4])
            return isnothing(result.comparison) || result.comparison.passed ? 0 : 1
        elseif model == "MIMICS-CN"
            length(args) == 7 || throw(
                AdapterError(
                    "MIMICS-CN Representative fresh worker requires forcing and reference-template paths",
                ),
            )
            result = run_mimics_cn_80(
                args[5],
                args[6],
                args[7],
                args[3],
                args[4],
            )
            return isnothing(result.comparison) || result.comparison.passed ? 0 : 1
        end
        verified_executable(args[4])
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
    elseif mode == "run-mimics-c-80"
        length(args) == 5 || throw(
            AdapterError(
                "usage: fresh_reference_adapter.jl run-mimics-c-80 SOURCE_ROOT FORCING_ROOT RUN_DIRECTORY BUILD_DIRECTORY",
            ),
        )
        result = run_mimics_c_80(args[2:end]...)
        return isnothing(result.comparison) || result.comparison.passed ? 0 : 1
    elseif mode == "run-mimics-cn-80"
        length(args) == 6 || throw(
            AdapterError(
                "usage: fresh_reference_adapter.jl run-mimics-cn-80 SOURCE_ROOT FORCING_ROOT REFERENCE_TEMPLATE RUN_DIRECTORY BUILD_DIRECTORY",
            ),
        )
        result = run_mimics_cn_80(args[2:end]...)
        return isnothing(result.comparison) || result.comparison.passed ? 0 : 1
    elseif mode == "status"
        TOML.print(stdout, status_document(); sorted = true)
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
