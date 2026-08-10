if !isdefined(@__MODULE__, :TestbedCASACReconstruction)
    include(joinpath(@__DIR__, "casa_c_reconstruction.jl"))
end
if !isdefined(@__MODULE__, :GenerateCompleteSelectedCORPSEReference)
    include(
        joinpath(@__DIR__, "generate_complete_selected_corpse_reference.jl"),
    )
end

module TestbedCORPSECReconstruction

import TOML
import Test

import NCDatasets

const MATRIX_PATH = joinpath(@__DIR__, "corpse_c_reconstruction.toml")
const STAGE_SPECS = (
    (name = "prespin", directory = "01-prespin"),
    (name = "spin", directory = "02-spin"),
    (name = "spin_continuation", directory = "03-spin_continuation"),
    (name = "historical", directory = "04-historical"),
)
const MODEL_PREFIXES = ("casaclm", "corpse")
const INACTIVE_PFTS = Set((13, 15, 17))
const RESTART_AREA_TO_M2 = 1.0e9
const HISTORICAL_CASA_FLOAT32_RTOL = 2Float64(eps(Float32))

casa() = getfield(parentmodule(@__MODULE__), :TestbedCASACReconstruction)
selected() = getfield(
    parentmodule(@__MODULE__),
    :GenerateCompleteSelectedCORPSEReference,
)
harness() = casa().harness()
sha256sum(path) = casa().sha256sum(path)
file_record(path) = casa().file_record(path)

function load_matrix(path = MATRIX_PATH)
    matrix = TOML.parsefile(path)
    get(matrix, "schema_version", 0) == 1 ||
        error("Unsupported CORPSE-C reconstruction matrix schema")
    matrix["issue"] == 44 || error("CORPSE-C matrix must identify issue 44")
    matrix["points"] == 4263 ||
        error("CORPSE-C matrix must retain 4,263 points")
    matrix["source_commit"] == "27ae1a0b673411642cd780ecad66d1c8f84e6a58" ||
        error("CORPSE-C source revision is not pinned")
    matrix["stages"]["prespin"]["loops"] == matrix["prespin_loops"] ||
        error("CORPSE-C prespin loop count is inconsistent")
    for stage in ("spin", "spin_continuation")
        matrix["stages"][stage]["loops"] == matrix["spin_loops"] ||
            error("CORPSE-C $stage loop count is inconsistent")
        matrix["stages"][stage]["years"] == matrix["spin_years"] ||
            error("CORPSE-C $stage years are inconsistent")
    end
    matrix["stages"]["historical"]["years"] == matrix["history_years"] ||
        error("CORPSE-C historical years are inconsistent")
    matrix["legacy_mean"]["status"] == "informational_only" ||
        error("The unreproducible legacy mean cannot be promoted")
    return matrix
end

function retained_daily_years(matrix = load_matrix())
    years = Set{Int}()
    for window in matrix["retention"]["daily_windows"]
        union!(years, first(window):last(window))
    end
    return years
end

netcdf_name(prefix, year; daily = false) =
    "$(prefix)_pool_flux_$(lpad(year, 4, '0'))$(daily ? "_daily" : "").nc"

function control_value_or_empty(line)
    return strip(first(split(line, '!'; limit = 2)))
end

function write_staged_control(source, destination, overrides)
    lines = readlines(source; keep = true)
    while length(lines) < length(harness().CONTROL_FIELDS)
        push!(lines, "\n")
    end
    diffs = Dict{String, Any}[]
    for (field, after) in overrides
        line = findfirst(==(field), harness().CONTROL_FIELDS)
        isnothing(line) && error("Unknown control field: $field")
        before = control_value_or_empty(lines[line])
        after_string = string(after)
        before == after_string && continue
        push!(
            diffs,
            Dict(
                "line" => line,
                "field" => string(field),
                "before" => before,
                "after" => after_string,
            ),
        )
        lines[line] = casa().replace_control_value(lines[line], after_string)
    end
    mkpath(dirname(destination))
    write(destination, join(lines))
    control = harness().parse_control(destination)
    control[:points] == 4263 ||
        error("Staged CORPSE control does not use 4,263 points")
    control[:soil_model] == 3 || error("Staged control is not CORPSE")
    control[:cycle] == 1 || error("Staged control is not carbon-only")
    return Dict(
        "source" => file_record(source),
        "staged" => file_record(destination),
        "diff" => diffs,
    )
end

function verified_static_inputs(source_root, matrix = load_matrix())
    records = Dict{String, Any}()
    for name in (
        "grid",
        "soil",
        "phenology",
        "perturbation",
        "casa_parameters",
        "corpse_parameters",
    )
        path = joinpath(source_root, matrix["inputs"][name])
        isfile(path) || error("Missing CORPSE-C input: $path")
        expected = matrix["inputs"]["$(name)_sha256"]
        actual = sha256sum(path)
        actual == expected ||
            error("CORPSE-C $name hash differs from the matrix")
        records[name] = file_record(path)
    end
    return records
end

function common_inputs(source_root, data_root, years, static)
    workflow_input = harness().workflow_input
    inputs = [
        workflow_input(static["grid"]["path"], "grid.csv"),
        workflow_input(
            static["casa_parameters"]["path"],
            "casa_parameters.csv",
        ),
        workflow_input(static["phenology"]["path"], "phenology.txt"),
        workflow_input(static["soil"]["path"], "soil.csv"),
        workflow_input(
            static["corpse_parameters"]["path"],
            "corpse_parameters.nml",
        ),
        workflow_input(static["perturbation"]["path"], "perturbation.txt"),
    ]
    driver_root =
        joinpath(data_root, load_matrix()["inputs"]["driver_directory"])
    for year in years
        filename = "met_$(year)_$(year).nc"
        push!(
            inputs,
            workflow_input(
                joinpath(driver_root, filename),
                filename;
                mode = "symlink",
            ),
        )
    end
    return inputs
end

function annual_output_years(control)
    years_per_loop = length(first(control[:years]):last(control[:years]))
    total = control[:loops] * years_per_loop
    interval = control[:netcdf_interval]
    return sort!(unique!([1; collect(interval:interval:total); total]))
end

function stage_definition(name, control_path, inputs, matrix = load_matrix())
    control = harness().parse_control(control_path)
    outputs = [
        control[:casa_final],
        control[:casa_flux_final],
        control[:corpse_final],
    ]
    if name == "historical"
        years = first(matrix["history_years"]):last(matrix["history_years"])
        retained = retained_daily_years(matrix)
        for prefix in MODEL_PREFIXES
            append!(outputs, netcdf_name.(Ref(prefix), years))
            append!(
                outputs,
                joinpath.(
                    "selected_daily",
                    netcdf_name.(
                        Ref(prefix),
                        sort!(collect(retained));
                        daily = true,
                    ),
                ),
            )
        end
        return Dict(
            "name" => name,
            "control" => relpath(control_path, dirname(dirname(control_path))),
            "outputs" => outputs,
            "input" => inputs,
            "retention" => matrix["retention"],
        )
    end
    for prefix in MODEL_PREFIXES
        append!(
            outputs,
            netcdf_name.(Ref(prefix), annual_output_years(control)),
        )
        control[:initialization] == 0 &&
            push!(outputs, "$(prefix)_pool_flux_yyyy.nc")
    end
    name in ("spin", "spin_continuation") &&
        push!(outputs, "corpse_spin_output_hashes.toml")
    return Dict(
        "name" => name,
        "control" => relpath(control_path, dirname(dirname(control_path))),
        "outputs" => outputs,
        "input" => inputs,
    )
end

function write_full_workflow(source_root, data_root, run_root)
    source_root = abspath(source_root)
    data_root = abspath(data_root)
    run_root = abspath(run_root)
    matrix = load_matrix()
    static = verified_static_inputs(source_root, matrix)
    configuration = joinpath(run_root, "configuration")
    controls_root = joinpath(configuration, "controls")
    mkpath(controls_root)
    common_overrides = Dict(
        :points => matrix["points"],
        :soil_model => 3,
        :cycle => 1,
        :grid_info => "grid.csv",
        :casa_parameters => "casa_parameters.csv",
        :phenology => "phenology.txt",
        :soil_properties => "soil.csv",
        :meteorology => "met_1901_1901.nc",
        :casa_initial => "casa_initial.csv",
        :casa_final => "casa_final.csv",
        :casa_flux_final => "casa_flux_final.csv",
        :casa_netcdf => "casaclm_pool_flux_yyyy.nc",
        :mimics_parameters => "unused_mimics_parameters.csv",
        :mimics_initial => "unused_mimics_initial.csv",
        :mimics_final => "unused_mimics_final.csv",
        :mimics_netcdf => "unused_mimics_pool_flux_yyyy.nc",
        :corpse_initial => "corpse_initial.csv",
        :corpse_final => "corpse_final.csv",
        :corpse_parameters => "corpse_parameters.nml",
        :corpse_netcdf => "corpse_pool_flux_yyyy.nc",
        :perturbation => "perturbation.txt",
        :point_output_index => -1,
        :point_output_directory => "./",
    )
    controls = Dict{String, String}()
    control_reports = Dict{String, Any}[]
    stage_inputs = Dict{String, Any}()
    for stage_spec in STAGE_SPECS
        name = stage_spec.name
        stage = matrix["stages"][name]
        source = joinpath(source_root, stage["control"])
        destination = joinpath(controls_root, "$name.lst")
        overrides = copy(common_overrides)
        overrides[:loops] = stage["loops"]
        overrides[:initialization] = stage["initialization"]
        overrides[:years] = join(stage["years"], " ")
        overrides[:netcdf_interval] = stage["netcdf_interval"]
        report = write_staged_control(source, destination, overrides)
        report["stage"] = name
        push!(control_reports, report)
        control = harness().parse_control(destination)
        control[:loops] == stage["loops"] ||
            error("CORPSE-C $name loop count differs from the matrix")
        collect(control[:years]) == stage["years"] ||
            error("CORPSE-C $name years differ from the matrix")
        controls[name] = destination
        stage_inputs[name] = common_inputs(
            source_root,
            data_root,
            first(stage["years"]):last(stage["years"]),
            static,
        )
    end
    for index in 2:length(STAGE_SPECS)
        name = STAGE_SPECS[index].name
        predecessor = STAGE_SPECS[index - 1].name
        for model in ("casa", "corpse")
            push!(
                stage_inputs[name],
                harness().workflow_input(
                    "stage:$predecessor/$(model)_final.csv",
                    "$(model)_initial.csv",
                ),
            )
        end
    end
    push!(
        stage_inputs["historical"],
        harness().workflow_input(MATRIX_PATH, "corpse_c_reconstruction.toml"),
    )
    stages = [
        stage_definition(
            stage.name,
            controls[stage.name],
            stage_inputs[stage.name],
            matrix,
        ) for stage in STAGE_SPECS
    ]
    workflow = Dict(
        "schema_version" => 1,
        "name" => "global-fortran-corpse-c",
        "source_commit" => matrix["source_commit"],
        "stage" => stages,
    )
    workflow_path = joinpath(configuration, "workflow.toml")
    harness().write_toml_atomic(workflow_path, workflow)
    harness().write_toml_atomic(
        joinpath(configuration, "control_diff_report.toml"),
        Dict(
            "schema_version" => 1,
            "issue" => matrix["issue"],
            "evidence_matrix" => file_record(MATRIX_PATH),
            "static_input" => static,
            "staged_control" => control_reports,
        ),
    )
    return workflow_path
end

function write_values(variable, values)
    if ndims(variable) == 0
        variable.var[] = values
    else
        indices = ntuple(_ -> Colon(), ndims(variable))
        variable.var[indices...] = values
    end
    return variable
end

function write_annual_mean_file(source_path, destination_path)
    temporary = destination_path * ".tmp"
    isfile(temporary) && rm(temporary; force = true)
    try
        NCDatasets.NCDataset(source_path) do source
            NCDatasets.NCDataset(temporary, "c"; format = :netcdf4) do output
                for (name, value) in source.attrib
                    output.attrib[name] = value
                end
                output.attrib["reduction"] = "arithmetic annual mean over the 365-day time dimension"
                for (name, length_value) in source.dim
                    NCDatasets.defDim(
                        output,
                        name,
                        name == "time" ? 1 : Int(length_value),
                    )
                end
                for name in keys(source)
                    input = source[name]
                    dimensions = NCDatasets.dimnames(input)
                    result =
                        define_output_variable(output, input, name, dimensions)
                    time_dimension = findfirst(==("time"), dimensions)
                    if isnothing(time_dimension)
                        indices = ntuple(_ -> Colon(), ndims(input))
                        values =
                            ndims(input) == 0 ? input.var[] :
                            input.var[indices...]
                        write_values(result, values)
                    else
                        values = casa().annual_mean(input, time_dimension)
                        indices = ntuple(ndims(result)) do dimension
                            dimension == time_dimension ? 1 : Colon()
                        end
                        result.var[indices...] = values
                    end
                end
            end
        end
        mv(temporary, destination_path; force = true)
    finally
        isfile(temporary) && rm(temporary; force = true)
    end
    return destination_path
end

function daily_file_complete(path)
    isfile(path) || return false
    try
        return NCDatasets.NCDataset(path) do dataset
            haskey(dataset.dim, "time") && dataset.dim["time"] == 365
        end
    catch
        return false
    end
end

function netcdf_file_readable(path)
    isfile(path) || return false
    try
        NCDatasets.NCDataset(path) do dataset
            isempty(dataset.dim) || first(values(dataset.dim)) >= 0
        end
        return true
    catch
        return false
    end
end

function stream_spin_outputs!(stage_dir, finished, control)
    total =
        control[:loops] * length(first(control[:years]):last(control[:years]))
    retained = Set(annual_output_years(control))
    records = Dict{String, Any}()
    for year in 1:total
        path = joinpath(stage_dir, netcdf_name("corpse", year))
        next_path =
            year == total ? "" :
            joinpath(stage_dir, netcdf_name("corpse", year + 1))
        while !isfile(path) && !finished[]
            sleep(1)
        end
        isfile(path) || return nothing
        if year == total
            while !finished[]
                sleep(1)
            end
        else
            while !isfile(next_path) && !finished[]
                sleep(1)
            end
            isfile(next_path) || return nothing
        end
        netcdf_file_readable(path) || return nothing
        records[string(year)] =
            Dict("bytes" => filesize(path), "sha256" => sha256sum(path))
        year in retained || rm(path; force = true)
    end
    harness().write_toml_atomic(
        joinpath(stage_dir, "corpse_spin_output_hashes.toml"),
        Dict(
            "schema_version" => 1,
            "outputs" => total,
            "retained_years" => sort!(collect(retained)),
            "year" => records,
        ),
    )
    return nothing
end

function selected_oracle_cell_ids(matrix = load_matrix())
    artifact = joinpath(@__DIR__, matrix["selected_oracle"]["artifact"])
    sha256sum(artifact) == matrix["selected_oracle"]["artifact_sha256"] ||
        error("Selected CORPSE oracle artifact hash differs")
    return NCDatasets.NCDataset(artifact) do dataset
        Int.(dataset["cellid"][:])
    end
end

function selected_indices(selected_ids, available_ids, context)
    return map(selected_ids) do cell_id
        index = findfirst(==(cell_id), available_ids)
        isnothing(index) && error("$context is missing cell $cell_id")
        index
    end
end

selected_float_values(values, indices) = Float64.(vec(values)[indices])

function define_output_variable(output, input, name, dimensions)
    attributes = Dict(input.attrib)
    fill_value = pop!(attributes, "_FillValue", nothing)
    kwargs =
        isnothing(fill_value) ? (; attrib = attributes) :
        (; attrib = attributes, fillvalue = fill_value)
    return NCDatasets.defVar(
        output,
        name,
        eltype(input.var),
        Tuple(dimensions);
        kwargs...,
    )
end

function write_selected_daily_file(source_path, destination_path, selected_ids)
    mkpath(dirname(destination_path))
    temporary = destination_path * ".tmp"
    isfile(temporary) && rm(temporary; force = true)
    try
        NCDatasets.NCDataset(source_path) do source
            cell_variable = source["cellid"]
            cell_dimensions = NCDatasets.dimnames(cell_variable)
            latitude_dimension = findfirst(==("lat"), cell_dimensions)
            longitude_dimension = findfirst(==("lon"), cell_dimensions)
            isnothing(latitude_dimension) &&
                error("Daily output cell IDs have no latitude dimension")
            isnothing(longitude_dimension) &&
                error("Daily output cell IDs have no longitude dimension")
            cell_indices = ntuple(_ -> Colon(), ndims(cell_variable))
            cell_values = Int.(cell_variable.var[cell_indices...])
            locations = map(selected_ids) do cell_id
                location = findfirst(==(cell_id), cell_values)
                isnothing(location) &&
                    error("Daily output is missing selected cell $cell_id")
                indices = Tuple(location)
                (
                    lat = indices[latitude_dimension],
                    lon = indices[longitude_dimension],
                )
            end
            NCDatasets.NCDataset(temporary, "c"; format = :netcdf4) do output
                for (name, value) in source.attrib
                    output.attrib[name] = value
                end
                output.attrib["transformation"] = "all variables subset losslessly to the pinned 37-cell collection"
                NCDatasets.defDim(output, "cell", length(selected_ids))
                for (name, length_value) in source.dim
                    name in ("lat", "lon") && continue
                    NCDatasets.defDim(output, name, Int(length_value))
                end
                for name in keys(source)
                    input = source[name]
                    dimensions = collect(NCDatasets.dimnames(input))
                    spatial = findall(dim -> dim in ("lat", "lon"), dimensions)
                    if isempty(spatial)
                        result = define_output_variable(
                            output,
                            input,
                            name,
                            dimensions,
                        )
                        indices = ntuple(_ -> Colon(), ndims(input))
                        values =
                            ndims(input) == 0 ? input.var[] :
                            input.var[indices...]
                        write_values(result, values)
                        continue
                    end
                    first_spatial = first(spatial)
                    output_dimensions = String[]
                    for (index, dimension) in enumerate(dimensions)
                        if index == first_spatial
                            push!(output_dimensions, "cell")
                        end
                        dimension in ("lat", "lon") ||
                            push!(output_dimensions, dimension)
                    end
                    result = define_output_variable(
                        output,
                        input,
                        name,
                        output_dimensions,
                    )
                    for (cell_index, location) in enumerate(locations)
                        input_indices = ntuple(length(dimensions)) do dimension
                            name = dimensions[dimension]
                            name == "lat" && return location.lat
                            name == "lon" && return location.lon
                            return Colon()
                        end
                        values = input.var[input_indices...]
                        output_indices =
                            ntuple(length(output_dimensions)) do dimension
                                output_dimensions[dimension] == "cell" ?
                                cell_index : Colon()
                            end
                        result.var[output_indices...] = values
                    end
                end
            end
        end
        mv(temporary, destination_path; force = true)
    finally
        isfile(temporary) && rm(temporary; force = true)
    end
    return destination_path
end

function stream_historical_outputs!(stage_dir, finished, matrix = load_matrix())
    years =
        collect(first(matrix["history_years"]):last(matrix["history_years"]))
    retained = retained_daily_years(matrix)
    selected_ids = selected_oracle_cell_ids(matrix)
    for (index, year) in enumerate(years)
        paths = [
            joinpath(stage_dir, netcdf_name(prefix, year; daily = true)) for
            prefix in MODEL_PREFIXES
        ]
        next_paths =
            index == length(years) ? String[] :
            [
                joinpath(
                    stage_dir,
                    netcdf_name(prefix, years[index + 1]; daily = true),
                ) for prefix in MODEL_PREFIXES
            ]
        while !all(isfile, paths) && !finished[]
            sleep(1)
        end
        all(isfile, paths) || return nothing
        if index == length(years)
            while !finished[]
                sleep(1)
            end
        else
            while !all(isfile, next_paths) && !finished[]
                sleep(1)
            end
            all(isfile, next_paths) || return nothing
        end
        all(daily_file_complete, paths) || return nothing
        for (prefix, path) in zip(MODEL_PREFIXES, paths)
            write_annual_mean_file(
                path,
                joinpath(stage_dir, netcdf_name(prefix, year)),
            )
            if year in retained
                write_selected_daily_file(
                    path,
                    joinpath(
                        stage_dir,
                        "selected_daily",
                        netcdf_name(prefix, year; daily = true),
                    ),
                    selected_ids,
                )
            end
            rm(path; force = true)
        end
    end
    return nothing
end

function retention_hook(matrix = load_matrix())
    state = Dict{String, Any}()
    return function (stage, name, stage_dir, event)
        if name in ("spin", "spin_continuation") && event == :before_run
            for filename in readdir(stage_dir)
                occursin(r"^corpse_pool_flux_\d{4}\.nc$", filename) || continue
                rm(joinpath(stage_dir, filename); force = true)
            end
            finished = Ref(false)
            state["$name-finished"] = finished
            control = harness().parse_control(
                joinpath(stage_dir, "fcasacnp_clm_testbed.lst"),
            )
            state["$name-task"] =
                @async stream_spin_outputs!(stage_dir, finished, control)
        elseif name in ("spin", "spin_continuation") && event == :after_run
            state["$name-finished"][] = true
            wait(state["$name-task"])
        elseif name == "historical" && event == :before_run
            for filename in readdir(stage_dir)
                occursin(
                    r"^(casaclm|corpse)_pool_flux_\d{4}_daily\.nc$",
                    filename,
                ) || continue
                rm(joinpath(stage_dir, filename); force = true)
            end
            finished = Ref(false)
            state["finished"] = finished
            state["task"] =
                @async stream_historical_outputs!(stage_dir, finished, matrix)
        elseif name == "historical" && event == :after_run
            state["finished"][] = true
            wait(state["task"])
        end
        return nothing
    end
end

restart_area_m2(value) = parse(Float64, value) * RESTART_AREA_TO_M2

function stage_state(stage_dir)
    casa_path = joinpath(stage_dir, "casa_final.csv")
    corpse_path = joinpath(stage_dir, "corpse_final.csv")
    casa_table = selected().read_csv(casa_path)
    corpse_table = selected().read_csv(corpse_path)
    length(casa_table.rows) == length(corpse_table.rows) ||
        error("CASA and CORPSE restart row counts differ")
    points = length(casa_table.rows)
    npt_column = selected().column(casa_table, "npt")
    parse.(Int, getindex.(casa_table.rows, npt_column)) == collect(1:points) ||
        error("CASA restart rows are not in point order")
    area_column = selected().column(casa_table, "casamet%areacell")
    # The Fortran CSV writer stores casamet%areacell in billions of m².
    areas = restart_area_m2.(getindex.(casa_table.rows, area_column))
    cell_column = selected().column(corpse_table, "ijgcm")
    cell_ids = parse.(Int, getindex.(corpse_table.rows, cell_column))
    length(unique(cell_ids)) == points ||
        error("CORPSE restart cell IDs are not unique")
    pft_column = selected().column(corpse_table, "veg")
    pfts = parse.(Int, getindex.(corpse_table.rows, pft_column))
    casa_fields = filter(
        name -> startswith(lowercase(name), "casapool%c"),
        casa_table.header,
    )
    casa_state = zeros(Float64, length(casa_fields), points)
    for (field_index, field) in enumerate(casa_fields)
        field_column = selected().column(casa_table, field)
        casa_state[field_index, :] =
            parse.(Float64, getindex.(casa_table.rows, field_column))
    end
    corpse_state = zeros(
        Float64,
        length(selected().CORPSE_COMPONENTS),
        points,
        length(selected().LAYERS),
        length(selected().COHORTS),
    )
    for (component_index, component) in enumerate(selected().CORPSE_COMPONENTS),
        (layer_index, layer) in enumerate(selected().LAYERS),
        (cohort_index, cohort) in enumerate(selected().COHORTS)

        field = selected().corpse_column_name(layer, cohort, component)
        field_column = selected().column(corpse_table, field)
        corpse_state[component_index, :, layer_index, cohort_index] =
            parse.(Float64, getindex.(corpse_table.rows, field_column))
    end
    return (;
        casa_path,
        corpse_path,
        areas,
        cell_ids,
        pfts,
        casa_fields,
        casa_state,
        corpse_state,
    )
end

active_carbon(state) =
    vec(sum(state.corpse_state[1:7, :, :, :]; dims = (1, 3, 4)))

function carbon_ledger(state)
    active = active_carbon(state)
    respiration_index =
        findfirst(==("cumulative_respiration"), selected().CORPSE_COMPONENTS)
    original_index =
        findfirst(==("original_carbon"), selected().CORPSE_COMPONENTS)
    respiration =
        vec(sum(state.corpse_state[respiration_index, :, :, :]; dims = (2, 3)))
    original =
        vec(sum(state.corpse_state[original_index, :, :, :]; dims = (2, 3)))
    residual = active .+ respiration .- original
    finite = isfinite.(active) .& isfinite.(respiration) .& isfinite.(original)
    return (; active, respiration, original, residual, finite)
end

function state_diagnostic(state, conservation_atol)
    ledger = carbon_ledger(state)
    active = ledger.active
    respiration = ledger.respiration
    original = ledger.original
    residual = ledger.residual
    finite = ledger.finite
    close = finite .& (abs.(residual) .<= conservation_atol)
    inactive = in.(state.pfts, Ref(INACTIVE_PFTS))
    return Dict(
        "points" => length(state.cell_ids),
        "casa_restart" => file_record(state.casa_path),
        "corpse_restart" => file_record(state.corpse_path),
        "nonfinite_count" => count(!, finite),
        "inactive" => Dict(
            "pfts" => sort!(collect(INACTIVE_PFTS)),
            "cells" => count(inactive),
            "cell_ids" => state.cell_ids[inactive],
            "nonfinite_count" => count(!, finite[inactive]),
            "finite_count" => count(finite[inactive]),
        ),
        "active" => Dict(
            "cells" => count(!, inactive),
            "nonfinite_count" => count(!, finite[.!inactive]),
            "finite_count" => count(finite[.!inactive]),
        ),
        "active_carbon_pg" => sum(active .* state.areas) * 1.0e-12,
        "cumulative_respiration_pg" =>
            sum(respiration .* state.areas) * 1.0e-12,
        "original_carbon_pg" => sum(original .* state.areas) * 1.0e-12,
        "conservation" => Dict(
            "atol_kg_c_m2" => conservation_atol,
            "passing_cells" => count(close),
            "fraction_passing" => count(close) / length(close),
            "maximum_absolute_residual_kg_c_m2" =>
                isempty(residual) ? 0.0 : maximum(abs.(residual)),
            "all_close" => all(close),
        ),
    )
end

function full_workflow_conservation(states, conservation_atol)
    first_state = states[first(STAGE_SPECS).name]
    accounted_source = zeros(Float64, length(first_state.cell_ids))
    cumulative_respiration = zeros(Float64, length(first_state.cell_ids))
    previous_active = zeros(Float64, length(first_state.cell_ids))
    final_active = similar(accounted_source)
    for stage in STAGE_SPECS
        state = states[stage.name]
        state.cell_ids == first_state.cell_ids ||
            error("Cell order changed across the CORPSE workflow")
        state.areas == first_state.areas ||
            error("Cell areas changed across the CORPSE workflow")
        ledger = carbon_ledger(state)
        accounted_source .+= ledger.original .- previous_active
        cumulative_respiration .+= ledger.respiration
        final_active .= ledger.active
        previous_active .= ledger.active
    end
    residual = final_active .+ cumulative_respiration .- accounted_source
    finite =
        isfinite.(final_active) .&
        isfinite.(cumulative_respiration) .&
        isfinite.(accounted_source)
    aggregate_atol = conservation_atol * length(STAGE_SPECS)
    close = finite .& (abs.(residual) .<= aggregate_atol)
    area = first_state.areas
    return Dict(
        "method" => "sum each rebased stage source increment and respiration ledger across exact restart handoffs",
        "points" => length(residual),
        "atol_kg_c_m2" => aggregate_atol,
        "accounted_source_carbon_pg" => sum(accounted_source .* area) * 1.0e-12,
        "final_active_carbon_pg" => sum(final_active .* area) * 1.0e-12,
        "cumulative_respiration_pg" =>
            sum(cumulative_respiration .* area) * 1.0e-12,
        "net_residual_pg" => sum(residual .* area) * 1.0e-12,
        "total_absolute_residual_pg" => sum(abs.(residual) .* area) * 1.0e-12,
        "maximum_absolute_residual_kg_c_m2" =>
            isempty(residual) ? 0.0 : maximum(abs.(residual)),
        "nonfinite_count" => count(!, finite),
        "passing_cells" => count(close),
        "fraction_passing" => count(close) / length(close),
        "all_close" => all(close),
    )
end

function spin_convergence(spin, continuation)
    spin.cell_ids == continuation.cell_ids ||
        error("CORPSE cell order changed between spin stages")
    spin.areas == continuation.areas ||
        error("Cell areas changed between spin stages")
    before = active_carbon(spin)
    after = active_carbon(continuation)
    difference = after .- before
    absolute = abs.(difference)
    relative = absolute ./ max.(abs.(before), eps(Float64))
    finite = isfinite.(before) .& isfinite.(after)
    net_global_delta = sum(difference .* spin.areas) * 1.0e-12
    return Dict(
        "absolute_global_delta_pg" => abs(net_global_delta),
        "net_global_delta_pg" => net_global_delta,
        "total_absolute_global_delta_pg" =>
            sum(absolute .* spin.areas) * 1.0e-12,
        "fraction_below_1_g_m2" => count(absolute .< 0.001) / length(absolute),
        "fraction_below_0_1_percent" =>
            count(relative .< 0.001) / length(relative),
        "nonfinite_count" => count(!, finite),
        "cell" => [
            Dict(
                "cell_id" => spin.cell_ids[index],
                "spin_active_carbon" => before[index],
                "continuation_active_carbon" => after[index],
                "absolute_change" => absolute[index],
                "relative_change" => relative[index],
            ) for index in eachindex(before)
        ],
    )
end

function comparison_record(reference, candidate, atol, rtol)
    size(reference) == size(candidate) ||
        error("Selected CORPSE comparison shapes differ")
    failures = 0
    nonfinite = 0
    max_abs = 0.0
    max_rel = 0.0
    for index in eachindex(reference, candidate)
        expected = reference[index]
        actual = candidate[index]
        if !isfinite(expected) || !isfinite(actual)
            nonfinite += 1
            isequal(expected, actual) || (failures += 1)
            continue
        end
        absolute = abs(actual - expected)
        relative = absolute / max(abs(expected), eps(Float64))
        max_abs = max(max_abs, absolute)
        max_rel = max(max_rel, relative)
        isapprox(actual, expected; atol, rtol) || (failures += 1)
    end
    return Dict(
        "values" => length(reference),
        "failure_count" => failures,
        "nonfinite_count" => nonfinite,
        "maximum_absolute_error" => max_abs,
        "maximum_relative_error" => max_rel,
        "absolute_tolerance" => atol,
        "relative_tolerance" => rtol,
        "all_match" => failures == 0,
    )
end

function selected_oracle_record(run_root, states, matrix = load_matrix())
    oracle_spec = matrix["selected_oracle"]
    artifact = joinpath(@__DIR__, oracle_spec["artifact"])
    manifest = joinpath(@__DIR__, oracle_spec["manifest"])
    sha256sum(artifact) == oracle_spec["artifact_sha256"] ||
        error("Selected CORPSE oracle artifact hash differs")
    sha256sum(manifest) == oracle_spec["manifest_sha256"] ||
        error("Selected CORPSE oracle manifest hash differs")
    atol = matrix["comparison_atol"]
    rtol = matrix["comparison_rtol"]
    records = Dict{String, Any}()
    NCDatasets.NCDataset(artifact) do reference
        selected_ids = Int.(reference["cellid"][:])
        stage_records = Dict{String, Any}()
        for (stage_index, stage_spec) in enumerate(STAGE_SPECS)
            state = states[stage_spec.name]
            indices = selected_indices(
                selected_ids,
                state.cell_ids,
                "Global stage $(stage_spec.name)",
            )
            reference_corpse =
                Float64.(reference["corpse_state"][:, stage_index, :, :, :])
            candidate_corpse = state.corpse_state[:, indices, :, :]
            reference_fields = String.(reference["casa_state_field"][:])
            reference_casa =
                Float64.(reference["casa_state"][:, stage_index, :])
            candidate_casa = zeros(size(reference_casa))
            for (field_index, field) in enumerate(reference_fields)
                source_index = findfirst(==(field), state.casa_fields)
                isnothing(source_index) &&
                    error("Global CASA restart is missing $field")
                candidate_casa[field_index, :] =
                    state.casa_state[source_index, indices]
            end
            stage_records[stage_spec.name] = Dict(
                "casa" => comparison_record(
                    reference_casa,
                    candidate_casa,
                    atol,
                    rtol,
                ),
                "corpse" => comparison_record(
                    reference_corpse,
                    candidate_corpse,
                    atol,
                    rtol,
                ),
            )
        end
        historical_records = Dict{String, Any}()
        historical_root = joinpath(run_root, "stages", "04-historical")
        reference_years = Int.(reference["historical_year"][:])
        casa_fields = String.(reference["historical_casa_field"][:])
        corpse_fields = String.(reference["historical_corpse_field"][:])
        for (year_index, year) in enumerate(reference_years)
            model_records = Dict{String, Any}()
            for (model, prefix, fields, variable) in (
                ("casa", "casaclm", casa_fields, "historical_casa"),
                ("corpse", "corpse", corpse_fields, "historical_corpse"),
            )
                path = joinpath(historical_root, netcdf_name(prefix, year))
                candidate = zeros(Float64, length(fields), length(selected_ids))
                NCDatasets.NCDataset(path) do dataset
                    ids = Int.(vec(dataset["cellid"][:]))
                    indices = selected_indices(
                        selected_ids,
                        ids,
                        "Historical $model output for $year",
                    )
                    for (field_index, field) in enumerate(fields)
                        candidate[field_index, :] =
                            selected_float_values(dataset[field][:], indices)
                    end
                end
                expected = Float64.(reference[variable][:, year_index, :])
                model_atol = atol
                model_rtol =
                    model == "casa" ? HISTORICAL_CASA_FLOAT32_RTOL : rtol
                model_records[model] = comparison_record(
                    expected,
                    candidate,
                    model_atol,
                    model_rtol,
                )
            end
            historical_records[string(year)] = model_records
        end
        records["stage"] = stage_records
        records["historical"] = historical_records
        records["historical_casa_tolerance"] = Dict(
            "basis" => "The global annual means reduce Float32 daily output, while the selected oracle uses the Fortran annual accumulator; allow two Float32 unit roundoffs.",
            "absolute_tolerance" => atol,
            "relative_tolerance" => HISTORICAL_CASA_FLOAT32_RTOL,
        )
        records["artifact"] = file_record(artifact)
        records["manifest"] = file_record(manifest)
    end
    records["all_match"] = all(
        record["all_match"] for group in ("stage", "historical") for
        item in values(records[group]) for record in values(item)
    )
    return records
end

function restart_handoffs(run_root, boundaries)
    stages_root = joinpath(run_root, "stages")
    records = Dict{String, Any}()
    for index in 2:length(STAGE_SPECS)
        stage = STAGE_SPECS[index]
        predecessor = STAGE_SPECS[index - 1]
        stage_root = joinpath(stages_root, stage.directory)
        predecessor_root = joinpath(stages_root, predecessor.directory)
        models = Dict{String, Any}()
        for model in ("casa", "corpse")
            source = joinpath(predecessor_root, "$(model)_final.csv")
            destination = joinpath(stage_root, "$(model)_initial.csv")
            source_md5 = harness().md5sum(source)
            destination_md5 = harness().md5sum(destination)
            models[model] = Dict(
                "source" => file_record(source),
                "destination" => file_record(destination),
                "exact" => source_md5 == destination_md5,
            )
        end
        predecessor_budget = boundaries[predecessor.name]
        records[stage.name] = Dict(
            "model" => models,
            "source_boundary" => predecessor.name,
            "budget" => Dict(
                "active_carbon_pg" =>
                    predecessor_budget["active_carbon_pg"],
                "cumulative_respiration_pg" =>
                    predecessor_budget["cumulative_respiration_pg"],
                "original_carbon_pg" =>
                    predecessor_budget["original_carbon_pg"],
                "conservation" => predecessor_budget["conservation"],
            ),
            "exact" => all(model["exact"] for model in values(models)),
            "conservation_preserved" =>
                all(model["exact"] for model in values(models)) &&
                predecessor_budget["conservation"]["all_close"],
        )
    end
    return records
end

function spin_output_hash_records(run_root, matrix = load_matrix())
    expected =
        matrix["spin_loops"] *
        length(first(matrix["spin_years"]):last(matrix["spin_years"]))
    records = Dict{String, Any}()
    for stage in STAGE_SPECS[2:3]
        stage_root = joinpath(run_root, "stages", stage.directory)
        manifest_path = joinpath(stage_root, "corpse_spin_output_hashes.toml")
        manifest = TOML.parsefile(manifest_path)
        years = get(manifest, "year", Dict())
        retained = Int.(manifest["retained_years"])
        retained_match = all(retained) do year
            path = joinpath(stage_root, netcdf_name("corpse", year))
            haskey(years, string(year)) &&
                isfile(path) &&
                sha256sum(path) == years[string(year)]["sha256"] &&
                filesize(path) == years[string(year)]["bytes"]
        end
        complete =
            manifest["outputs"] == expected &&
            length(years) == expected &&
            all(haskey(years, string(year)) for year in 1:expected) &&
            retained_match
        records[stage.name] = Dict(
            "manifest" => file_record(manifest_path),
            "expected_outputs" => expected,
            "hashed_outputs" => length(years),
            "retained_years" => retained,
            "retained_outputs_match_manifest" => retained_match,
            "complete" => complete,
        )
    end
    return records
end

function write_report(run_root)
    run_root = abspath(run_root)
    matrix = load_matrix()
    states = Dict{String, Any}()
    boundaries = Dict{String, Any}()
    for stage in STAGE_SPECS
        state = stage_state(joinpath(run_root, "stages", stage.directory))
        state.cell_ids |> length == matrix["points"] ||
            error("CORPSE-C stage $(stage.name) does not contain 4,263 cells")
        states[stage.name] = state
        boundaries[stage.name] =
            state_diagnostic(state, matrix["conservation_atol"])
    end
    handoffs = restart_handoffs(run_root, boundaries)
    spin_output_hashes = spin_output_hash_records(run_root, matrix)
    workflow_conservation =
        full_workflow_conservation(states, matrix["conservation_atol"])
    selected_record = selected_oracle_record(run_root, states, matrix)
    historical_root = joinpath(run_root, "stages", "04-historical")
    retained = retained_daily_years(matrix)
    retention = Dict(
        "annual_years" => length(
            first(matrix["history_years"]):last(matrix["history_years"]),
        ),
        "retained_daily_years" => sort!(collect(retained)),
        "annual_outputs_complete" => all(
            isfile(joinpath(historical_root, netcdf_name(prefix, year))) for prefix in MODEL_PREFIXES for year in
            first(matrix["history_years"]):last(matrix["history_years"])
        ),
        "daily_outputs_complete" => all(
            isfile(
                joinpath(
                    historical_root,
                    "selected_daily",
                    netcdf_name(prefix, year; daily = true),
                ),
            ) for prefix in MODEL_PREFIXES for year in retained
        ),
    )
    finite =
        all(record["nonfinite_count"] == 0 for record in values(boundaries))
    conservation = all(
        record["conservation"]["all_close"] for record in values(boundaries)
    )
    handoffs_exact = all(stage["exact"] for stage in values(handoffs))
    handoff_conservation =
        all(stage["conservation_preserved"] for stage in values(handoffs))
    spin_outputs_complete =
        all(record["complete"] for record in values(spin_output_hashes))
    complete =
        finite &&
        conservation &&
        workflow_conservation["all_close"] &&
        handoffs_exact &&
        handoff_conservation &&
        spin_outputs_complete &&
        selected_record["all_match"] &&
        retention["annual_outputs_complete"] &&
        retention["daily_outputs_complete"]
    configuration = joinpath(run_root, "configuration")
    report = Dict(
        "schema_version" => 1,
        "issue" => matrix["issue"],
        "status" => complete ? "complete" : "scientific_checks_failed",
        "points" => matrix["points"],
        "source_commit" => matrix["source_commit"],
        "restart_boundaries_finite" => finite,
        "conservation_closes" => conservation,
        "full_workflow_conservation_closes" =>
            workflow_conservation["all_close"],
        "restart_handoffs_exact" => handoffs_exact,
        "restart_handoff_conservation_preserved" => handoff_conservation,
        "spin_output_hashes_complete" => spin_outputs_complete,
        "selected_oracle_matches" => selected_record["all_match"],
        "boundary" => boundaries,
        "full_workflow_conservation" => workflow_conservation,
        "restart_handoff" => handoffs,
        "spin_output_hash" => spin_output_hashes,
        "spin_convergence" =>
            spin_convergence(states["spin"], states["spin_continuation"]),
        "selected_oracle" => selected_record,
        "retention" => retention,
        "legacy_mean" => matrix["legacy_mean"],
        "configuration" => Dict(
            "matrix" => file_record(MATRIX_PATH),
            "workflow" =>
                file_record(joinpath(configuration, "workflow.toml")),
            "control_diff_report" => file_record(
                joinpath(configuration, "control_diff_report.toml"),
            ),
            "workflow_metadata" => file_record(
                joinpath(run_root, "workflow_metadata.toml"),
            ),
            "build_metadata" => file_record(
                joinpath(run_root, "build", "build_metadata.toml"),
            ),
            "stage_metadata" => Dict(
                stage.name => file_record(
                    joinpath(
                        run_root,
                        "stages",
                        stage.directory,
                        "stage_metadata.toml",
                    ),
                ) for stage in STAGE_SPECS
            ),
            "stage_log" => Dict(
                stage.name => file_record(
                    joinpath(run_root, "stages", stage.directory, "run.log"),
                ) for stage in STAGE_SPECS
            ),
        ),
    )
    path = joinpath(run_root, "reconstruction_report.toml")
    harness().write_toml_atomic(path, report)
    println("CORPSE-C reconstruction report: $path")
    return path
end

function run_reduced_validation(source_root, run_root, matrix = load_matrix())
    reduced_root = joinpath(run_root, "reduced_validation")
    destination = joinpath(reduced_root, "reference")
    result = selected().generate(source_root, reduced_root, destination)
    actual = sha256sum(result.artifact_path)
    expected = matrix["selected_oracle"]["artifact_sha256"]
    actual == expected ||
        error("Reduced CORPSE workflow differs from the pinned selected oracle")
    second = selected().generate(source_root, reduced_root, destination)
    sha256sum(second.artifact_path) == expected ||
        error("Reused reduced CORPSE workflow changed the pinned oracle")
    workflow = TOML.parsefile(joinpath(reduced_root, "workflow_metadata.toml"))
    statuses = String.(getindex.(workflow["stages"], "status"))
    all(status -> status in ("reused", "recovered"), statuses) ||
        error("Reduced CORPSE workflow did not prove stage reuse")
    return Dict(
        "artifact" => file_record(second.artifact_path),
        "manifest" => file_record(second.manifest_path),
        "matches_pinned_oracle" => true,
        "second_run_stage_statuses" => statuses,
        "resumability_verified" => true,
    )
end

function run(source_root, data_root, run_root)
    source_root = abspath(source_root)
    data_root = abspath(data_root)
    run_root = abspath(run_root)
    mkpath(run_root)
    matrix = load_matrix()
    reduced = run_reduced_validation(source_root, run_root, matrix)
    harness().write_toml_atomic(
        joinpath(run_root, "reduced_validation.toml"),
        reduced,
    )
    workflow = write_full_workflow(source_root, data_root, run_root)
    execution_source = casa().ensure_source_revision(
        source_root,
        matrix["source_commit"],
        run_root,
    )
    executable = abspath(
        harness().ensure_fortran_build(
            execution_source,
            run_root;
            expected_commit = matrix["source_commit"],
        ),
    )
    results = harness().run_stage_workflow(
        executable,
        workflow,
        run_root;
        stage_hook = retention_hook(matrix),
    )
    write_report(run_root)
    return results
end

function self_test()
    matrix = load_matrix()
    Test.@testset "CORPSE-C reconstruction" begin
        Test.@test matrix["issue"] == 44
        Test.@test matrix["points"] == 4263
        Test.@test map(stage -> stage.name, STAGE_SPECS) ==
                   ("prespin", "spin", "spin_continuation", "historical")
        Test.@test retained_daily_years(matrix) == Set([1901:1905; 2010:2014])
        Test.@test netcdf_name("corpse", 1901; daily = true) ==
                   "corpse_pool_flux_1901_daily.nc"
        synthetic_state(active, respiration, original) = begin
            corpse_state = zeros(Float64, 10, 1, 1, 1)
            corpse_state[1, 1, 1, 1] = active
            corpse_state[8, 1, 1, 1] = respiration
            corpse_state[9, 1, 1, 1] = original
            (; cell_ids = [1], areas = [1.0], corpse_state)
        end
        synthetic = Dict(
            "prespin" => synthetic_state(10.0, 2.0, 12.0),
            "spin" => synthetic_state(8.0, 3.0, 11.0),
            "spin_continuation" => synthetic_state(7.0, 2.0, 9.0),
            "historical" => synthetic_state(6.0, 4.0, 10.0),
        )
        workflow_budget = full_workflow_conservation(synthetic, 1.0e-4)
        Test.@test workflow_budget["all_close"]
        Test.@test workflow_budget["accounted_source_carbon_pg"] ≈ 17.0e-12
        Test.@test workflow_budget["cumulative_respiration_pg"] ≈ 11.0e-12
        Test.@test workflow_budget["final_active_carbon_pg"] ≈ 6.0e-12
        multi_cell_state = zeros(Float64, 10, 2, 1, 1)
        multi_cell_state[1, :, 1, 1] = [10.0, 20.0]
        multi_cell_state[8, :, 1, 1] = [2.0, 4.0]
        multi_cell_state[9, :, 1, 1] = [12.0, 24.0]
        multi_cell_ledger = carbon_ledger((; corpse_state = multi_cell_state))
        Test.@test multi_cell_ledger.active == [10.0, 20.0]
        Test.@test multi_cell_ledger.respiration == [2.0, 4.0]
        Test.@test multi_cell_ledger.original == [12.0, 24.0]
        Test.@test selected_float_values(
            Union{Missing, Float32}[missing, 2.0],
            [2],
        ) == [2.0]
        Test.@test restart_area_m2("1.25") == 1.25e9
        mktempdir() do root
            source = joinpath(root, "source.lst")
            control = harness().write_smoke_control(
                root;
                points = 4299,
                loops = 1,
                initialization = 2,
                years = (1901, 2010),
                soil_model = 3,
                cycle = 1,
            )
            lines = readlines(control; keep = true)
            lines[29] = "\n"
            write(source, join(lines))
            destination = joinpath(root, "staged.lst")
            report = write_staged_control(
                source,
                destination,
                Dict(
                    :points => 4263,
                    :years => "1901 2014",
                    :netcdf_interval => 1,
                ),
            )
            parsed = harness().parse_control(destination)
            Test.@test parsed[:points] == 4263
            Test.@test parsed[:years] == (1901, 2014)
            Test.@test parsed[:netcdf_interval] == 1
            Test.@test any(
                diff ->
                    diff["field"] == "netcdf_interval" && diff["before"] == "",
                report["diff"],
            )

            daily = joinpath(root, "daily.nc")
            annual = joinpath(root, "annual.nc")
            NCDatasets.NCDataset(daily, "c") do dataset
                NCDatasets.defDim(dataset, "cell", 2)
                NCDatasets.defDim(dataset, "time", 365)
                variable = NCDatasets.defVar(
                    dataset,
                    "stock",
                    Float32,
                    ("cell", "time"),
                )
                variable[:, :] = repeat(Float32[1, 3], 1, 365)
            end
            write_annual_mean_file(daily, annual)
            NCDatasets.NCDataset(annual) do dataset
                Test.@test dataset.dim["time"] == 1
                Test.@test vec(dataset["stock"][:]) == Float32[1, 3]
            end

            full_daily = joinpath(root, "full_daily.nc")
            selected_daily = joinpath(root, "selected", "daily.nc")
            NCDatasets.NCDataset(full_daily, "c") do dataset
                NCDatasets.defDim(dataset, "time", 3)
                NCDatasets.defDim(dataset, "lat", 2)
                NCDatasets.defDim(dataset, "lon", 2)
                cellid =
                    NCDatasets.defVar(dataset, "cellid", Int32, ("lat", "lon"))
                cellid[:, :] = Int32[1 2; 3 4]
                stock = NCDatasets.defVar(
                    dataset,
                    "stock",
                    Float32,
                    ("time", "lat", "lon"),
                )
                stock[:, :, :] = reshape(Float32.(1:12), 3, 2, 2)
            end
            write_selected_daily_file(full_daily, selected_daily, [2, 3])
            NCDatasets.NCDataset(selected_daily) do dataset
                Test.@test Int.(dataset["cellid"][:]) == [2, 3]
                Test.@test dataset["stock"][:, 1] ==
                           reshape(Float32.(1:12), 3, 2, 2)[:, 1, 2]
                Test.@test dataset["stock"][:, 2] ==
                           reshape(Float32.(1:12), 3, 2, 2)[:, 2, 1]
            end

            spin_root = joinpath(root, "spin")
            mkpath(spin_root)
            for year in 1:3
                NCDatasets.NCDataset(
                    joinpath(spin_root, netcdf_name("corpse", year)),
                    "c",
                ) do dataset
                    NCDatasets.defDim(dataset, "cell", 1)
                    stock =
                        NCDatasets.defVar(dataset, "stock", Float32, ("cell",))
                    stock[:] = Float32[year]
                end
            end
            stream_spin_outputs!(
                spin_root,
                Ref(true),
                Dict(
                    :loops => 3,
                    :years => (1901, 1901),
                    :netcdf_interval => 3,
                ),
            )
            spin_manifest = TOML.parsefile(
                joinpath(spin_root, "corpse_spin_output_hashes.toml"),
            )
            Test.@test spin_manifest["outputs"] == 3
            Test.@test length(spin_manifest["year"]) == 3
            Test.@test isfile(joinpath(spin_root, netcdf_name("corpse", 1)))
            Test.@test !isfile(joinpath(spin_root, netcdf_name("corpse", 2)))
            Test.@test isfile(joinpath(spin_root, netcdf_name("corpse", 3)))
        end
    end
    return true
end

function usage(io = stdout)
    println(
        io,
        "Usage: julia corpse_c_reconstruction.jl run " *
        "<source-repo> <data-root> <run-root>",
    )
    println(
        io,
        "       julia corpse_c_reconstruction.jl prepare " *
        "<source-repo> <data-root> <run-root>",
    )
    println(io, "       julia corpse_c_reconstruction.jl report <run-root>")
    println(io, "       julia corpse_c_reconstruction.jl self-test")
end

function main(args)
    isempty(args) && (usage(stderr); return 2)
    try
        if args[1] == "run"
            length(args) == 4 || error("run requires three arguments")
            run(args[2], args[3], args[4])
        elseif args[1] == "prepare"
            length(args) == 4 || error("prepare requires three arguments")
            write_full_workflow(args[2], args[3], args[4])
        elseif args[1] == "report"
            length(args) == 2 || error("report requires one argument")
            write_report(args[2])
        elseif args[1] == "self-test"
            length(args) == 1 || error("self-test takes no arguments")
            self_test()
        else
            usage(stderr)
            return 2
        end
        return 0
    catch error_value
        println(stderr, "error: ", sprint(showerror, error_value))
        return 1
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end

end
