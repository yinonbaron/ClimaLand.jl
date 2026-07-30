include(joinpath(@__DIR__, "generate_casa_c_full_grid_calibration.jl"))

const CASA_CN_BOUNDARY_VARIABLES = (
    ("casapool%clabile", ("casa_plant", "c_labile", "c")),
    ("casapool%cplant(LEAF)", ("casa_plant", "c_leaf", "c")),
    ("casapool%cplant(WOOD)", ("casa_plant", "c_wood", "c")),
    ("casapool%cplant(FROOT)", ("casa_plant", "c_fine_root", "c")),
    ("casapool%clitter(METB)", ("casa_soil", "c_litter_metabolic", "c")),
    ("casapool%clitter(STR)", ("casa_soil", "c_litter_structural", "c")),
    ("casapool%clitter(CWD)", ("casa_soil", "c_litter_cwd", "c")),
    ("casapool%csoil(MIC)", ("casa_soil", "c_soil_microbial", "c")),
    ("casapool%csoil(SLOW)", ("casa_soil", "c_soil_slow", "c")),
    ("casapool%csoil(PASS)", ("casa_soil", "c_soil_passive", "c")),
    ("casapool%nplant(LEAF)", ("casa_plant", "n_leaf", "n")),
    ("casapool%nplant(WOOD)", ("casa_plant", "n_wood", "n")),
    ("casapool%nplant(FROOT)", ("casa_plant", "n_fine_root", "n")),
    ("casapool%nlitter(METB)", ("casa_soil", "n_litter_metabolic", "n")),
    ("casapool%nlitter(STR)", ("casa_soil", "n_litter_structural", "n")),
    ("casapool%nlitter(CWD)", ("casa_soil", "n_litter_cwd", "n")),
    ("casapool%nsoil(MIC)", ("casa_soil", "n_soil_microbial", "n")),
    ("casapool%nsoil(SLOW)", ("casa_soil", "n_soil_slow", "n")),
    ("casapool%nsoil(PASS)", ("casa_soil", "n_soil_passive", "n")),
    ("casapool%nsoilmin", ("casa_soil", "n_mineral", "n")),
)

const CASA_CN_ANNUAL_VARIABLES = (
    ("cleaf", "casa_plant.c_leaf", "annual_mean", "c"),
    ("cwood", "casa_plant.c_wood", "annual_mean", "c"),
    ("cfroot", "casa_plant.c_fine_root", "annual_mean", "c"),
    ("clitmetb", "casa_soil.c_litter_metabolic", "annual_mean", "c"),
    ("clitstr", "casa_soil.c_litter_structural", "annual_mean", "c"),
    ("clitcwd", "casa_soil.c_litter_cwd", "annual_mean", "c"),
    ("csoilmic", "casa_soil.c_soil_microbial", "annual_mean", "c"),
    ("csoilslow", "casa_soil.c_soil_slow", "annual_mean", "c"),
    ("csoilpass", "casa_soil.c_soil_passive", "annual_mean", "c"),
    ("nleaf", "casa_plant.n_leaf", "annual_mean", "n"),
    ("nwood", "casa_plant.n_wood", "annual_mean", "n"),
    ("nfroot", "casa_plant.n_fine_root", "annual_mean", "n"),
    ("nlitmetb", "casa_soil.n_litter_metabolic", "annual_mean", "n"),
    ("nlitstr", "casa_soil.n_litter_structural", "annual_mean", "n"),
    ("nlitcwd", "casa_soil.n_litter_cwd", "annual_mean", "n"),
    ("nsoilmic", "casa_soil.n_soil_microbial", "annual_mean", "n"),
    ("nsoilslow", "casa_soil.n_soil_slow", "annual_mean", "n"),
    ("nsoilpass", "casa_soil.n_soil_passive", "annual_mean", "n"),
    ("nMineral", "casa_soil.n_mineral", "annual_mean", "n"),
    ("cgpp", "diagnostic.cgpp", "annual_total", "c"),
    ("cnpp", "diagnostic.cnpp", "annual_total", "c"),
    ("cresp", "diagnostic.cresp", "annual_total", "c"),
    ("cLitInptMet", "diagnostic.c_litter_metabolic_input", "annual_total", "c"),
    (
        "cLitInptStruc",
        "diagnostic.c_litter_structural_input",
        "annual_total",
        "c",
    ),
    ("cpassInpt", "diagnostic.c_passive_input", "annual_total", "c"),
    ("nMinDep", "diagnostic.n_deposition", "annual_total", "n"),
    ("nMinFix", "diagnostic.n_fixation", "annual_total", "n"),
    ("nMinUptake", "diagnostic.n_plant_uptake", "annual_total", "n"),
    ("nMinLeach", "diagnostic.n_leaching", "annual_total", "n"),
    ("nMinLoss", "diagnostic.n_gaseous_loss", "annual_total", "n"),
    (
        "nLitMineralization",
        "diagnostic.n_litter_mineralization",
        "annual_total",
        "n",
    ),
    (
        "nSoilMineralization",
        "diagnostic.n_soil_mineralization",
        "annual_total",
        "n",
    ),
    ("nSoilImmob", "diagnostic.n_soil_immobilization", "annual_total", "n"),
    (
        "nNetMineralization",
        "diagnostic.n_net_mineralization",
        "annual_total",
        "n",
    ),
    ("nLitInptMet", "diagnostic.n_litter_metabolic_input", "annual_total", "n"),
)

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) in (3, 4) || error(
        "usage: generate_casa_cn_full_grid_calibration.jl JULIA_OUTPUT FORTRAN_REFERENCE OUTPUT_TOML [EXECUTION_REVISION]",
    )
    println(
        generate(
            ARGS[1:3]...;
            execution_revision = length(ARGS) == 4 ? ARGS[4] : "HEAD",
            boundary_variables = CASA_CN_BOUNDARY_VARIABLES,
            calibration_id = "casa-cn-fresh-fortran-full-grid-v1",
            units = "kg C or N m^-2, as declared by variable",
            model_source = "native_casa_cn_reconstruction.jl",
            annual_variables = CASA_CN_ANNUAL_VARIABLES,
            daily_variables = CASA_CN_ANNUAL_VARIABLES,
            additional_sources = (
                "generate_casa_cn_full_grid_calibration.jl",
                "selected_casa_workflow.jl",
            ),
        ),
    )
end
