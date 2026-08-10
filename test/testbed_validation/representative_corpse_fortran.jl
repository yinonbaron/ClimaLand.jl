if !isdefined(@__MODULE__, :TestbedReferenceHarness)
    include(joinpath(@__DIR__, "reference_harness.jl"))
end
if !isdefined(@__MODULE__, :TestbedSelectedCellFixtures)
    include(joinpath(@__DIR__, "selected_cell_fixtures.jl"))
end
if !isdefined(@__MODULE__, :GenerateSelectedCORPSEReference)
    include(joinpath(@__DIR__, "generate_selected_corpse_reference.jl"))
end
if !isdefined(@__MODULE__, :GenerateRepresentativeCORPSEReference)
    include(joinpath(@__DIR__, "generate_representative_corpse_reference.jl"))
end

module TestbedRepresentativeCORPSEFortran

import TOML
import NCDatasets
import SHA

const Harness = getfield(parentmodule(@__MODULE__), :TestbedReferenceHarness)
const Fixtures =
    getfield(parentmodule(@__MODULE__), :TestbedSelectedCellFixtures)
const Selected =
    getfield(parentmodule(@__MODULE__), :GenerateSelectedCORPSEReference)
const Reduced =
    getfield(parentmodule(@__MODULE__), :GenerateRepresentativeCORPSEReference)
const SOURCE_COMMIT = "27ae1a0b673411642cd780ecad66d1c8f84e6a58"
const STAGES = (
    (
        name = "prespin",
        loops = 100,
        years = 1901:1901,
        initialization = 0,
        interval = 99,
        daily = 0,
        saved_years = (1, 99, 100),
    ),
    (
        name = "spin",
        loops = 499,
        years = 1901:1920,
        initialization = 3,
        interval = 9960,
        daily = 0,
        saved_years = (1, 9960, 9980),
    ),
    (
        name = "spin_continuation",
        loops = 499,
        years = 1901:1920,
        initialization = 3,
        interval = 9960,
        daily = 0,
        saved_years = (1, 9960, 9980),
    ),
    (
        # The reduced oracle reads 365 daily records for every historical year.
        name = "historical",
        loops = 1,
        years = 1901:2014,
        initialization = 2,
        interval = 1,
        daily = 1,
        saved_years = Tuple(1901:2014),
    ),
)
const BOUNDARY_END = Dict(
    "prespin" => (36500, "1901-12-31"),
    "spin" => (499 * 20 * 365, "1920-12-31"),
    "spin_continuation" => (499 * 20 * 365, "1920-12-31"),
)

# The Fortran appends `_daily` to its NetCDF names when daily output is on.
output_name(prefix, year, daily = 0) =
    "$(prefix)_pool_flux_$(lpad(year, 4, '0'))$(daily == 1 ? "_daily" : "").nc"

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

function fixture_inputs(fixture_manifest, scope_manifest)
    fixture = TOML.parsefile(fixture_manifest)
    scope = TOML.parsefile(scope_manifest)
    get(fixture, "schema_version", nothing) == 1 ||
        error("Representative forcing fixture schema is incompatible")
    get(scope, "schema_version", nothing) == 1 &&
        get(scope, "name", nothing) == "representative" ||
        error("CORPSE requires the Representative scope")
    cell_ids = Int.(get(scope, "cell_ids", Int[]))
    length(cell_ids) == 80 && cell_ids == sort(unique(cell_ids)) ||
        error("CORPSE requires 80 ordered Representative cells")
    selection = get(fixture, "selection", Dict{String, Any}())
    get(selection, "representative_cell_ids", nothing) == cell_ids ||
        error("Representative fixture cells differ from the scope")
    get(selection, "scope_manifest_sha256", nothing) ==
    sha256sum(scope_manifest) ||
        error("Representative fixture scope checksum differs")
    get(
        get(fixture, "source", Dict{String, Any}()),
        "repository_commit",
        nothing,
    ) == SOURCE_COMMIT || error("Representative fixture source commit differs")
    files = Fixtures.verified_fixture_paths(fixture_manifest, fixture)
    required = Set((
        "forcing",
        "grid",
        "soil",
        "casa_c_parameters",
        "corpse_parameters",
        "phenology",
        "perturbation",
    ))
    required <= Set(keys(files)) ||
        error("Representative fixture lacks CORPSE inputs")
    return (; fixture, files, cell_ids)
end

function stage_outputs(stage)
    outputs = ["casa_final.csv", "casa_flux_final.csv", "corpse_final.csv"]
    for prefix in ("casaclm", "corpse")
        append!(outputs, output_name.(prefix, stage.saved_years, stage.daily))
    end
    if stage.initialization == 0
        push!(outputs, "casaclm_pool_flux_yyyy.nc")
        push!(outputs, "corpse_pool_flux_yyyy.nc")
    end
    return outputs
end

function write_workflow(
    fixture_manifest,
    scope_manifest,
    run_root;
    meteorology_writer = Selected.write_fortran_meteorology,
    grid_writer = Selected.write_fortran_grid,
)
    inputs = fixture_inputs(fixture_manifest, scope_manifest)
    configuration = joinpath(run_root, "configuration")
    controls = joinpath(configuration, "controls")
    forcing = joinpath(configuration, "forcing")
    mkpath(controls)
    mkpath(forcing)
    grid = joinpath(configuration, "grid.csv")
    grid_writer(inputs.files["grid"], grid)
    for year in 1901:2014
        meteorology_writer(
            inputs.files["forcing"],
            joinpath(forcing, "met_$(year)_$(year).nc");
            selected_year = year,
        )
    end

    stage_specs = Dict{String, Any}[]
    for (index, stage) in enumerate(STAGES)
        control = Harness.write_smoke_control(
            controls;
            points = 80,
            daily_output = stage.daily,
            soil_model = 3,
            loops = stage.loops,
            initialization = stage.initialization,
            years = (first(stage.years), last(stage.years)),
            cycle = 1,
            meteorology = "met_1901_1901.nc",
            casa_initial = "casa_initial.csv",
            casa_final = "casa_final.csv",
            casa_flux_final = "casa_flux_final.csv",
            casa_netcdf = "casaclm_pool_flux_yyyy.nc",
            corpse_initial = "corpse_initial.csv",
            corpse_final = "corpse_final.csv",
            corpse_parameters = "corpse_parameters.nml",
            corpse_netcdf = "corpse_pool_flux_yyyy.nc",
            netcdf_interval = stage.interval,
        )
        control_path = joinpath(controls, "$(stage.name).lst")
        mv(control, control_path; force = true)
        records = [
            Harness.workflow_input(grid, "grid.csv"),
            Harness.workflow_input(inputs.files["soil"], "soil.csv"),
            Harness.workflow_input(
                inputs.files["casa_c_parameters"],
                "casa_parameters.csv",
            ),
            Harness.workflow_input(
                inputs.files["corpse_parameters"],
                "corpse_parameters.nml",
            ),
            Harness.workflow_input(inputs.files["phenology"], "phenology.txt"),
            Harness.workflow_input(
                inputs.files["perturbation"],
                "perturbation.txt",
            ),
        ]
        for year in stage.years
            name = "met_$(year)_$(year).nc"
            push!(
                records,
                Harness.workflow_input(
                    joinpath(forcing, name),
                    name;
                    mode = "symlink",
                ),
            )
        end
        if index > 1
            predecessor = STAGES[index - 1].name
            push!(
                records,
                Harness.workflow_input(
                    "stage:$predecessor/casa_final.csv",
                    "casa_initial.csv",
                ),
            )
            push!(
                records,
                Harness.workflow_input(
                    "stage:$predecessor/corpse_final.csv",
                    "corpse_initial.csv",
                ),
            )
        end
        push!(
            stage_specs,
            Dict(
                "name" => stage.name,
                "control" => relpath(control_path, configuration),
                "outputs" => stage_outputs(stage),
                "input" => records,
            ),
        )
    end
    path = joinpath(configuration, "workflow.toml")
    Harness.write_toml_atomic(
        path,
        Dict(
            "schema_version" => 1,
            "name" => "representative-80-corpse-complete-workflow",
            "source_commit" => SOURCE_COMMIT,
            "stage" => stage_specs,
        ),
    )
    return (; workflow_path = path, inputs)
end

function read_csv(path)
    lines = readlines(path)
    isempty(lines) && error("empty CORPSE boundary CSV: $path")
    header = strip.(split(first(lines), ','; keepempty = true))
    rows = map(lines[2:end]) do line
        values = strip.(split(line, ','; keepempty = true))
        isempty(last(values)) && pop!(values)
        length(values) == length(header) ||
            error("CSV column mismatch: $path")
        values
    end
    return (; header, rows)
end

function boundary_values(stage_root, cell_ids)
    values = Dict{String, Vector{Float64}}()
    for (prefix, filename, id_name) in (
        ("casa", "casa_final.csv", "npt"),
        ("corpse", "corpse_final.csv", "ijgcm"),
    )
        table = read_csv(joinpath(stage_root, filename))
        id_index = only(findall(==(id_name), table.header))
        rows = Dict(parse(Int, row[id_index]) => row for row in table.rows)
        ordered_ids = prefix == "casa" ? collect(eachindex(cell_ids)) : cell_ids
        ordered = [rows[id] for id in ordered_ids]
        for (column, name) in enumerate(table.header)
            column == id_index && continue
            parsed = tryparse.(Float64, getindex.(ordered, column))
            any(isnothing, parsed) && continue
            values["$prefix.$name"] =
                Float64[something(value) for value in parsed]
        end
    end
    return values
end

function scan_boundaries(run_root, cell_ids, observer)
    for (index, stage) in enumerate(STAGES[1:3])
        root =
            joinpath(run_root, "stages", "$(lpad(index, 2, '0'))-$(stage.name)")
        step, date = BOUNDARY_END[stage.name]
        observer(stage.name, step, date, boundary_values(root, cell_ids))
    end
    return nothing
end

function noleap_date(year, day)
    lengths = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
    month = 1
    while day > lengths[month]
        day -= lengths[month]
        month += 1
    end
    return "$(lpad(year, 4, '0'))-$(lpad(month, 2, '0'))-$(lpad(day, 2, '0'))"
end

function scan_historical(historical_root, cell_ids, observer)
    step = 0
    sources = merge(Reduced.STATE_SOURCES, Reduced.FLUX_SOURCES)
    for year in 1901:2014
        paths = Dict(
            prefix => Reduced.daily_path(historical_root, prefix, year) for
            prefix in ("casaclm", "corpse")
        )
        datasets = Dict(
            prefix => NCDatasets.NCDataset(path) for (prefix, path) in paths
        )
        try
            series = Dict(
                name => Reduced.selected_series(
                    datasets[prefix],
                    variable,
                    cell_ids,
                ) for (name, (prefix, variable)) in sources
            )
            for day in 1:365
                step += 1
                observer(
                    "historical",
                    step,
                    noleap_date(year, day),
                    Dict(
                        name => view(values, :, day) for
                        (name, values) in series
                    ),
                )
            end
        finally
            foreach(close, values(datasets))
        end
    end
    return nothing
end

function write_reconstruction_report(run_root)
    path = joinpath(run_root, "reconstruction_report.toml")
    Harness.write_toml_atomic(
        path,
        Dict(
            "schema_version" => 1,
            "status" => "complete",
            "points" => 80,
            "scope" => "representative",
            "source_commit" => SOURCE_COMMIT,
        ),
    )
    return path
end

function run(;
    executable,
    source_root,
    fixture_manifest,
    scope_manifest,
    output_root,
    cell_ids,
    observer,
    workflow_writer = write_workflow,
    workflow_runner = Harness.run_stage_workflow,
    boundary_scanner = scan_boundaries,
    historical_scanner = scan_historical,
)
    isfile(executable) || error("shared CORPSE executable is missing")
    isempty(readdir(mkpath(output_root))) ||
        error("CORPSE Fortran output directory must be empty")
    specification =
        workflow_writer(fixture_manifest, scope_manifest, output_root)
    specification.inputs.cell_ids == cell_ids ||
        error("CORPSE Fortran runner did not receive the exact scope order")
    results =
        workflow_runner(executable, specification.workflow_path, output_root)
    all(result.status in (:ran, :reused, :recovered) for result in results) ||
        error("Representative CORPSE Fortran workflow did not finish")
    boundary_scanner(output_root, cell_ids, observer)
    historical_root = joinpath(output_root, "stages", "04-historical")
    historical_scanner(historical_root, cell_ids, observer)
    write_reconstruction_report(output_root)
    return (;
        cell_ids = copy(cell_ids),
        boundary_root = output_root,
        historical_root,
    )
end

end
