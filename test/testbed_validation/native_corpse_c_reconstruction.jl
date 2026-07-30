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

selected_corpse() =
    getfield(parentmodule(@__MODULE__), :TestbedSelectedCORPSEWorkflow)
native_casa() = selected_corpse().native_casa()
native_workflow() = selected_corpse().native_workflow()

eligible_cell(point) = !(point.pft in INELIGIBLE_PFTS)
comparison_variable_count() = (
    length(CASA_VARIABLES),
    length(CORPSE_COMPONENTS) * length(LAYERS) * length(COHORTS),
)

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

struct AfterStepCallback{S, A}
    stoichiometry::S
    annual_npp::A
end

function (callback::AfterStepCallback)(_, _, state, parameters, _)
    native_casa().update_stoichiometry!(callback.stoichiometry, state)
    accumulate_annual_npp!(callback.annual_npp, parameters)
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

function build_setup(source_root, forcing_root; cell_limit = nothing)
    paths = source_paths(source_root)
    grid = native_casa().read_grid(paths.grid)
    length(grid) == 4263 || error("Pinned CORPSE grid must have 4,263 rows")
    if !isnothing(cell_limit)
        eligible = filter(eligible_cell, grid)
        1 <= cell_limit <= length(eligible) ||
            throw(ArgumentError("cell_limit is outside the pinned grid"))
        grid = eligible[1:cell_limit]
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
        "configuration" => "issue-50 full-grid boundary-only reconstruction",
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
    length(casa_rows) == 4263 ||
        error("Fortran CASA boundary must contain 4,263 rows")
    corpse_id = corpse_columns["ijgcm"]
    corpse_by_id =
        Dict(parse(Int, row[corpse_id]) => row for row in corpse_rows)
    pairs = Dict{String, Any}()
    for (source, (component, variable)) in CASA_VARIABLES
        actual_all =
            vec(parent(getproperty(getproperty(state, component), variable)))
        expected_all = [
            parse(Float64, casa_rows[index][casa_columns[source]]) / 1000
            for index in eachindex(grid)
        ]
        pairs["$component.$variable"] = (;
            actual = actual_all[eligible],
            expected = expected_all[eligible],
            grid = grid[eligible],
            absolute_floor = 5e-10,
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
            absolute_floor = 5e-7,
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

function report_provenance(setup, reference_root)
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
    return Dict(
        "julia_threads" => Threads.nthreads(),
        "blas_threads" => LinearAlgebra.BLAS.get_num_threads(),
        "parameter_file" => record(setup.paths.parameters),
        "grid_file" => record(setup.paths.grid),
        "soil_file" => record(setup.paths.soil),
        "phenology_file" => record(setup.paths.phenology),
        "fortran_reconstruction_report" =>
            record(joinpath(reference_root, "reconstruction_report.toml")),
        "julia_source" =>
            Dict(relpath(path, repo_root) => record(path) for path in sources),
    )
end

"""
    run_gridded_case(source_root, forcing_root, reference_root, output_root; ...)

Run the four-stage CORPSE workflow with yearly forcing streaming. The default
boundary-only mode writes exactly one checkpoint per stage and an ephemeral
comparison report, but no historical records, diagnostics, or carbon budget.
`cell_limit` and noncanonical `stages` exist only for the public short-benchmark
path; calibration requires the canonical 4,263-cell run.
"""
function run_gridded_case(
    source_root,
    forcing_root,
    reference_root,
    output_root;
    boundary_only = true,
    compare_references = true,
    stages = canonical_stages(),
    cell_limit = nothing,
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
    setup = build_setup(source_root, forcing_root; cell_limit)
    eligible_count = count(eligible_cell, setup.grid)
    isnothing(cell_limit) &&
        eligible_count != 2970 &&
        error("expected 2,970 eligible CORPSE cells, found $eligible_count")
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
    after_step_callback = AfterStepCallback(stoichiometry, annual_npp)
    stage_reports = Dict{String, Any}()
    checkpoints = String[]
    started = time()
    try
        for stage in stages
            if stage.name != :prespin
                selected_corpse().rebase_corpse_stage!(current_state)
                native_casa().restore_stoichiometry!(
                    stoichiometry,
                    current_state,
                )
            end
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
            checkpoint = only(result.checkpoints)
            push!(checkpoints, checkpoint)
            checkpoint_state, _ =
                ClimaLand.read_checkpoint(checkpoint; model = setup.model)
            current_state = native_casa().state_as_initial_state(
                checkpoint_state,
                setup.model,
            )
            comparison =
                compare_references && isnothing(cell_limit) ?
                boundary_summary(
                    boundary_pairs(
                        current_state,
                        stage,
                        setup.grid,
                        reference_root,
                    ),
                ) : Dict("status" => "not compared")
            stage_reports[String(stage.name)] = Dict(
                "checkpoint" => abspath(checkpoint),
                "checkpoint_sha256" =>
                    native_workflow().sha256sum(checkpoint),
                "output_records" => output_records[1]["output_records"],
                "comparison" => comparison,
            )
        end
    finally
        native_casa().close_forcing!(setup.forcing.base)
    end
    report = Dict(
        "schema_version" => 1,
        "model" => "CORPSE",
        "mode" => "boundary_only",
        "grid_cells" => length(setup.grid),
        "eligible_cells" => eligible_count,
        "ineligible_pfts" => collect(INELIGIBLE_PFTS),
        "comparison_variables" => sum(comparison_variable_count()),
        "historical_output" => false,
        "diagnostics" => false,
        "budget" => false,
        "elapsed_seconds" => time() - started,
        "provenance" => report_provenance(setup, reference_root),
        "stage" => stage_reports,
    )
    report_path = joinpath(output_root, "corpse_boundary_report.toml")
    mkpath(output_root)
    open(report_path, "w") do io
        TOML.print(io, report; sorted = true)
    end
    return (; checkpoints = Tuple(checkpoints), report = report_path)
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
    length(values) in (4, 5) || error(
        "usage: native_corpse_c_reconstruction.jl SOURCE_ROOT FORCING_ROOT FORTRAN_ROOT OUTPUT_ROOT [CELL_LIMIT]",
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
    cell_limit = length(values) == 5 ? parse(Int, values[5]) : nothing
    stages = isnothing(cell_limit) ? canonical_stages() : benchmark_stages()
    result = run_gridded_case(
        values[1:4]...;
        stages,
        cell_limit,
        compare_references = isnothing(cell_limit),
    )
    println(result.report)
    return result
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    TestbedNativeCORPSECReconstruction.main()
end
