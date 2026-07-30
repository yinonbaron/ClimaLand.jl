if !isdefined(@__MODULE__, :TestbedReferenceHarness)
    include(joinpath(@__DIR__, "reference_harness.jl"))
end
if !isdefined(@__MODULE__, :GenerateSelectedCORPSEReference)
    include(joinpath(@__DIR__, "generate_selected_corpse_reference.jl"))
end
if !isdefined(@__MODULE__, :TestbedNativeMIMICSCNReconstruction)
    include(joinpath(@__DIR__, "native_mimics_cn_reconstruction.jl"))
end

module SelectedMIMICSCNValidation

import TOML

const HARNESS = getfield(parentmodule(@__MODULE__), :TestbedReferenceHarness)
const SELECTED =
    getfield(parentmodule(@__MODULE__), :GenerateSelectedCORPSEReference)
const NATIVE =
    getfield(parentmodule(@__MODULE__), :TestbedNativeMIMICSCNReconstruction)
const FIXTURE_ROOT = joinpath(@__DIR__, "fixtures", "selected_cells")
const YEARS = 1901:2014
const POINTS = 37
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
        name = "spin_continuation",
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

function static_inputs(
    source_root,
    selected_root,
    fixture_root,
    prespin_parameters,
    stage,
)
    casa_parameters =
        stage.name == "prespin" ? prespin_parameters :
        joinpath(source_root, "GRID_CN", "pftlookup_igbp_updated4_exud0.csv")
    mimics_parameters = joinpath(
        source_root,
        "GRID_CN",
        "MIMICS_mod5_GSWP3_JAMES",
        "pftlookup_LIDET-MIM-REV_CN_desorb2xKO4_micCN_FI30.csv",
    )
    return [
        HARNESS.workflow_input(
            joinpath(selected_root, "grid_packed.csv"),
            "grid.csv",
        ),
        HARNESS.workflow_input(casa_parameters, "casa_parameters.csv"),
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

function restart_inputs(stage)
    stage.name == "prespin" && return Dict{String, String}[]
    predecessor = Dict(
        "spin" => "prespin",
        "spin_continuation" => "spin",
        "historical" => "spin_continuation",
    )[stage.name]
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

function forcing_inputs(forcing_root, stage)
    return [
        HARNESS.workflow_input(
            joinpath(forcing_root, "met_$(year)_$(year).nc"),
            "met_$(year)_$(year).nc";
            mode = "symlink",
        ) for year in stage.years
    ]
end

function prepare_inputs(source_root, selected_root; fixture_root = FIXTURE_ROOT)
    mkpath(selected_root)
    SELECTED.write_fortran_grid(
        joinpath(fixture_root, "grid_selected_cells.csv"),
        joinpath(selected_root, "grid_packed.csv"),
    )
    forcing_root = joinpath(selected_root, "forcing")
    mkpath(forcing_root)
    source_forcing = joinpath(fixture_root, "forcing_1901_2014.nc")
    for year in YEARS
        destination = joinpath(forcing_root, "met_$(year)_$(year).nc")
        isfile(destination) || SELECTED.write_fortran_meteorology(
            source_forcing,
            destination;
            selected_year = year,
        )
    end
    return forcing_root
end

function write_workflow(
    source_root,
    reference_template,
    run_root;
    prepare = true,
    fixture_root = FIXTURE_ROOT,
    points = POINTS,
)
    configuration = joinpath(run_root, "configuration")
    controls = joinpath(configuration, "controls")
    selected_root = joinpath(run_root, "selected_inputs")
    mkpath(controls)
    forcing_root =
        prepare ?
        prepare_inputs(source_root, selected_root; fixture_root) :
        joinpath(selected_root, "forcing")
    if prepare
        mimics_parameters = joinpath(
            source_root,
            "GRID_CN",
            "MIMICS_mod5_GSWP3_JAMES",
            NATIVE.MIMICS_PARAMETER_FILE,
        )
        NATIVE.native_workflow().sha256sum(mimics_parameters) ==
        NATIVE.MIMICS_PARAMETER_SHA256 || error(
            "Selected validation must use issue 43's unchanged KO4/FI30 parameter file",
        )
    end
    prespin_parameters = joinpath(
        reference_template,
        "candidates",
        "parameters",
        "pftlookup_igbp_updated4_borealNfix.candidate.csv",
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
            cycle = 2,
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
        inputs = vcat(
            static_inputs(
                source_root,
                selected_root,
                fixture_root,
                prespin_parameters,
                stage,
            ),
            forcing_inputs(forcing_root, stage),
            restart_inputs(stage),
        )
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
                "input" => inputs,
            ),
        )
    end
    workflow = Dict(
        "schema_version" => 1,
        "name" => "selected-mimics-cn-issue31-ko4-fi30",
        "source_commit" => TOML.parsefile(
            joinpath(reference_template, "configuration", "workflow.toml"),
        )["source_commit"],
        "stage" => stages,
    )
    workflow_path = joinpath(configuration, "workflow.toml")
    HARNESS.write_toml_atomic(workflow_path, workflow)
    return (; workflow_path, forcing_root, selected_root)
end

function run_fortran(executable, workflow_path, run_root)
    return HARNESS.run_stage_workflow(executable, workflow_path, run_root)
end

function run_julia(
    source_root,
    reference_template,
    run_root,
    output_root;
    fixture_root = FIXTURE_ROOT,
    points = POINTS,
)
    selected_root = joinpath(run_root, "selected_inputs")
    return NATIVE.run_gridded_case(
        source_root,
        joinpath(selected_root, "forcing"),
        run_root,
        output_root;
        expected_points = points,
        grid_path = joinpath(selected_root, "grid_packed.csv"),
        soil_path = joinpath(fixture_root, "soil_selected_cells.csv"),
        archive_grid_path =
            joinpath(fixture_root, "grid_selected_cells.csv"),
        prespin_parameters_path = joinpath(
            reference_template,
            "candidates",
            "parameters",
            "pftlookup_igbp_updated4_borealNfix.candidate.csv",
        ),
        compare_archive = false,
        reference_stage_initialization = false,
    )
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 5 || error(
        "usage: selected_mimics_cn_validation.jl SOURCE_ROOT REFERENCE_TEMPLATE FORTRAN_EXECUTABLE RUN_ROOT JULIA_OUTPUT_ROOT",
    )
    prepared =
        SelectedMIMICSCNValidation.write_workflow(ARGS[1], ARGS[2], ARGS[4])
    SelectedMIMICSCNValidation.run_fortran(
        ARGS[3],
        prepared.workflow_path,
        ARGS[4],
    )
    SelectedMIMICSCNValidation.run_julia(ARGS[1], ARGS[2], ARGS[4], ARGS[5])
end
