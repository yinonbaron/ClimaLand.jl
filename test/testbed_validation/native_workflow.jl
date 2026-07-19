module TestbedNativeWorkflow

import ClimaLand
import ClimaTimeSteppers as CTS
import NCDatasets
import SHA
import TOML

"""One workflow phase backed by a repeated, unmaterialized forcing period."""
struct NativeStage
    name::Symbol
    forcing_days::Int
    repeats::Int
    write_output::Bool

    function NativeStage(
        name,
        forcing_days,
        repeats;
        write_output = Symbol(name) == :historical,
    )
        forcing_days > 0 ||
            throw(ArgumentError("forcing_days must be positive"))
        repeats > 0 || throw(ArgumentError("repeats must be positive"))
        return new(Symbol(name), forcing_days, repeats, write_output)
    end
end

step_count(stage::NativeStage) = stage.forcing_days * stage.repeats

function forcing_index(stage::NativeStage, step)
    1 <= step <= step_count(stage) || throw(BoundsError(stage, step))
    return mod1(step, stage.forcing_days)
end

@enum PFTCategory InactivePFT NonwoodyPFT WoodyPFT

function pft_category(code)
    code == 0 && return InactivePFT
    code == 1 && return NonwoodyPFT
    code in (2, 3) && return WoodyPFT
    throw(ArgumentError("unknown Fortran vegetation category $code"))
end

active_value(category::PFTCategory, value) =
    category == InactivePFT ? zero(value) : value
woody_value(category::PFTCategory, value) =
    category == WoodyPFT ? value : zero(value)

function parameter_rows(path, header)
    lines = readlines(path)
    header_index = findfirst(line -> startswith(strip(line), header), lines)
    isnothing(header_index) && error("Parameter section $header was not found")
    rows = Dict{Int, Vector{Float64}}()
    for line in lines[(header_index + 2):(header_index + 19)]
        fields = split(strip(line), ','; keepempty = true)
        pft = parse(Int, strip(first(fields)))
        values = strip.(fields[2:end])
        last_value = findlast(!isempty, values)
        isnothing(last_value) && error("Parameter row $pft is empty")
        rows[pft] = parse.(Float64, values[1:last_value])
    end
    return rows
end

function pft_categories(path)
    lines = readlines(path)
    header_index = findfirst(line -> startswith(strip(line), "vegtype,"), lines)
    isnothing(header_index) &&
        error("IGBP vegetation categories were not found")
    categories = Dict{Int, PFTCategory}()
    for line in lines[(header_index + 1):(header_index + 18)]
        fields = split(strip(line), ','; keepempty = true)
        categories[parse(Int, strip(fields[1]))] =
            pft_category(parse(Int, strip(fields[2])))
    end
    return categories
end

function casa_plant_state(carbon, nitrogen, nutrients, category)
    state = (;
        c_leaf = active_value(category, carbon[1] / 1000),
        c_wood = woody_value(category, carbon[2] / 1000),
        c_fine_root = active_value(category, carbon[3] / 1000),
        c_labile = 0.0,
    )
    nutrients == :carbon_only && return state
    return merge(
        state,
        (;
            n_leaf = active_value(category, nitrogen[1] / 1000),
            n_wood = woody_value(category, nitrogen[2] / 1000),
            n_fine_root = active_value(category, nitrogen[3] / 1000),
        ),
    )
end

function casa_soil_state(carbon, nitrogen, nutrients, category)
    state = (;
        c_litter_metabolic = active_value(category, carbon[4] / 1000),
        c_litter_structural = active_value(category, carbon[5] / 1000),
        c_litter_cwd = woody_value(category, carbon[6] / 1000),
        c_soil_microbial = active_value(category, carbon[7] / 1000),
        c_soil_slow = active_value(category, carbon[8] / 1000),
        c_soil_passive = active_value(category, carbon[9] / 1000),
    )
    nutrients == :carbon_only && return state
    return merge(
        state,
        (;
            n_litter_metabolic = active_value(category, nitrogen[4] / 1000),
            n_litter_structural = active_value(category, nitrogen[5] / 1000),
            n_litter_cwd = woody_value(category, nitrogen[6] / 1000),
            n_soil_microbial = active_value(category, nitrogen[7] / 1000),
            n_soil_slow = active_value(category, nitrogen[8] / 1000),
            n_soil_passive = active_value(category, nitrogen[9] / 1000),
            n_mineral = active_value(category, nitrogen[10] / 1000),
        ),
    )
end

function mimics_soil_state(
    carbon,
    nitrogen,
    nutrients,
    category,
    microbial_carbon_nitrogen,
)
    state = (;
        c_litter_metabolic = active_value(category, 0.001),
        c_litter_structural = active_value(category, 0.001),
        c_litter_cwd = woody_value(category, carbon[6] / 1000),
        c_microbe_r = active_value(category, 0.000015),
        c_microbe_k = active_value(category, 0.000025),
        c_soil_available = active_value(category, 0.001),
        c_soil_chemical = active_value(category, 0.001),
        c_soil_physical = active_value(category, 0.001),
    )
    nutrients == :carbon_only && return state
    return merge(
        state,
        (;
            n_litter_metabolic = active_value(category, 0.0001),
            n_litter_structural = active_value(category, 0.0001),
            n_microbe_r = active_value(
                category,
                0.000015 / microbial_carbon_nitrogen[1],
            ),
            n_microbe_k = active_value(
                category,
                0.000025 / microbial_carbon_nitrogen[2],
            ),
            n_soil_available = active_value(category, 0.0001),
            n_soil_chemical = active_value(category, 0.0001),
            n_soil_physical = active_value(category, 0.0001),
            n_litter_cwd = woody_value(category, nitrogen[6] / 1000),
            n_mineral = active_value(category, nitrogen[10] / 1000),
        ),
    )
end

"""Return native SI initial states using the pinned Fortran prespin rules."""
function fortran_initial_state(
    parameter_file,
    pft;
    soil_model,
    nutrients,
    microbial_carbon_nitrogen = (6.0, 10.0),
)
    soil_model in (:casa, :mimics) ||
        throw(ArgumentError("soil_model must be :casa or :mimics"))
    nutrients in (:carbon_only, :carbon_nitrogen) || throw(
        ArgumentError("nutrients must be :carbon_only or :carbon_nitrogen"),
    )
    carbon = parameter_rows(parameter_file, ",Leaf C")[pft]
    nitrogen =
        nutrients == :carbon_nitrogen ?
        parameter_rows(parameter_file, ",Nleaf")[pft] : Float64[]
    category = pft_categories(parameter_file)[pft]
    plant = casa_plant_state(carbon, nitrogen, nutrients, category)
    soil = if soil_model == :casa
        casa_soil_state(carbon, nitrogen, nutrients, category)
    else
        mimics_soil_state(
            carbon,
            nitrogen,
            nutrients,
            category,
            microbial_carbon_nitrogen,
        )
    end
    component = soil_model == :casa ? :casa_soil : :mimics_soil
    return (; casa_plant = plant, NamedTuple{(component,)}((soil,))...)
end

const FORWARD_EULER = CTS.ExplicitAlgorithm(
    CTS.ExplicitTableau(;
        a = zeros(Int, 1, 1),
        b = ones(Int, 1),
        c = zeros(Int, 1),
    ),
)

function set_initial_state!(Y, model, initial_state)
    components = ClimaLand.land_components(model)
    propertynames(initial_state) == components || error(
        "Initial-state components $(propertynames(initial_state)) do not match $components",
    )
    for component_name in components
        component = getproperty(model, component_name)
        values = getproperty(initial_state, component_name)
        variables = ClimaLand.prognostic_vars(component)
        propertynames(values) == variables || error(
            "Initial variables for $component_name do not match $variables",
        )
        state = getproperty(Y, component_name)
        for variable in variables
            getproperty(state, variable) .= getproperty(values, variable)
        end
    end
    return Y
end

function state_variables(model)
    return [
        (component_name, variable) for
        component_name in ClimaLand.land_components(model) for variable in
        ClimaLand.prognostic_vars(getproperty(model, component_name))
    ]
end

output_name(component, variable) = "$(component)__$(variable)"

function state_units(variable)
    name = String(variable)
    startswith(name, "c_") && return "kg C m-2"
    startswith(name, "n_") && return "kg N m-2"
    return "native SI"
end

function define_output!(
    output,
    model,
    Y,
    diagnostics;
    output_eltype = Float64,
    deflatelevel = 0,
)
    variables = state_variables(model)
    first_component, first_variable = first(variables)
    points = length(
        parent(getproperty(getproperty(Y, first_component), first_variable)),
    )
    NCDatasets.defDim(output, "point", points)
    NCDatasets.defDim(output, "time", Inf)
    time = NCDatasets.defVar(output, "time", Float64, ("time",))
    time.attrib["units"] = "seconds since 1901-01-01 00:00:00"
    time.attrib["calendar"] = "365_day"
    stage_index = NCDatasets.defVar(output, "stage_index", Int32, ("time",))
    forcing = NCDatasets.defVar(output, "forcing_index", Int32, ("time",))
    storage_options =
        (; chunksizes = (points, 1), deflatelevel, shuffle = deflatelevel > 0)
    for (component, variable) in variables
        name = output_name(component, variable)
        state = NCDatasets.defVar(
            output,
            name,
            output_eltype,
            ("point", "time");
            storage_options...,
        )
        state.attrib["long_name"] = "$component $variable"
        state.attrib["units"] = state_units(variable)
    end
    for diagnostic in diagnostics
        state = NCDatasets.defVar(
            output,
            diagnostic.name,
            output_eltype,
            ("point", "time"),
            ;
            storage_options...,
        )
        state.attrib["long_name"] = diagnostic.long_name
        state.attrib["units"] = diagnostic.units
    end
    return variables
end

function write_state!(
    output,
    variables,
    Y,
    p,
    diagnostics,
    record,
    time,
    stage_index,
    forcing_index,
)
    parent(output["time"])[record] = time
    output["stage_index"][record] = stage_index
    output["forcing_index"][record] = forcing_index
    for (component, variable) in variables
        field = getproperty(getproperty(Y, component), variable)
        output[output_name(component, variable)][:, record] =
            vec(Array(parent(field)))
    end
    for diagnostic in diagnostics
        field = diagnostic.compute(Y, p)
        output[diagnostic.name][:, record] = vec(Array(parent(field)))
    end
    return nothing
end

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

function validate_provenance(provenance, stages)
    required = ("model", "configuration", "pft", "parameter_file", "forcing")
    all(haskey(provenance, key) for key in required) ||
        throw(ArgumentError("provenance must contain $(join(required, ", "))"))
    parameter_file = provenance["parameter_file"]
    all(haskey(parameter_file, key) for key in ("source", "sha256")) || throw(
        ArgumentError(
            "parameter_file provenance must contain source and sha256",
        ),
    )
    forcing = provenance["forcing"]
    length(forcing) == length(stages) || throw(
        ArgumentError("forcing provenance must contain one entry per stage"),
    )
    for (entry, stage) in zip(forcing, stages)
        all(haskey(entry, key) for key in ("stage", "source", "sha256")) ||
            throw(
                ArgumentError(
                    "forcing provenance must contain stage, source, and sha256",
                ),
            )
        entry["stage"] == String(stage.name) || throw(
            ArgumentError("forcing provenance is not ordered like the stages"),
        )
    end
    return provenance
end

function stage_checkpoint!(Y, time, model, output_dir, stage)
    checkpoint_dir = joinpath(output_dir, "checkpoints", String(stage.name))
    mkpath(checkpoint_dir)
    ClimaLand.save_checkpoint(Y, time, checkpoint_dir; model)
    checkpoint = only(
        filter(
            path -> endswith(path, ".hdf5"),
            readdir(checkpoint_dir; join = true),
        ),
    )
    return checkpoint
end

"""
    run_workflow(model, initial_state, stages, output_dir; ...)

Run repeated-forcing stages with native ClimaTimeSteppers Forward Euler,
round-trip every stage through a native checkpoint, and stream selected stage
states to NetCDF. `update_forcing!` receives only the stage, forcing index, and
current time, so prognostic state advances exclusively through CTS.
"""
function run_workflow(
    model,
    initial_state,
    stages,
    output_dir;
    dt = 86400.0,
    update_forcing! = (_, _, _) -> nothing,
    before_step! = (_, _, _, _, _) -> nothing,
    after_step! = (_, _, _, _, _) -> nothing,
    diagnostics = (),
    output_eltype = Float64,
    deflatelevel = 0,
    provenance,
)
    dt > 0 || throw(ArgumentError("dt must be positive"))
    isempty(stages) && throw(ArgumentError("at least one stage is required"))
    stage_names = getproperty.(stages, :name)
    allunique(stage_names) || throw(ArgumentError("stage names must be unique"))
    validate_provenance(provenance, stages)
    mkpath(output_dir)

    Y, p, _ = ClimaLand.initialize(model)
    set_initial_state!(Y, model, initial_state)
    time = 0.0
    ClimaLand.make_set_initial_cache(model)(p, Y, time)
    tendency! = ClimaLand.make_exp_tendency(model)
    checkpoints = String[]
    stage_manifests = Dict{String, Any}[]
    output_path = joinpath(output_dir, "historical.nc")
    recorded_steps = 0

    NCDatasets.NCDataset(output_path, "c") do output
        variables = define_output!(
            output,
            model,
            Y,
            diagnostics;
            output_eltype,
            deflatelevel,
        )
        output_record = 0
        for (stage_index, stage) in enumerate(stages)
            start_time = time
            stage_output_start = output_record
            stop_time = start_time + step_count(stage) * dt
            problem = CTS.ODEProblem(
                CTS.ClimaODEFunction((T_exp!) = tendency!),
                Y,
                (start_time, stop_time),
                p,
            )
            integrator =
                CTS.init(problem, FORWARD_EULER; dt, save_everystep = false)
            for step in 1:step_count(stage)
                index = forcing_index(stage, step)
                update_forcing!(stage, index, integrator.t)
                before_step!(
                    stage,
                    step,
                    integrator.u,
                    integrator.p,
                    integrator.t,
                )
                CTS.step!(integrator)
                after_step!(
                    stage,
                    step,
                    integrator.u,
                    integrator.p,
                    integrator.t,
                )
                recorded_steps += 1
                if stage.write_output
                    output_record += 1
                    write_state!(
                        output,
                        variables,
                        integrator.u,
                        integrator.p,
                        diagnostics,
                        output_record,
                        integrator.t - start_time,
                        stage_index,
                        index,
                    )
                end
            end
            integrator.t == stop_time || error(
                "Stage $(stage.name) stopped at $(integrator.t), expected $stop_time",
            )
            Y = integrator.u
            time = integrator.t
            checkpoint = stage_checkpoint!(Y, time, model, output_dir, stage)
            push!(checkpoints, checkpoint)
            push!(
                stage_manifests,
                Dict(
                    "name" => String(stage.name),
                    "forcing_days" => stage.forcing_days,
                    "repeats" => stage.repeats,
                    "steps" => step_count(stage),
                    "start_time" => start_time,
                    "stop_time" => time,
                    "output_records" => output_record - stage_output_start,
                    "checkpoint" => relpath(checkpoint, output_dir),
                    "checkpoint_sha256" => sha256sum(checkpoint),
                ),
            )
            Y, time = ClimaLand.read_checkpoint(checkpoint; model)
            _, p, _ = ClimaLand.initialize(model)
            ClimaLand.make_set_initial_cache(model)(p, Y, time)
        end
    end

    manifest_path = joinpath(output_dir, "workflow.toml")
    manifest = Dict(
        "schema_version" => 1,
        "calendar" => "365_day",
        "temporal_scheme" => "ForwardEuler",
        "state_updates" => "ClimaTimeSteppers only",
        "dt_seconds" => dt,
        "recorded_steps" => recorded_steps,
        "output" => basename(output_path),
        "output_eltype" => string(output_eltype),
        "output_deflatelevel" => deflatelevel,
        "output_sha256" => sha256sum(output_path),
        "provenance" => provenance,
        "stage" => stage_manifests,
    )
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted = true)
    end
    return (;
        state = Y,
        time,
        checkpoints,
        output = output_path,
        manifest = manifest_path,
    )
end

end
