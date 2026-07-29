import Dates
import TOML

import NCDatasets

using ClimaLand

include(joinpath(@__DIR__, "native_workflow.jl"))
include(joinpath(@__DIR__, "native_casa_c_reconstruction.jl"))
include(joinpath(@__DIR__, "selected_cell_fixtures.jl"))
include(joinpath(@__DIR__, "selected_casa_workflow.jl"))

const Workflow = TestbedSelectedCASAWorkflow
const NativeCASA = TestbedNativeCASACReconstruction
const CASA_C_CALIBRATION_PATH =
    joinpath(@__DIR__, "validation", "casa_c_full_grid_calibration.toml")

const FORTRAN_BOUNDARY_VARIABLES = Dict(
    "casapool%clabile" => "casa_plant.c_labile",
    "casapool%cplant(LEAF)" => "casa_plant.c_leaf",
    "casapool%cplant(WOOD)" => "casa_plant.c_wood",
    "casapool%cplant(FROOT)" => "casa_plant.c_fine_root",
    "casapool%clitter(METB)" => "casa_soil.c_litter_metabolic",
    "casapool%clitter(STR)" => "casa_soil.c_litter_structural",
    "casapool%clitter(CWD)" => "casa_soil.c_litter_cwd",
    "casapool%csoil(MIC)" => "casa_soil.c_soil_microbial",
    "casapool%csoil(SLOW)" => "casa_soil.c_soil_slow",
    "casapool%csoil(PASS)" => "casa_soil.c_soil_passive",
    "casapool%nplant(LEAF)" => "casa_plant.n_leaf",
    "casapool%nplant(WOOD)" => "casa_plant.n_wood",
    "casapool%nplant(FROOT)" => "casa_plant.n_fine_root",
    "casapool%nlitter(METB)" => "casa_soil.n_litter_metabolic",
    "casapool%nlitter(STR)" => "casa_soil.n_litter_structural",
    "casapool%nlitter(CWD)" => "casa_soil.n_litter_cwd",
    "casapool%nsoil(MIC)" => "casa_soil.n_soil_microbial",
    "casapool%nsoil(SLOW)" => "casa_soil.n_soil_slow",
    "casapool%nsoil(PASS)" => "casa_soil.n_soil_passive",
    "casapool%nsoilmin" => "casa_soil.n_mineral",
)

const STAGE_DIRECTORIES = Dict(
    "prespin" => "01-prespin",
    "accelerated_spin" => "02-accelerated_spin",
    "normal_spin" => "03-normal_spin",
    "historical" => "04-historical",
)

function fixture_metadata(collection)
    cells = collection.cells
    return (
        ids = getproperty.(cells, :id),
        pfts = sort!(unique(getproperty.(cells, :pft))),
        regimes = sort!(unique(vcat(getproperty.(cells, :reasons)...))),
    )
end

function source_indices(fortran_root, cell_ids)
    grid = NativeCASA.parse_rows(
        joinpath(fortran_root, "stages", "01-prespin", "grid.csv"),
    )
    row_by_id = Dict(
        parse(Int, strip(row.ijcam)) => index for
        (index, row) in enumerate(grid)
    )
    return map(cell_ids) do cell_id
        haskey(row_by_id, cell_id) ||
            error("Cell $cell_id is absent from the Fortran grid")
        row_by_id[cell_id]
    end
end

function fortran_boundaries(root, configuration, indices)
    variables = if configuration == :carbon_only
        filter(
            pair -> startswith(first(pair), "casapool%c"),
            FORTRAN_BOUNDARY_VARIABLES,
        )
    else
        FORTRAN_BOUNDARY_VARIABLES
    end
    boundaries = Dict{String, Any}()
    for (stage, directory) in STAGE_DIRECTORIES
        path = joinpath(root, "stages", directory, "casa_final.csv")
        columns, rows = NativeCASA.read_boundary_csv(path)
        states = Dict{String, Any}()
        for (fortran_name, native_name) in variables
            column = columns[fortran_name]
            states[native_name] = [
                parse(Float64, rows[index][column]) / 1000 for index in indices
            ]
        end
        boundaries[stage] = states
    end
    return boundaries
end

function model_for_stage(setup, stage)
    stage == "prespin" && return setup.prespin.model
    stage == "accelerated_spin" && return setup.accelerated.model
    return setup.normal.model
end

function julia_boundaries(output_root, setup)
    boundaries = Dict{String, Any}()
    for stage in keys(STAGE_DIRECTORIES)
        checkpoint_root =
            joinpath(output_root, "stages", stage, "checkpoints", stage)
        checkpoint = only(
            filter(
                path -> endswith(path, ".hdf5"),
                readdir(checkpoint_root; join = true),
            ),
        )
        Y, _ = ClimaLand.read_checkpoint(
            checkpoint;
            model = model_for_stage(setup, stage),
        )
        boundaries[stage] = Workflow.state_snapshot(Y)
    end
    return boundaries
end

function julia_historical(output_root)
    years = (1901, 1957, 2014)
    quarter_starts = (1, 91, 182, 274)
    sample_days = sort!([
        (year - 1901) * 365 + start + offset for year in years for
        start in quarter_starts for offset in 0:6
    ],)
    path = joinpath(output_root, "stages", "historical", "historical.nc")
    return NCDatasets.NCDataset(path) do output
        historical = Dict{String, Any}("sample_days" => sample_days)
        for name in keys(output)
            occursin("__", name) || continue
            (startswith(name, "casa_") || startswith(name, "diagnostic__")) ||
                continue
            historical[replace(name, "__" => ".")] =
                vec(Array(output[name][:, sample_days]))
        end
        historical
    end
end

function measured_fortran_tolerance(fortran, julia)
    tolerance = Dict{String, Any}()
    for stage in keys(fortran)
        stage_tolerance = Dict{String, Any}()
        for name in keys(fortran[stage])
            maximum_error =
                maximum(abs.(fortran[stage][name] .- julia[stage][name]))
            stage_tolerance[name] = Dict(
                "atol" => 1.05 * maximum_error + 64eps(Float64),
                "rtol" => 0.0,
                "measured_maximum_absolute_error" => maximum_error,
                "method" => "1.05 times the measured fresh-Fortran/native-Julia maximum plus 64 eps",
            )
        end
        tolerance[stage] = stage_tolerance
    end
    return tolerance
end

function calibrated_fortran_tolerance(path = CASA_C_CALIBRATION_PATH)
    calibration = TOML.parsefile(path)
    calibration["source"] == "fresh_fortran_full_grid" &&
        calibration["cell_count"] == 4263 ||
        error("CASA-C calibration must use the full fresh-Fortran grid")
    return Dict(
        stage => Dict(
            name => Dict(
                "atol" => values["derived_policy"]["atol"],
                "rtol" => values["derived_policy"]["rtol"],
                "method" => calibration["calibration_id"],
            ) for (name, values) in stage_values
        ) for (stage, stage_values) in calibration["variable"]
    )
end

function generate_reference(
    configuration,
    collection,
    output_root,
    fortran_root,
    path,
)
    metadata = fixture_metadata(collection)
    setup = Workflow.load_setup(configuration; collection)
    fortran = fortran_boundaries(
        fortran_root,
        configuration,
        source_indices(fortran_root, metadata.ids),
    )
    julia = julia_boundaries(output_root, setup)
    historical = julia_historical(output_root)
    reference = isfile(path) ? TOML.parsefile(path) : Dict{String, Any}()
    reference["schema_version"] = 1
    reference["tier"] = collection.name
    reference["cell_ids"] = metadata.ids
    reference["historical_coverage"] = Dict(
        "pfts" => metadata.pfts,
        "forcing_regimes" => metadata.regimes,
        "dates" =>
            string.([
                Dates.Date(year, month, 1) + Dates.Day(offset) for
                year in (1901, 1957, 2014) for month in (1, 4, 7, 10) for
                offset in 0:6
            ],),
        "final_boundary" => "2014-12-31",
    )
    provenance = Dict(
        "fresh_fortran_boundary_sha256" => Dict(
            stage => TestbedNativeWorkflow.sha256sum(
                joinpath(fortran_root, "stages", directory, "casa_final.csv"),
            ) for (stage, directory) in STAGE_DIRECTORIES
        ),
        "native_julia_report_sha256" => TestbedNativeWorkflow.sha256sum(
            joinpath(output_root, "reconstruction_report.toml"),
        ),
        "accelerated_spin_parameter_adjustment" => Dict(
            "effective_passive_decay_rate_multiplier" => 10.0,
            "equivalence" => "archived accelerated-spin parameter file",
        ),
    )
    configuration == :carbon_only && (
        provenance["fresh_fortran_calibration_sha256"] =
            TestbedNativeWorkflow.sha256sum(CASA_C_CALIBRATION_PATH)
    )
    configurations = get!(reference, "configuration", Dict{String, Any}())
    configurations[String(configuration)] = Dict(
        "fresh_fortran" => Dict("boundary" => fortran),
        "native_julia" => Dict(
            "initialization" =>
                Workflow.state_snapshot(setup.initial_state),
            "boundary" => julia,
            "historical" => historical,
        ),
        "tolerance" => Dict(
            "fresh_fortran_boundary" =>
                configuration == :carbon_only ?
                calibrated_fortran_tolerance() :
                measured_fortran_tolerance(fortran, julia),
            "native_julia_boundary" => Dict(
                "atol" => 256eps(Float64),
                "rtol" => 256eps(Float64),
                "method" => "256 machine eps for pinned Float64 native checkpoints",
            ),
            "native_julia_initialization" => Dict(
                "atol" => 64eps(Float64),
                "rtol" => 64eps(Float64),
                "method" => "64 machine eps for pinned Float64 initialization",
            ),
            "native_julia_historical" => Dict(
                "atol" => 256eps(Float64),
                "rtol" => 256eps(Float64),
                "method" => "256 machine eps for pinned Float64 native history",
            ),
        ),
        "provenance" => provenance,
    )
    mkpath(dirname(path))
    open(path, "w") do io
        TOML.print(io, reference; sorted = true)
    end
    return path
end

function main(args = ARGS)
    length(args) == 5 || error(
        "usage: generate_selected_casa_workflow_reference.jl CONFIGURATION TIER OUTPUT_ROOT FORTRAN_ROOT REFERENCE_PATH",
    )
    configuration = Symbol(args[1])
    tier = Symbol(args[2])
    collection =
        tier in (:core, :ordinary) ?
        TestbedReferenceCellComparisons.core_cell_collection() :
        tier in (:smoke, :extended) ?
        TestbedReferenceCellComparisons.smoke_cell_collection() :
        error("TIER must be core/ordinary or smoke/extended")
    println(
        generate_reference(
            configuration,
            collection,
            args[3],
            args[4],
            args[5],
        ),
    )
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
