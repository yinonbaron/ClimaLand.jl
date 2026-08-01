if !isdefined(@__MODULE__, :TestbedReferenceHarness)
    include(joinpath(@__DIR__, "reference_harness.jl"))
end
if !isdefined(@__MODULE__, :GenerateSelectedCORPSEReference)
    include(joinpath(@__DIR__, "generate_selected_corpse_reference.jl"))
end

module SelectedMIMICSCValidation

import SHA

const HARNESS = getfield(parentmodule(@__MODULE__), :TestbedReferenceHarness)
const SELECTED =
    getfield(parentmodule(@__MODULE__), :GenerateSelectedCORPSEReference)
const FIXTURE_ROOT = joinpath(@__DIR__, "fixtures", "selected_cells")
const YEARS = 1901:2014
const POINTS = 80
const MIMICS_PARAMETER_SHA256 =
    "251435a0d914f72e8b498b2661f0067663418ccfcc3389f21cce7ceaff4d9dbf"
const STAGE_SPECS = (
    (
        name = "prespin",
        loops = 100,
        years = 1901:1901,
        initialization = 0,
        daily = 0,
        interval = 1,
    ),
    (
        name = "spin",
        loops = 499,
        years = 1901:1920,
        initialization = 3,
        daily = 0,
        interval = 9960,
    ),
    (
        name = "historical",
        loops = 1,
        years = 1901:2014,
        initialization = 3,
        daily = 1,
        interval = 1,
    ),
)

sha256sum(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

function prepare_inputs(selected_root; fixture_root = FIXTURE_ROOT)
    mkpath(selected_root)
    SELECTED.write_fortran_grid(
        joinpath(fixture_root, "grid_selected_cells.csv"),
        joinpath(selected_root, "grid_packed.csv"),
    )
    forcing_root = joinpath(selected_root, "forcing")
    mkpath(forcing_root)
    source = joinpath(fixture_root, "forcing_1901_2014.nc")
    for year in YEARS
        destination = joinpath(forcing_root, "met_$(year)_$(year).nc")
        isfile(destination) || SELECTED.write_fortran_meteorology(
            source,
            destination;
            selected_year = year,
        )
    end
    return forcing_root
end

function static_inputs(source_root, selected_root, fixture_root; verify = true)
    mimics_parameters = joinpath(
        source_root,
        "GRID_CN",
        "MIMICS_mod5_GSWP3_JAMES",
        "pftlookup_LIDET-MIM-REV_CN_desorb2xKO4_micCN_FI30.csv",
    )
    if verify
        sha256sum(mimics_parameters) == MIMICS_PARAMETER_SHA256 ||
            error("MIMICS-C KO4/FI30 parameter hash differs")
    end
    return [
        HARNESS.workflow_input(
            joinpath(selected_root, "grid_packed.csv"),
            "grid.csv",
        ),
        HARNESS.workflow_input(
            joinpath(source_root, "GRID_CN", "pftlookup_igbp_updated4.csv"),
            "casa_parameters.csv",
        ),
        HARNESS.workflow_input(
            joinpath(source_root, "GRID_CN", "modis_phenology_wtundra.txt"),
            "phenology.txt",
        ),
        HARNESS.workflow_input(
            joinpath(fixture_root, "soil_selected_cells.csv"),
            "soil.csv",
        ),
        HARNESS.workflow_input(mimics_parameters, "mimics_parameters.csv"),
        HARNESS.workflow_input(
            joinpath(source_root, "GRID_CN", "co2delta_control.txt"),
            "perturbation.txt",
        ),
    ]
end

function forcing_inputs(forcing_root, stage)
    return [
        HARNESS.workflow_input(
            joinpath(forcing_root, "met_$(year)_$(year).nc"),
            "met_$(year)_$(year).nc";
            mode = "symlink",
        ) for year in stage.years
    ]
end

function restart_inputs(stage)
    stage.name == "prespin" && return Dict{String, String}[]
    predecessor = stage.name == "spin" ? "prespin" : "spin"
    return [
        HARNESS.workflow_input(
            "stage:$predecessor/casa_final.csv",
            "casa_initial.csv",
        ),
        HARNESS.workflow_input(
            "stage:$predecessor/mimics_final.csv",
            "mimics_initial.csv",
        ),
    ]
end

function write_workflow(
    source_root,
    run_root;
    prepare = true,
    fixture_root = FIXTURE_ROOT,
    points = POINTS,
    source_commit,
)
    configuration = joinpath(run_root, "configuration")
    controls = joinpath(configuration, "controls")
    selected_root = joinpath(run_root, "selected_inputs")
    mkpath(controls)
    forcing_root = prepare ? prepare_inputs(selected_root; fixture_root) :
                   joinpath(selected_root, "forcing")
    common = static_inputs(
        source_root,
        selected_root,
        fixture_root;
        verify = prepare,
    )
    stages = Dict{String, Any}[]
    for stage in STAGE_SPECS
        control = HARNESS.write_smoke_control(
            controls;
            points,
            daily_output = stage.daily,
            soil_model = 2,
            loops = stage.loops,
            initialization = stage.initialization,
            years = (first(stage.years), last(stage.years)),
            cycle = 1,
            meteorology = "met_1901_1901.nc",
            netcdf_interval = stage.interval,
            casa_initial = "casa_initial.csv",
            mimics_parameters = "mimics_parameters.csv",
            mimics_initial = "mimics_initial.csv",
            mimics_final = "mimics_final.csv",
            mimics_netcdf = "mimics_pool_flux_yyyy.nc",
        )
        control_name = "$(stage.name).lst"
        mv(control, joinpath(controls, control_name); force = true)
        push!(
            stages,
            Dict(
                "name" => stage.name,
                "control" => joinpath("controls", control_name),
                "outputs" => [
                    "casa_final.csv",
                    "casa_flux_final.csv",
                    "mimics_final.csv",
                ],
                "input" => vcat(
                    common,
                    forcing_inputs(forcing_root, stage),
                    restart_inputs(stage),
                ),
            ),
        )
    end
    workflow_path = joinpath(configuration, "workflow.toml")
    HARNESS.write_toml_atomic(
        workflow_path,
        Dict(
            "schema_version" => 1,
            "name" => "selected-mimics-c-representative",
            "source_commit" => source_commit,
            "stage" => stages,
        ),
    )
    return (; workflow_path, forcing_root, selected_root)
end

run_fortran(executable, workflow_path, run_root) =
    HARNESS.run_stage_workflow(executable, workflow_path, run_root)

end
