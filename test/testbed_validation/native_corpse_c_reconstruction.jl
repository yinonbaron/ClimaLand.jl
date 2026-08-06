if !isdefined(@__MODULE__, :TestbedSelectedCORPSEWorkflow)
    include(joinpath(@__DIR__, "selected_corpse_workflow.jl"))
end

module TestbedNativeCORPSECReconstruction

import LinearAlgebra
import TOML

import ClimaCore
import ClimaLand
import NCDatasets

const DAY_SECONDS = 86400.0
const TIMEOUT_SECONDS = 2 * 60 * 60
const INELIGIBLE_PFTS = (11, 13, 15, 17)
const STAGE_DIRECTORIES = (
    prespin = "01-prespin",
    spin = "02-spin",
    spin_continuation = "03-spin_continuation",
    historical = "04-historical",
)
const CASA_VARIABLES = (
    "casapool%clabile" => (:casa_plant, :c_labile),
    "casapool%cplant(LEAF)" => (:casa_plant, :c_leaf),
    "casapool%cplant(WOOD)" => (:casa_plant, :c_wood),
    "casapool%cplant(FROOT)" => (:casa_plant, :c_fine_root),
    "casapool%clitter(CWD)" => (:corpse_soil, :c_litter_cwd),
)
const CORPSE_COMPONENTS = (
    "unprotected_labile" => "unprotected_labile",
    "unprotected_recalcitrant" => "unprotected_recalcitrant",
    "unprotected_dead_microbe" => "unprotected_dead_microbe",
    "protected_labile" => "protected_labile",
    "protected_recalcitrant" => "protected_recalcitrant",
    "protected_dead_microbe" => "protected_dead_microbe",
    "living_microbe" => "live_microbe",
    "cumulative_respiration" => "cumulative_co2",
    "original_carbon" => "original_carbon",
)
const LAYERS = ("litter", "soil")
const COHORTS = ("rhizosphere", "bulk")
const REPRESENTATIVE_GAPS = Dict(51 => 17, 3442 => 11)
const REDUCED_SAMPLE_DAYS = sort!([
    (year - 1901) * 365 + start + offset for year in (1901, 1957, 2014) for
    start in (1, 91, 182, 274) for offset in 0:6
],)

selected_corpse() =
    getfield(parentmodule(@__MODULE__), :TestbedSelectedCORPSEWorkflow)
native_casa() = selected_corpse().native_casa()
native_workflow() = selected_corpse().native_workflow()

eligible_cell(point) = !(point.pft in INELIGIBLE_PFTS)
comparison_variable_count() = (
    length(CASA_VARIABLES),
    length(CORPSE_COMPONENTS) * length(LAYERS) * length(COHORTS),
)

function representative_scope(path)
    manifest = TOML.parsefile(path)
    cell_ids = Int.(get(manifest, "cell_ids", Int[]))
    get(manifest, "schema_version", nothing) == 1 &&
        get(manifest, "name", nothing) == "representative" &&
        length(cell_ids) == 80 &&
        cell_ids == sort(unique(cell_ids)) ||
        error("CORPSE requires the immutable 80-cell Representative scope")
    gap_entries = [
        Dict{String, Any}(String(key) => value for (key, value) in gap) for
        gap in get(manifest, "eligibility_gaps", Any[]) if
        get(gap, "model", nothing) == "CORPSE"
    ]
    length(gap_entries) == 2 ||
        error("Representative scope must declare two CORPSE gaps")
    gaps = Dict(
        Int(gap["cell_id"]) => Int(gap["pft"]) for
        gap in gap_entries if get(gap, "reviewed", false) === true &&
        get(gap, "evidence_kind", nothing) == "inactive_model_mask" &&
        get(gap, "first_ineligible_stage", nothing) == "prespin" &&
        get(gap, "evidence_variable", nothing) == "veg%iveg2" &&
        get(gap, "fortran_vegetation_category", nothing) == 0 &&
        !isempty(strip(String(get(gap, "reason", ""))))
    )
    gaps == REPRESENTATIVE_GAPS ||
        error("Representative scope CORPSE gaps are not the reviewed set")
    all(id in cell_ids for id in keys(gaps)) ||
        error("CORPSE reviewed gaps are absent from Representative scope")
    sort!(gap_entries; by = gap -> Int(gap["cell_id"]))
    return (;
        name = "representative",
        path = abspath(path),
        sha256 = native_workflow().sha256sum(path),
        cell_ids,
        gaps,
        gap_entries,
        eligible_cell_ids = filter(id -> !haskey(gaps, id), cell_ids),
    )
end

function assert_single_threaded()
    Threads.nthreads() == 1 ||
        error("CORPSE calibration requires exactly one Julia thread")
    LinearAlgebra.BLAS.get_num_threads() == 1 ||
        error("CORPSE calibration requires exactly one BLAS thread")
    return nothing
end

function canonical_stages()
    stage = native_workflow().NativeStage
    return (
        stage(:prespin, 365, 100; write_output = false),
        stage(:spin, 20 * 365, 499; write_output = false),
        stage(:spin_continuation, 20 * 365, 499; write_output = false),
        stage(:historical, 114 * 365, 1; write_output = false),
    )
end

function benchmark_stages(; days = 2)
    days > 0 || throw(ArgumentError("benchmark days must be positive"))
    stage = native_workflow().NativeStage
    return (
        stage(:prespin, days, 1; write_output = false),
        stage(:spin, days, 1; write_output = false),
        stage(:spin_continuation, days, 1; write_output = false),
        stage(:historical, days, 1; write_output = false),
    )
end

function root_weighted_saturation(roots, water, porosity)
    porosity > 0 || throw(ArgumentError("porosity must be positive"))
    length(roots) == length(water) ||
        throw(DimensionMismatch("root and water layers differ"))
    weighted_water = 0.0
    for layer in eachindex(roots)
        weighted_water += roots[layer] * water[layer]
    end
    return min(1.0, weighted_water / porosity)
end

mutable struct StreamingCORPSEForcing{B, C, M}
    base::B
    buffers::C
    porosity::Vector{Float64}
    frozen_loaded::Dict{Int, BitVector}
    frozen_saturation::Dict{Int, M}
    transient_year::Int
    transient_loaded::BitVector
    transient_saturation::M
end

function StreamingCORPSEForcing(
    grid,
    soils,
    parameters,
    phenology_path,
    forcing_root,
    buffers,
)
    base = native_casa().GriddedForcing(
        grid,
        soils,
        parameters,
        phenology_path,
        forcing_root,
        buffers.base,
    )
    return StreamingCORPSEForcing(
        base,
        buffers,
        [soils[point.cell_id].porosity for point in grid],
        Dict{Int, BitVector}(),
        Dict{Int, Matrix{Float64}}(),
        0,
        falses(365),
        zeros(length(grid), 365),
    )
end

function frozen_cache!(forcing, year)
    points = length(forcing.base.phase)
    if year > 1920
        if forcing.transient_year != year
            forcing.transient_year = year
            forcing.transient_loaded .= false
            forcing.transient_saturation .= 0
        end
        return forcing.transient_loaded, forcing.transient_saturation
    end
    loaded = get!(forcing.frozen_loaded, year) do
        falses(365)
    end
    values = get!(forcing.frozen_saturation, year) do
        zeros(points, 365)
    end
    return loaded, values
end

function load_frozen_day!(forcing, year, day)
    loaded, values = frozen_cache!(forcing, year)
    loaded[day] && return values
    dataset = native_casa().ensure_forcing_year!(forcing.base, year)
    frozen_grid = dataset["xfrznmoist"][:, :, :, day]
    for point in eachindex(forcing.base.phase)
        forcing.base.active[point] || continue
        longitude = forcing.base.longitude_index[point]
        latitude = forcing.base.latitude_index[point]
        roots = view(forcing.base.root_fraction, point, :)
        weighted_frozen = 0.0
        for layer in eachindex(roots)
            weighted_frozen +=
                roots[layer] * native_casa().forcing_value(
                    forcing.base,
                    frozen_grid[longitude, latitude, layer],
                )
        end
        values[point, day] = min(1.0, weighted_frozen / forcing.porosity[point])
    end
    loaded[day] = true
    return values
end

function update_forcing!(forcing::StreamingCORPSEForcing, stage, index, time)
    native_casa().update_forcing!(forcing.base, stage, index, time)
    year, day = native_casa().forcing_year_day(stage, index)
    frozen = load_frozen_day!(forcing, year, day)
    liquid = vec(parent(forcing.buffers.base.liquid_water))
    liquid_saturation = vec(parent(forcing.buffers.liquid_saturation))
    frozen_saturation = vec(parent(forcing.buffers.frozen_saturation))
    for point in eachindex(liquid)
        if forcing.base.active[point]
            liquid_saturation[point] =
                min(1.0, liquid[point] / forcing.porosity[point])
            frozen_saturation[point] = frozen[point, day]
        else
            liquid_saturation[point] = 0.0
            frozen_saturation[point] = 0.0
        end
    end
    return nothing
end

mutable struct StreamingAnnualNPP{F}
    active_stage::Union{Nothing, Symbol}
    accumulated::F
end

StreamingAnnualNPP(buffers) =
    StreamingAnnualNPP(nothing, zero(buffers.exudate_labile))

function first_year_exudate!(destination, forcing)
    cache = native_casa().year_cache!(forcing.base, 1901)
    for day in 1:365
        native_casa().load_forcing_day!(forcing.base, cache, 1901, day)
    end
    for point in eachindex(destination)
        destination[point] =
            forcing.base.active[point] ?
            0.02 * sum(view(cache.gpp, point, :)) / (2 * 365) : 0.0
    end
    return destination
end

function prepare_annual_npp!(tracker, forcing, stage, index)
    mod1(index, 365) == 1 || return nothing
    destination = vec(parent(forcing.buffers.exudate_labile))
    if tracker.active_stage != stage.name
        tracker.active_stage = stage.name
        first_year_exudate!(destination, forcing)
    else
        destination .=
            0.02 .* vec(parent(tracker.accumulated)) ./ (365 * DAY_SECONDS)
    end
    tracker.accumulated .= 0
    return nothing
end

function accumulate_annual_npp!(tracker, p)
    accumulated = tracker.accumulated
    carbon_fluxes = p.casa_plant.carbon_fluxes
    @. accumulated += DAY_SECONDS * getindex(carbon_fluxes, 15)
    return nothing
end

function reduced_state_variables()
    casa = (
        (
            name = "cleaf",
            source = :state,
            component = :casa_plant,
            variables = (:c_leaf,),
            scale = 1000.0,
            units = "g C m-2",
        ),
        (
            name = "cwood",
            source = :state,
            component = :casa_plant,
            variables = (:c_wood,),
            scale = 1000.0,
            units = "g C m-2",
        ),
        (
            name = "cfroot",
            source = :state,
            component = :casa_plant,
            variables = (:c_fine_root,),
            scale = 1000.0,
            units = "g C m-2",
        ),
        (
            name = "clitcwd",
            source = :state,
            component = :corpse_soil,
            variables = (:c_litter_cwd,),
            scale = 1000.0,
            units = "g C m-2",
        ),
    )
    corpse = Tuple(
        begin
            fortran_layer = layer == "soil" ? "Soil" : "LitterLayer"
            fortran_component =
                source == "unprotected_labile" ? "C1" :
                source == "unprotected_recalcitrant" ? "C2" :
                source == "unprotected_dead_microbe" ? "C3" :
                source == "protected_labile" ? "Protected_C1" :
                source == "protected_recalcitrant" ? "Protected_C2" :
                source == "protected_dead_microbe" ? "Protected_C3" :
                source == "living_microbe" ? "LiveMicrobeC" :
                error("unsupported historical CORPSE component $source")
            name = if startswith(fortran_component, "Protected")
                "$(fortran_layer)$(fortran_component)"
            else
                "$(fortran_layer)_$(fortran_component)"
            end
            (
                name,
                source = :state,
                component = :corpse_soil,
                variables = (
                    Symbol(layer, "_rhiz_", suffix),
                    Symbol(layer, "_bulk_", suffix),
                ),
                scale = 1000.0,
                units = "g C m-2",
            )
        end for (source, suffix) in CORPSE_COMPONENTS if source in (
            "unprotected_labile",
            "unprotected_recalcitrant",
            "unprotected_dead_microbe",
            "protected_labile",
            "protected_recalcitrant",
            "protected_dead_microbe",
            "living_microbe",
        ) for layer in LAYERS if
        !(layer == "litter" && startswith(source, "protected"))
    )
    drivers = (
        (
            name = "Ts",
            source = :parameter,
            component = :corpse_soil,
            variables = (:soil_temperature,),
            scale = 1.0,
            units = "K",
        ),
        (
            name = "thetaLiq",
            source = :parameter,
            component = :corpse_soil,
            variables = (:liquid_saturation,),
            scale = 1.0,
            units = "1",
        ),
        (
            name = "thetaFrzn",
            source = :parameter,
            component = :corpse_soil,
            variables = (:frozen_saturation,),
            scale = 1.0,
            units = "1",
        ),
    )
    return (casa..., corpse..., drivers...)
end

function corpse_flux_index(name)
    index = findfirst(==(name), selected_corpse().CORPSE.PROGNOSTIC_VARIABLES)
    isnothing(index) && error("missing CORPSE flux $name")
    return index
end

function reduced_flux_variables()
    return (
        (
            name = "cgpp",
            source = :plant_flux,
            variables = (14,),
            scale = 1000.0 * DAY_SECONDS,
            daily_units = "g C m-2 day-1",
            annual_units = "g C m-2 year-1",
        ),
        (
            name = "cnpp",
            source = :plant_flux,
            variables = (15,),
            scale = 1000.0 * DAY_SECONDS,
            daily_units = "g C m-2 day-1",
            annual_units = "g C m-2 year-1",
        ),
        (
            name = "Soil_CO2",
            source = :corpse_flux,
            variables = (
                corpse_flux_index(:soil_rhiz_cumulative_co2),
                corpse_flux_index(:soil_bulk_cumulative_co2),
            ),
            scale = 1000.0 * DAY_SECONDS,
            daily_units = "g C m-2 day-1",
            annual_units = "g C m-2 year-1",
        ),
        (
            name = "LitterLayer_CO2",
            source = :corpse_litter_flux,
            variables = (
                length(selected_corpse().CORPSE.PROGNOSTIC_VARIABLES) + 1,
                corpse_flux_index(:soil_rhiz_cumulative_co2),
                corpse_flux_index(:soil_bulk_cumulative_co2),
            ),
            scale = 1000.0 * DAY_SECONDS,
            daily_units = "g C m-2 day-1",
            annual_units = "g C m-2 year-1",
        ),
    )
end

const REDUCED_STATE_VARIABLES = reduced_state_variables()
const REDUCED_FLUX_VARIABLES = reduced_flux_variables()
const REDUCED_VARIABLES =
    (REDUCED_STATE_VARIABLES..., REDUCED_FLUX_VARIABLES...)

function reduced_units(description, reducer)
    reducer == "annual_total" && return description.annual_units
    reducer == "fixed_daily_sample" &&
        description.source in
        (:plant_flux, :corpse_flux, :corpse_litter_flux) &&
        return description.daily_units
    return description.units
end

mutable struct ReducedCORPSEHistorical
    annual_mean::Dict{String, Matrix{Float64}}
    end_of_year::Dict{String, Matrix{Float64}}
    annual_total::Dict{String, Matrix{Float64}}
    samples::Dict{String, Matrix{Float64}}
    sample_position::Dict{Int, Int}
end

function ReducedCORPSEHistorical(point_count)
    state_names = getproperty.(REDUCED_STATE_VARIABLES, :name)
    flux_names = getproperty.(REDUCED_FLUX_VARIABLES, :name)
    return ReducedCORPSEHistorical(
        Dict(name => zeros(point_count, 114) for name in state_names),
        Dict(name => zeros(point_count, 114) for name in state_names),
        Dict(name => zeros(point_count, 114) for name in flux_names),
        Dict(
            name => zeros(point_count, length(REDUCED_SAMPLE_DAYS)) for
            name in (state_names..., flux_names...)
        ),
        Dict(day => index for (index, day) in enumerate(REDUCED_SAMPLE_DAYS)),
    )
end

function reduced_field(description, state, parameters)
    if description.source in (:state, :parameter)
        source = description.source == :state ? state : parameters
        component = getproperty(source, description.component)
        return map(description.variables) do variable
            vec(parent(getproperty(component, variable)))
        end
    end
    fluxes =
        description.source == :plant_flux ?
        parameters.casa_plant.carbon_fluxes :
        parameters.corpse_soil.carbon_fluxes
    if description.source == :corpse_litter_flux
        total, soil_rhiz, soil_bulk = map(description.variables) do index
            vec(parent(getindex.(fluxes, index)))
        end
        return [total .- soil_rhiz .- soil_bulk]
    end
    return map(description.variables) do index
        vec(parent(getindex.(fluxes, index)))
    end
end

function assign_reduced!(destination, description, values; accumulate)
    if accumulate
        destination .+= description.scale .* first(values)
        length(values) == 2 &&
            (destination .+= description.scale .* last(values))
    else
        destination .= description.scale .* first(values)
        length(values) == 2 &&
            (destination .+= description.scale .* last(values))
    end
    return destination
end

function (tracker::ReducedCORPSEHistorical)(stage, step, state, parameters, _)
    stage.name == :historical || return nothing
    year = cld(step, 365)
    day = mod1(step, 365)
    sample = get(tracker.sample_position, step, 0)
    for description in REDUCED_STATE_VARIABLES
        name = description.name
        values = reduced_field(description, state, parameters)
        assign_reduced!(
            view(tracker.annual_mean[name], :, year),
            description,
            values;
            accumulate = true,
        )
        if day == 365
            assign_reduced!(
                view(tracker.end_of_year[name], :, year),
                description,
                values;
                accumulate = false,
            )
        end
        if sample != 0
            assign_reduced!(
                view(tracker.samples[name], :, sample),
                description,
                values;
                accumulate = false,
            )
        end
    end
    for description in REDUCED_FLUX_VARIABLES
        name = description.name
        values = reduced_field(description, state, parameters)
        assign_reduced!(
            view(tracker.annual_total[name], :, year),
            description,
            values;
            accumulate = true,
        )
        if sample != 0
            assign_reduced!(
                view(tracker.samples[name], :, sample),
                description,
                values;
                accumulate = false,
            )
        end
    end
    return nothing
end

function write_reduced_historical(path, tracker, grid, eligible)
    mkpath(dirname(path))
    NCDatasets.NCDataset(path, "c") do output
        NCDatasets.defDim(output, "point", length(grid))
        NCDatasets.defDim(output, "year", 114)
        NCDatasets.defDim(output, "sample", length(REDUCED_SAMPLE_DAYS))
        NCDatasets.defVar(output, "cell_id", Int, ("point",))[:] =
            getproperty.(grid, :cell_id)
        NCDatasets.defVar(output, "eligible", Int8, ("point",))[:] =
            Int8.(eligible)
        NCDatasets.defVar(output, "year", Int, ("year",))[:] = 1901:2014
        NCDatasets.defVar(output, "sample_day", Int, ("sample",))[:] =
            REDUCED_SAMPLE_DAYS
        for (reducer, values) in (
            "annual_mean" => tracker.annual_mean,
            "end_of_year" => tracker.end_of_year,
            "annual_total" => tracker.annual_total,
            "fixed_daily_sample" => tracker.samples,
        )
            for (name, data) in values
                reducer == "annual_mean" && (data ./= 365)
                dimension = reducer == "fixed_daily_sample" ? "sample" : "year"
                variable = NCDatasets.defVar(
                    output,
                    "$(reducer)__$(name)",
                    Float64,
                    ("point", dimension);
                    deflatelevel = 1,
                )
                descriptions =
                    reducer == "annual_total" ? REDUCED_FLUX_VARIABLES :
                    reducer == "fixed_daily_sample" ? REDUCED_VARIABLES :
                    REDUCED_STATE_VARIABLES
                description =
                    only(filter(item -> item.name == name, descriptions))
                variable.attrib["units"] = reduced_units(description, reducer)
                variable[:, :] = data
            end
        end
    end
    return path
end

struct ForcingCallback{F, S, M, A}
    forcing::F
    stoichiometry::S
    model::M
    annual_npp::A
end

function (callback::ForcingCallback)(stage, index, time)
    update_forcing!(callback.forcing, stage, index, time)
    native_casa().apply_stoichiometry!(callback.stoichiometry, callback.model)
    prepare_annual_npp!(callback.annual_npp, callback.forcing, stage, index)
    return nothing
end

struct AfterStepCallback{S, A, R}
    stoichiometry::S
    annual_npp::A
    reduced::R
end

function (callback::AfterStepCallback)(stage, step, state, parameters, time)
    native_casa().update_stoichiometry!(callback.stoichiometry, state)
    accumulate_annual_npp!(callback.annual_npp, parameters)
    isnothing(callback.reduced) ||
        callback.reduced(stage, step, state, parameters, time)
    return nothing
end

function source_paths(source_root)
    grid_root = joinpath(source_root, "GRID_CN")
    return (;
        grid = joinpath(grid_root, "gridinfo_igbpz_CLM5_GSWP3.csv"),
        soil = joinpath(grid_root, "gridinfo_soil_CLM5_GSWP3.csv"),
        phenology = joinpath(grid_root, "modis_phenology_wtundra.txt"),
        parameters = joinpath(grid_root, "pftlookup_igbp_updated4_exud0.csv"),
    )
end

function build_setup(source_root, forcing_root; cell_ids = nothing)
    paths = source_paths(source_root)
    grid = native_casa().read_grid(paths.grid)
    length(grid) == 4263 || error("Pinned CORPSE grid must have 4,263 rows")
    if !isnothing(cell_ids)
        ids = Int.(cell_ids)
        ids == sort(unique(ids)) ||
            throw(ArgumentError("cell_ids must be sorted and unique"))
        by_id = Dict(point.cell_id => point for point in grid)
        all(haskey(by_id, id) for id in ids) ||
            throw(ArgumentError("cell_ids contain a point outside the grid"))
        grid = [by_id[id] for id in ids]
    end
    soils = native_casa().read_soils(paths.soil)
    domain = native_casa().gridded_domain(length(grid))
    buffers = selected_corpse().CORPSEBuffers(domain)
    build = selected_corpse().build_model(
        grid,
        soils,
        paths.parameters,
        buffers;
        domain,
    )
    forcing = StreamingCORPSEForcing(
        grid,
        soils,
        build.parameters,
        paths.phenology,
        forcing_root,
        buffers,
    )
    return (;
        grid,
        soils,
        model = build.model,
        parameters = build.parameters,
        buffers,
        forcing,
        paths,
    )
end

function stage_directory(stage)
    hasproperty(STAGE_DIRECTORIES, stage.name) ||
        error("unknown CORPSE stage $(stage.name)")
    return getproperty(STAGE_DIRECTORIES, stage.name)
end

function stage_provenance(setup, stage, reference_root)
    metadata = joinpath(
        reference_root,
        "stages",
        stage_directory(stage),
        "stage_metadata.toml",
    )
    return Dict(
        "model" => "ClimaLand integrated CASA-CORPSE LegacyDaily",
        "configuration" => "issue-50 CORPSE boundary/reduced reconstruction",
        "pft" => "IGBP 1:18 in pinned grid order",
        "parameter_file" => Dict(
            "source" => abspath(setup.paths.parameters),
            "sha256" => native_workflow().sha256sum(setup.paths.parameters),
        ),
        "forcing" => [
            Dict(
                "stage" => String(stage.name),
                "source" => "year-streamed GSWP3/CLM5 forcing; manifest $(abspath(metadata))",
                "sha256" => native_workflow().sha256sum(metadata),
            ),
        ],
    )
end

function csv_table(path)
    lines = readlines(path)
    header = strip.(split(first(lines), ','))
    columns = Dict(name => index for (index, name) in enumerate(header))
    rows = [strip.(split(line, ','; keepempty = true)) for line in lines[2:end]]
    return columns, rows
end

function corpse_column_name(layer, cohort, component)
    prefix = layer == "litter" ? "litlyr" : "soil_1"
    short = cohort == "rhizosphere" ? "rhiz" : "bulk"
    component == "unprotected_labile" &&
        return "$(prefix)_unprotect_$(short)(LABILE)"
    component == "unprotected_recalcitrant" &&
        return "$(prefix)_unprotect_$(short)(RECALCTRNT)"
    component == "unprotected_dead_microbe" &&
        return "$(prefix)_unprotect_$(short)(DEADMICRB)"
    component == "protected_labile" &&
        return "$(prefix)_protect_$(short)(LABILE)"
    component == "protected_recalcitrant" &&
        return "$(prefix)_protect_$(short)(RECALCTRNT)"
    component == "protected_dead_microbe" &&
        return "$(prefix)_protect_$(short)(DEADMICRB)"
    component == "living_microbe" && return "$(prefix)_livingMicrobeC_$(short)"
    component == "cumulative_respiration" && return "$(prefix)_CO2_$(short)"
    component == "original_carbon" && return "$(prefix)_originalC_$(short)"
    error("unsupported CORPSE boundary component $component")
end

function boundary_pairs(state, stage, grid, reference_root)
    eligible = findall(eligible_cell, grid)
    length(eligible) == count(eligible_cell, grid) ||
        error("CORPSE eligibility indexing failed")
    root = joinpath(reference_root, "stages", stage_directory(stage))
    casa_columns, casa_rows = csv_table(joinpath(root, "casa_final.csv"))
    corpse_columns, corpse_rows = csv_table(joinpath(root, "corpse_final.csv"))
    # Both the full grid and the 80-cell Representative scope reach here, so the
    # boundary is checked against the run's own grid rather than a fixed count.
    reference_grid = native_casa().read_grid(joinpath(root, "grid.csv"))
    isempty(reference_grid) && error("Fortran CASA grid is empty")
    length(reference_grid) == length(casa_rows) ||
        error("Fortran CASA boundary and grid differ")
    casa_by_id = Dict(
        point.cell_id => casa_rows[index] for
        (index, point) in enumerate(reference_grid)
    )
    corpse_id = corpse_columns["ijgcm"]
    corpse_by_id =
        Dict(parse(Int, row[corpse_id]) => row for row in corpse_rows)
    pairs = Dict{String, Any}()
    for (source, (component, variable)) in CASA_VARIABLES
        actual_all =
            vec(parent(getproperty(getproperty(state, component), variable)))
        expected_all = [
            parse(Float64, casa_by_id[point.cell_id][casa_columns[source]]) / 1000 for point in grid
        ]
        pairs["$component.$variable"] = (;
            actual = actual_all[eligible],
            expected = expected_all[eligible],
            grid = grid[eligible],
        )
    end
    for (source, suffix) in CORPSE_COMPONENTS,
        layer in LAYERS,
        cohort in COHORTS

        short = cohort == "rhizosphere" ? "rhiz" : "bulk"
        variable = Symbol(layer, '_', short, '_', suffix)
        actual_all = vec(parent(getproperty(state.corpse_soil, variable)))
        column = corpse_columns[corpse_column_name(layer, cohort, source)]
        expected_all = [
            parse(Float64, corpse_by_id[point.cell_id][column]) for
            point in grid
        ]
        pairs["corpse_soil.$variable"] = (;
            actual = actual_all[eligible],
            expected = expected_all[eligible],
            grid = grid[eligible],
        )
    end
    for (name, pair) in pairs
        all(isfinite, pair.actual) ||
            error("eligible Julia boundary contains nonfinite $name")
        all(isfinite, pair.expected) ||
            error("eligible Fortran boundary contains nonfinite $name")
    end
    return pairs
end

function boundary_summary(pairs)
    return Dict(
        name => Dict(
            "eligible_pairs" => length(pair.actual),
            "maximum_absolute_error" =>
                maximum(abs.(pair.actual .- pair.expected)),
            "finite" => true,
        ) for (name, pair) in pairs
    )
end

has_scientific_floor(::Any) = false
has_scientific_floor(values::AbstractVector) =
    any(has_scientific_floor, values)
has_scientific_floor(values::AbstractDict) = any(
    occursin("floor", lowercase(string(key))) || has_scientific_floor(value)
    for (key, value) in values
)

function calibration_policy(path)
    policy = TOML.parsefile(path)
    get(policy, "schema_version", nothing) == 1 &&
        get(policy, "calibration_id", nothing) ==
        "corpse-c-representative-fresh-fortran-v1" &&
        get(policy, "source", nothing) == "fresh_fortran_representative" &&
        get(policy, "model", nothing) == "CORPSE" &&
        get(policy, "scope", nothing) == "representative" &&
        get(policy, "scope_cell_count", nothing) == 80 &&
        get(policy, "eligible_cell_count", nothing) == 78 ||
        error("incompatible CORPSE Representative calibration")
    has_scientific_floor(policy) &&
        error("CORPSE calibration must not contain a scientific floor")
    gaps = Dict(
        Int(gap["cell_id"]) => Int(gap["pft"]) for
        gap in get(policy, "eligibility_gaps", Any[]) if
        get(gap, "model", nothing) == "CORPSE" &&
        get(gap, "reviewed", false) === true
    )
    gaps == REPRESENTATIVE_GAPS || error("calibration eligibility gaps differ")
    method = get(policy, "method", Dict{String, Any}())
    Set(keys(method)) == Set((
        "acceptance",
        "annual_flux_total_population_per_variable",
        "annual_population_per_variable",
        "boundary_population_per_variable",
        "coefficient_constraints",
        "error",
        "fixed_daily_population_per_variable",
        "flux_annual_total",
        "globally_inapplicable_pfts",
        "nonfinite",
        "numerical_padding",
        "outliers_per_variable",
        "population",
        "reference_magnitude",
        "representative_gaps",
        "safety_margin",
        "selection",
    )) || error("calibration method schema differs")
    method["acceptance"] ==
        "e_i <= atol + rtol*x_i for every eligible pair" &&
        method["coefficient_constraints"] ==
        "fit atol >= 0 and rtol >= 0 solely from observed errors and absolute Fortran reference magnitudes" &&
        method["error"] == "e_i = abs(Julia_i - Fortran_i)" &&
        method["nonfinite"] ==
        "hard failure in any eligible Julia or Fortran pair" &&
        method["numerical_padding"] ==
        "after the 5% fit, add 64*eps(Float64)*max(maximum(abs, Julia), maximum(abs, Fortran), floatmin(Float64)) to atol; add no rtol padding" &&
        method["reference_magnitude"] == "x_i = abs(Fortran_i)" &&
        method["safety_margin"] ==
        "multiply both fitted coefficients by 1.05 before adding numerical padding" &&
        method["selection"] ==
        "choose the smallest r >= 0 minimizing a(r) + r*mean(x)" ||
        error("calibration method differs")
    provenance = get(policy, "provenance", Dict{String, Any}())
    sources = (
        (
            "runner_source",
            "test/testbed_validation/native_corpse_c_reconstruction.jl",
            joinpath(@__DIR__, "native_corpse_c_reconstruction.jl"),
        ),
        (
            "calibration_source",
            "test/testbed_validation/generate_corpse_c_representative_calibration.jl",
            joinpath(
                @__DIR__,
                "generate_corpse_c_representative_calibration.jl",
            ),
        ),
        (
            "scope_manifest",
            "validation/scopes/representative.toml",
            joinpath(@__DIR__, "validation", "scopes", "representative.toml"),
        ),
    )
    for (name, id, source_path) in sources
        source = get(provenance, name, Dict{String, Any}())
        get(source, "id", nothing) == id &&
            get(source, "sha256", nothing) ==
            native_workflow().sha256sum(source_path) ||
            error("calibration $name provenance differs")
    end
    return policy
end

function calibrated_metrics(actual, expected, calibration)
    size(actual) == size(expected) ||
        error("calibrated comparison shapes differ")
    all(isfinite, actual) ||
        error("eligible Julia calibrated comparison contains a nonfinite value")
    all(isfinite, expected) || error(
        "eligible Fortran calibrated comparison contains a nonfinite value",
    )
    length(actual) == get(calibration, "finite_pair_count", nothing) ||
        error("calibration population differs from runtime comparison")
    units = get(calibration, "units", nothing)
    units isa String && !isempty(units) ||
        error("calibration record has no units")
    derived = get(calibration, "derived_policy", Dict{String, Any}())
    atol = get(derived, "atol", nothing)
    rtol = get(derived, "rtol", nothing)
    atol isa Real &&
        rtol isa Real &&
        isfinite(atol) &&
        isfinite(rtol) &&
        atol >= 0 &&
        rtol >= 0 &&
        get(derived, "validation_failed_pairs", nothing) == 0 ||
        error("invalid calibrated tolerance")
    errors = abs.(actual .- expected)
    failures = count(errors .> atol .+ rtol .* abs.(expected))
    return Dict(
        "values" => length(actual),
        "failure_count" => failures,
        "maximum_absolute_error" => maximum(errors),
        "atol" => Float64(atol),
        "rtol" => Float64(rtol),
        "all_match" => failures == 0,
    )
end

function calibrated_boundary_summary(pairs, calibration, stage)
    rules = get(
        get(calibration, "stage", Dict{String, Any}()),
        String(stage.name),
        nothing,
    )
    rules isa AbstractDict || error("calibration is missing $(stage.name)")
    Set(keys(rules)) == Set(keys(pairs)) ||
        error("calibrated boundary variables differ")
    all(get(rule, "units", nothing) == "kg C m-2" for rule in values(rules)) ||
        error("calibrated boundary units differ")
    records = Dict(
        name => calibrated_metrics(pair.actual, pair.expected, rules[name])
        for (name, pair) in pairs
    )
    all(record["all_match"] for record in values(records)) ||
        error("CORPSE $(stage.name) boundary exceeds calibrated tolerance")
    return records
end

function compare_reduced_historical(candidate_path, reference_path, calibration)
    return NCDatasets.NCDataset(candidate_path) do candidate
        NCDatasets.NCDataset(reference_path) do reference
            candidate_ids = Int.(candidate["cell_id"][:])
            candidate_ids == Int.(reference["cell_id"][:]) ||
                error("reduced historical cell order differs")
            length(candidate_ids) == 80 ||
                error("reduced comparison is not Representative-80")
            eligible = findall(Bool.(candidate["eligible"][:]))
            length(eligible) == 78 ||
                error("reduced comparison must contain 78 eligible cells")
            Bool.(candidate["eligible"][:]) ==
            Bool.(reference["eligible"][:]) ||
                error("reduced historical eligibility masks differ")
            Int.(candidate["year"][:]) ==
            Int.(reference["year"][:]) ==
            collect(1901:2014) ||
                error("reduced historical year coordinates differ")
            Int.(candidate["sample_day"][:]) ==
            Int.(reference["sample_day"][:]) ==
            REDUCED_SAMPLE_DAYS ||
                error("reduced historical sample coordinates differ")
            rules = get(calibration, "reducer", Dict{String, Any}())
            result = Dict{String, Any}()
            for (reducer, variables) in (
                "annual_mean" => REDUCED_STATE_VARIABLES,
                "end_of_year" => REDUCED_STATE_VARIABLES,
                "annual_total" => REDUCED_FLUX_VARIABLES,
                "fixed_daily_sample" => REDUCED_VARIABLES,
            )
                names = getproperty.(variables, :name)
                reducer_rules = get(rules, reducer, nothing)
                reducer_rules isa AbstractDict ||
                    error("calibration is missing $reducer")
                Set(keys(reducer_rules)) == Set(names) ||
                    error("$reducer calibrated variables differ")
                result[reducer] = Dict(
                    name => begin
                        variable = "$(reducer)__$(name)"
                        description = only(
                            filter(item -> item.name == name, variables),
                        )
                        get(reducer_rules[name], "units", nothing) ==
                        reduced_units(description, reducer) ||
                            error("$variable calibrated units differ")
                        calibrated_metrics(
                            Float64.(candidate[variable][eligible, :]),
                            Float64.(reference[variable][eligible, :]),
                            reducer_rules[name],
                        )
                    end for name in names
                )
            end
            all(
                record["all_match"] for records in values(result) for
                record in values(records)
            ) || error("CORPSE reduced history exceeds calibrated tolerance")
            return result
        end
    end
end

function verify_reduced_reference(calibration, reference_path)
    provenance = get(calibration, "provenance", Dict{String, Any}())
    reference =
        get(provenance, "fortran_reduced_historical", Dict{String, Any}())
    manifest = get(
        provenance,
        "fortran_reduced_historical_manifest",
        Dict{String, Any}(),
    )
    get(reference, "sha256", nothing) ==
    native_workflow().sha256sum(reference_path) ||
        error("Fortran reduced historical reference hash differs")
    manifest_path = reference_path * ".toml"
    isfile(manifest_path) ||
        error("Fortran reduced historical reference manifest is missing")
    get(manifest, "sha256", nothing) ==
    native_workflow().sha256sum(manifest_path) ||
        error("Fortran reduced historical reference manifest hash differs")
    return nothing
end

function verify_boundary_reference(calibration, reference_root)
    provenance = get(calibration, "provenance", Dict{String, Any}())
    verify(record, path, id) = begin
        get(record, "id", nothing) == id ||
            error("Fortran boundary reference identifier differs for $id")
        get(record, "sha256", nothing) ==
        native_workflow().sha256sum(path) ||
            error("Fortran boundary reference hash differs for $id")
    end
    verify(
        get(
            provenance,
            "fortran_reconstruction_report",
            Dict{String, Any}(),
        ),
        joinpath(reference_root, "reconstruction_report.toml"),
        "fortran/reconstruction_report.toml",
    )
    stage_provenance =
        get(provenance, "fortran_stage", Dict{String, Any}())
    for stage in canonical_stages()
        name = String(stage.name)
        records = get(stage_provenance, name, Dict{String, Any}())
        stage_root =
            joinpath(reference_root, "stages", stage_directory(stage))
        for (key, filename) in (
            "casa_boundary" => "casa_final.csv",
            "corpse_boundary" => "corpse_final.csv",
            "metadata" => "stage_metadata.toml",
        )
            id = "fortran/$(stage_directory(stage))/$filename"
            verify(
                get(records, key, Dict{String, Any}()),
                joinpath(stage_root, filename),
                id,
            )
        end
    end
    return nothing
end

function report_provenance(setup, reference_root; scope = nothing)
    repo_root = normpath(joinpath(@__DIR__, "..", ".."))
    record(path) = Dict(
        "path" => abspath(path),
        "sha256" => native_workflow().sha256sum(path),
    )
    sources = (
        @__FILE__,
        joinpath(@__DIR__, "selected_corpse_workflow.jl"),
        joinpath(@__DIR__, "native_casa_c_reconstruction.jl"),
        joinpath(@__DIR__, "native_workflow.jl"),
        joinpath(
            repo_root,
            "src",
            "standalone",
            "Soil",
            "Biogeochemistry",
            "corpse.jl",
        ),
        joinpath(repo_root, "src", "integrated", "casa_biogeochemistry.jl"),
    )
    provenance = Dict(
        "julia_threads" => Threads.nthreads(),
        "blas_threads" => LinearAlgebra.BLAS.get_num_threads(),
        "parameter_file" => record(setup.paths.parameters),
        "grid_file" => record(setup.paths.grid),
        "soil_file" => record(setup.paths.soil),
        "phenology_file" => record(setup.paths.phenology),
        "fortran_reconstruction_report" =>
            record(joinpath(reference_root, "reconstruction_report.toml")),
        "julia_source" => Dict(
            relpath(path, repo_root) => record(path) for path in sources
        ),
    )
    isnothing(scope) || (
        provenance["scope_manifest"] = Dict(
            "name" => scope.name,
            "path" => scope.path,
            "sha256" => scope.sha256,
        )
    )
    return provenance
end

"""
    run_gridded_case(source_root, forcing_root, reference_root, output_root; ...)

Run the four-stage CORPSE workflow with yearly forcing streaming. The default
boundary-only mode writes exactly one checkpoint per stage and an ephemeral
comparison report, but no raw historical records or diagnostics. Passing an
immutable Representative scope manifest selects its exact IDs and can enable
reduced annual, end-of-year, and fixed-daily products.
"""
function run_gridded_case(
    source_root,
    forcing_root,
    reference_root,
    output_root;
    boundary_only = true,
    compare_references = true,
    stages = canonical_stages(),
    scope_manifest = nothing,
    reduce_historical = false,
    calibration_manifest = nothing,
    reduced_reference = nothing,
)
    assert_single_threaded()
    boundary_only || throw(
        ArgumentError(
            "the issue-50 runner currently supports boundary_only=true",
        ),
    )
    expected_names = (:prespin, :spin, :spin_continuation, :historical)
    getproperty.(stages, :name) == expected_names ||
        throw(ArgumentError("CORPSE stages must be ordered $expected_names"))
    all(!stage.write_output for stage in stages) || throw(
        ArgumentError("boundary_only stages must disable historical output"),
    )
    scope =
        isnothing(scope_manifest) ? nothing :
        representative_scope(scope_manifest)
    calibration =
        isnothing(calibration_manifest) ? nothing :
        calibration_policy(calibration_manifest)
    isnothing(calibration) ||
        !isnothing(scope) ||
        error("calibrated comparison requires the Representative scope")
    isnothing(calibration) ||
        verify_boundary_reference(calibration, reference_root)
    setup = build_setup(
        source_root,
        forcing_root;
        cell_ids = isnothing(scope) ? nothing : scope.cell_ids,
    )
    eligible_count = count(eligible_cell, setup.grid)
    isnothing(scope) &&
        eligible_count != 2970 &&
        error("expected 2,970 eligible CORPSE cells, found $eligible_count")
    if !isnothing(scope)
        eligible_count == 78 ||
            error("Representative CORPSE must have 78 eligible cells")
        actual_gaps = Dict(
            point.cell_id => point.pft for
            point in setup.grid if !eligible_cell(point)
        )
        actual_gaps == scope.gaps ||
            error("Representative CORPSE gaps differ from reviewed gaps")
    end
    stoichiometry =
        native_casa().CarbonOnlyPlantStoichiometry(setup.grid, setup.parameters)
    annual_npp = StreamingAnnualNPP(setup.buffers)
    current_state = selected_corpse().gridded_initial_state(
        setup.model,
        setup.grid,
        setup.parameters,
    )
    forcing_callback =
        ForcingCallback(setup.forcing, stoichiometry, setup.model, annual_npp)
    reduced =
        reduce_historical ? ReducedCORPSEHistorical(length(setup.grid)) :
        nothing
    after_step_callback = AfterStepCallback(stoichiometry, annual_npp, reduced)
    stage_reports = Dict{String, Any}()
    checkpoints = String[]
    initial_totals = selected_corpse().corpse_carbon_totals(current_state)
    workflow_inputs = zero(initial_totals.active)
    workflow_respiration = zero(initial_totals.active)
    started = time()
    try
        for stage in stages
            restart_transform = if stage.name == :prespin
                (; maximum_residual = 0.0, tolerance = 2e-12, verified = true)
            else
                before_rebase =
                    selected_corpse().corpse_carbon_totals(current_state)
                selected_corpse().rebase_corpse_stage!(current_state)
                native_casa().restore_stoichiometry!(
                    stoichiometry,
                    current_state,
                )
                selected_corpse().rebase_conservation(
                    before_rebase,
                    selected_corpse().corpse_carbon_totals(current_state),
                )
            end
            restart_transform.verified ||
                error("CORPSE $(stage.name) restart transform is not conservative")
            stage_start_totals =
                selected_corpse().corpse_carbon_totals(current_state)
            stage_root = joinpath(output_root, "stages", String(stage.name))
            result = native_workflow().run_workflow(
                setup.model,
                current_state,
                [stage],
                stage_root;
                update_forcing! = forcing_callback,
                after_step! = after_step_callback,
                diagnostics = (),
                provenance = stage_provenance(setup, stage, reference_root),
            )
            manifest = TOML.parsefile(result.manifest)
            output_records = manifest["stage"]
            isfile(result.output) && rm(result.output)
            stage_end_totals =
                selected_corpse().corpse_carbon_totals(result.state)
            workflow_inputs .+=
                stage_end_totals.original .- stage_start_totals.original
            workflow_respiration .+=
                stage_end_totals.cumulative .- stage_start_totals.cumulative
            checkpoint = only(result.checkpoints)
            push!(checkpoints, checkpoint)
            checkpoint_state, _ =
                ClimaLand.read_checkpoint(checkpoint; model = setup.model)
            current_state = native_casa().state_as_initial_state(
                checkpoint_state,
                setup.model,
            )
            handoff = selected_corpse().carbon_handoff(
                stage_end_totals,
                selected_corpse().corpse_carbon_totals(current_state),
            )
            conservation = selected_corpse().corpse_conservation(current_state)
            handoff.verified ||
                error("CORPSE $(stage.name) checkpoint handoff is not conservative")
            conservation.verified ||
                error("CORPSE $(stage.name) state violates conservation")
            comparison =
                compare_references ?
                begin
                    pairs = boundary_pairs(
                        current_state,
                        stage,
                        setup.grid,
                        reference_root,
                    )
                    isnothing(calibration) ? boundary_summary(pairs) :
                    calibrated_boundary_summary(pairs, calibration, stage)
                end : Dict("status" => "not compared")
            stage_reports[String(stage.name)] = Dict(
                "checkpoint" => abspath(checkpoint),
                "checkpoint_sha256" =>
                    native_workflow().sha256sum(checkpoint),
                "output_records" => output_records[1]["output_records"],
                "comparison" => comparison,
                "restart_transform" => Dict(
                    "maximum_residual_kg_c_m2" =>
                        restart_transform.maximum_residual,
                    "tolerance_kg_c_m2" => restart_transform.tolerance,
                    "verified" => restart_transform.verified,
                ),
                "checkpoint_handoff" => Dict(
                    "maximum_residual_kg_c_m2" => handoff.maximum_residual,
                    "tolerance_kg_c_m2" => handoff.tolerance,
                    "verified" => handoff.verified,
                ),
                "conservation" => Dict(
                    "maximum_residual_kg_c_m2" =>
                        conservation.maximum_residual,
                    "tolerance_kg_c_m2" => conservation.tolerance,
                    "verified" => conservation.verified,
                ),
            )
        end
    finally
        native_casa().close_forcing!(setup.forcing.base)
    end
    final_totals = selected_corpse().corpse_carbon_totals(current_state)
    workflow_residual =
        initial_totals.active .+ workflow_inputs .- workflow_respiration .-
        final_totals.active
    workflow_tolerance = 2e-11
    workflow_maximum_residual = maximum(abs, workflow_residual)
    isfinite(workflow_maximum_residual) &&
        workflow_maximum_residual <= workflow_tolerance ||
        error("CORPSE full-workflow conservation tolerance exceeded")
    reduced_path = if isnothing(reduced)
        ""
    else
        write_reduced_historical(
            joinpath(output_root, "reduced_historical.nc"),
            reduced,
            setup.grid,
            eligible_cell.(setup.grid),
        )
    end
    reduced_comparison = if isnothing(calibration)
        Dict("status" => "not calibrated")
    else
        isempty(reduced_path) && error(
            "calibrated comparison requires reduced historical output",
        )
        isnothing(reduced_reference) && error(
            "calibrated comparison requires a reduced Fortran reference",
        )
        verify_reduced_reference(calibration, reduced_reference)
        compare_reduced_historical(reduced_path, reduced_reference, calibration)
    end
    gaps = if isnothing(scope)
        [
            Dict(
                "model" => "CORPSE",
                "cell_id" => point.cell_id,
                "pft" => point.pft,
                "reason" => "outside CORPSE model applicability",
                "reviewed" => false,
            ) for point in setup.grid if !eligible_cell(point)
        ]
    else
        scope.gap_entries
    end
    report = Dict(
        "schema_version" => 1,
        "model" => "CORPSE",
        "mode" =>
            isnothing(reduced) ? "boundary_only" : "representative_reduced",
        "scope" => isnothing(scope) ? "global" : scope.name,
        "grid_cells" => length(setup.grid),
        "eligible_cells" => eligible_count,
        "eligibility_gaps" => gaps,
        "ineligible_pfts" => collect(INELIGIBLE_PFTS),
        "comparison_variables" => sum(comparison_variable_count()),
        "historical_output" => false,
        "diagnostics" => false,
        "budget" => true,
        "full_workflow_conservation" => Dict(
            "maximum_residual_kg_c_m2" => workflow_maximum_residual,
            "tolerance_kg_c_m2" => workflow_tolerance,
            "verified" => true,
        ),
        "reduced_historical" =>
            isempty(reduced_path) ? Dict("enabled" => false) :
            Dict(
                "enabled" => true,
                "path" => abspath(reduced_path),
                "sha256" => native_workflow().sha256sum(reduced_path),
                "annual_years" => 114,
                "fixed_daily_samples" => length(REDUCED_SAMPLE_DAYS),
                "state_variables" => length(REDUCED_STATE_VARIABLES),
                "flux_variables" => length(REDUCED_FLUX_VARIABLES),
                "reducers" => [
                    "annual_mean",
                    "end_of_year",
                    "annual_total",
                    "fixed_daily_sample",
                ],
                "flux_annual_total_units" => "g C m-2 year-1",
                "comparison" => reduced_comparison,
            ),
        "elapsed_seconds" => time() - started,
        "provenance" => report_provenance(setup, reference_root; scope),
        "calibration" =>
            isnothing(calibration) ? Dict("enabled" => false) :
            Dict(
                "enabled" => true,
                "id" => calibration["calibration_id"],
                "sha256" =>
                    native_workflow().sha256sum(calibration_manifest),
                "reduced_reference_sha256" =>
                    native_workflow().sha256sum(reduced_reference),
            ),
        "stage" => stage_reports,
    )
    report_path = joinpath(output_root, "corpse_boundary_report.toml")
    mkpath(output_root)
    open(report_path, "w") do io
        TOML.print(io, report; sorted = true)
    end
    return (;
        checkpoints = Tuple(checkpoints),
        report = report_path,
        reduced_historical = reduced_path,
    )
end

function run_with_timeout(command; timeout_seconds = TIMEOUT_SECONDS)
    process = run(command; wait = false)
    deadline = time() + timeout_seconds
    while Base.process_running(process) && time() < deadline
        sleep(0.1)
    end
    if Base.process_running(process)
        Base.kill(process)
        wait(process)
        error(
            "CORPSE boundary run exceeded the $(timeout_seconds)-second hard timeout",
        )
    end
    wait(process)
    success(process) || error("CORPSE boundary worker failed")
    return nothing
end

function main(args = ARGS)
    worker = !isempty(args) && first(args) == "--worker"
    values = worker ? args[2:end] : args
    length(values) in (4, 5, 7) || error(
        "usage: native_corpse_c_reconstruction.jl SOURCE_ROOT FORCING_ROOT FORTRAN_ROOT OUTPUT_ROOT [SCOPE_MANIFEST [CALIBRATION_MANIFEST REDUCED_REFERENCE]]",
    )
    if !worker
        project = dirname(Base.active_project())
        command = addenv(
            `$(Base.julia_cmd()) --startup-file=no --project=$project $(@__FILE__) --worker $values`,
            "JULIA_NUM_THREADS" => "1",
            "OPENBLAS_NUM_THREADS" => "1",
        )
        run_with_timeout(command)
        return nothing
    end
    scope_manifest = length(values) in (5, 7) ? values[5] : nothing
    calibration_manifest = length(values) == 7 ? values[6] : nothing
    reduced_reference = length(values) == 7 ? values[7] : nothing
    result = run_gridded_case(
        values[1:4]...;
        scope_manifest,
        reduce_historical = !isnothing(scope_manifest),
        calibration_manifest,
        reduced_reference,
    )
    println(result.report)
    return result
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    TestbedNativeCORPSECReconstruction.main()
end
