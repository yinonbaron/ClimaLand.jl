if !isdefined(@__MODULE__, :TestbedNativeWorkflow)
    include(joinpath(@__DIR__, "native_workflow.jl"))
end
if !isdefined(@__MODULE__, :TestbedNativeCASACReconstruction)
    include(joinpath(@__DIR__, "native_casa_c_reconstruction.jl"))
end
if !isdefined(@__MODULE__, :TestbedGridTransitionParity)
    include(joinpath(@__DIR__, "grid_transition_parity.jl"))
end
if !isdefined(@__MODULE__, :TestbedNativeMIMICSCReconstruction)
    include(joinpath(@__DIR__, "native_mimics_c_reconstruction.jl"))
end
if !isdefined(@__MODULE__, :TestbedSelectedCASAWorkflow)
    include(joinpath(@__DIR__, "selected_casa_workflow.jl"))
end

module TestbedNativeMIMICSCNReconstruction

import ClimaCore
import ClimaLand
import NCDatasets
import TOML

const SoilMIMICS = ClimaLand.Soil.Biogeochemistry.MIMICS
const SoilCASA = ClimaLand.Soil.Biogeochemistry.CASA
const DAY_SECONDS = 86400.0
const MIMICS_PARAMETER_FILE = "pftlookup_LIDET-MIM-REV_CN_desorb2xKO4_micCN_FI30.csv"
const MIMICS_PARAMETER_SHA256 = "52d12f43e484caec0580198f72fc85f814ccc9c2e9799165859076640c84bb3b"
const CASA_RESTART_FIELDS =
    (:c_leaf, :c_wood, :c_fine_root, :n_leaf, :n_wood, :n_fine_root)
const CASA_SOIL_RESTART_FIELDS = (:c_litter_cwd, :n_litter_cwd, :n_mineral)
const MIMICS_RESTART_FIELDS = (
    :c_litter_metabolic,
    :c_litter_structural,
    :c_microbe_r,
    :c_microbe_k,
    :c_soil_available,
    :c_soil_chemical,
    :c_soil_physical,
    :n_litter_metabolic,
    :n_litter_structural,
    :n_microbe_r,
    :n_microbe_k,
    :n_soil_available,
    :n_soil_chemical,
    :n_soil_physical,
)

native_workflow() = getfield(parentmodule(@__MODULE__), :TestbedNativeWorkflow)
native_casa() =
    getfield(parentmodule(@__MODULE__), :TestbedNativeCASACReconstruction)
native_mimics() =
    getfield(parentmodule(@__MODULE__), :TestbedNativeMIMICSCReconstruction)
grid_parity() =
    getfield(parentmodule(@__MODULE__), :TestbedGridTransitionParity)
selected_casa() =
    getfield(parentmodule(@__MODULE__), :TestbedSelectedCASAWorkflow)
const CompensatedSum = native_workflow().CompensatedSum

# -----------------------------------------------------------------------------
# Stage and comparison definitions
# -----------------------------------------------------------------------------

const COMPLETE_STAGES = (
    native_workflow().NativeStage(:prespin, 365, 100; write_output = false),
    native_workflow().NativeStage(:spin, 20 * 365, 499; write_output = false),
    native_workflow().NativeStage(
        :spin_continuation,
        20 * 365,
        499;
        write_output = false,
    ),
    native_workflow().NativeStage(:historical, 114 * 365, 1),
)

const HISTORICAL_VARIABLES = (
    ("cleaf", :casa, "casa_plant__c_leaf", 1000.0),
    ("nleaf", :casa, "casa_plant__n_leaf", 1000.0),
    ("cwood", :casa, "casa_plant__c_wood", 1000.0),
    ("nwood", :casa, "casa_plant__n_wood", 1000.0),
    ("cfroot", :casa, "casa_plant__c_fine_root", 1000.0),
    ("nfroot", :casa, "casa_plant__n_fine_root", 1000.0),
    ("clitcwd", :casa, "mimics_soil__c_litter_cwd", 1000.0),
    ("nlitcwd", :casa, "mimics_soil__n_litter_cwd", 1000.0),
    ("cgpp", :casa, "diagnostic__cgpp", 1000DAY_SECONDS),
    ("cnpp", :casa, "diagnostic__cnpp", 1000DAY_SECONDS),
    ("nMinDep", :casa, "diagnostic__n_deposition", 1000DAY_SECONDS),
    ("nMinFix", :casa, "diagnostic__n_fixation", 1000DAY_SECONDS),
    ("nMinUptake", :casa, "diagnostic__n_plant_uptake", 1000DAY_SECONDS),
    ("nMinLeach", :casa, "diagnostic__n_leaching", 1000DAY_SECONDS),
    ("nMinLoss", :casa, "diagnostic__n_gaseous_loss", 1000DAY_SECONDS),
    (
        "nLitMineralization",
        :casa,
        "diagnostic__mimics_litter_mineralization",
        1000DAY_SECONDS,
    ),
    (
        "nSoilMineralization",
        :casa,
        "diagnostic__mimics_soil_mineralization",
        1000DAY_SECONDS,
    ),
    ("nSoilImmob", :casa, "diagnostic__mimics_immobilization", 1000DAY_SECONDS),
    (
        "nNetMineralization",
        :casa,
        "diagnostic__mimics_net_mineralization",
        1000DAY_SECONDS,
    ),
    ("cLITm", :mimics, "mimics_soil__c_litter_metabolic", 1000.0),
    ("cLITs", :mimics, "mimics_soil__c_litter_structural", 1000.0),
    ("cMICr", :mimics, "mimics_soil__c_microbe_r", 1000.0),
    ("cMICk", :mimics, "mimics_soil__c_microbe_k", 1000.0),
    ("cSOMa", :mimics, "mimics_soil__c_soil_available", 1000.0),
    ("cSOMc", :mimics, "mimics_soil__c_soil_chemical", 1000.0),
    ("cSOMp", :mimics, "mimics_soil__c_soil_physical", 1000.0),
    ("nLITm", :mimics, "mimics_soil__n_litter_metabolic", 1000.0),
    ("nLITs", :mimics, "mimics_soil__n_litter_structural", 1000.0),
    ("nMICr", :mimics, "mimics_soil__n_microbe_r", 1000.0),
    ("nMICk", :mimics, "mimics_soil__n_microbe_k", 1000.0),
    ("nSOMa", :mimics, "mimics_soil__n_soil_available", 1000.0),
    ("nSOMc", :mimics, "mimics_soil__n_soil_chemical", 1000.0),
    ("nSOMp", :mimics, "mimics_soil__n_soil_physical", 1000.0),
    ("DIN", :mimics, "diagnostic__mimics_working_din", 1000.0),
    ("cHresp", :mimics, "diagnostic__mimics_respiration", 1000DAY_SECONDS),
    (
        "cSOMpIn",
        :mimics,
        "diagnostic__mimics_physical_protection",
        1000DAY_SECONDS,
    ),
    (
        "cLitInput_metb",
        :mimics,
        "diagnostic__mimics_metabolic_input",
        1000DAY_SECONDS,
    ),
    (
        "cLitInput_struc",
        :mimics,
        "diagnostic__mimics_structural_input",
        1000DAY_SECONDS,
    ),
    ("cOverflow_r", :mimics, "diagnostic__mimics_overflow_r", 1000DAY_SECONDS),
    ("cOverflow_k", :mimics, "diagnostic__mimics_overflow_k", 1000DAY_SECONDS),
    (
        "nLitInput_metb",
        :mimics,
        "diagnostic__mimics_n_metabolic_input",
        1000DAY_SECONDS,
    ),
    (
        "nLitInput_struc",
        :mimics,
        "diagnostic__mimics_n_structural_input",
        1000DAY_SECONDS,
    ),
)

const BOUNDARY_VARIABLES = (
    ("casapool%clabile", :casa, :casa_plant, :c_labile),
    ("casapool%cplant(LEAF)", :casa, :casa_plant, :c_leaf),
    ("casapool%cplant(WOOD)", :casa, :casa_plant, :c_wood),
    ("casapool%cplant(FROOT)", :casa, :casa_plant, :c_fine_root),
    ("casapool%nplant(LEAF)", :casa, :casa_plant, :n_leaf),
    ("casapool%nplant(WOOD)", :casa, :casa_plant, :n_wood),
    ("casapool%nplant(FROOT)", :casa, :casa_plant, :n_fine_root),
    ("casapool%clitter(CWD)", :casa, :mimics_soil, :c_litter_cwd),
    ("casapool%nlitter(CWD)", :casa, :mimics_soil, :n_litter_cwd),
    ("casapool%nsoilmin", :casa, :mimics_soil, :n_mineral),
    ("mimicspool%LITm", :mimics, :mimics_soil, :c_litter_metabolic),
    ("mimicspool%LITs", :mimics, :mimics_soil, :c_litter_structural),
    ("mimicspool%MICr", :mimics, :mimics_soil, :c_microbe_r),
    ("mimicspool%MICk", :mimics, :mimics_soil, :c_microbe_k),
    ("mimicspool%SOMa", :mimics, :mimics_soil, :c_soil_available),
    ("mimicspool%SOMc", :mimics, :mimics_soil, :c_soil_chemical),
    ("mimicspool%SOMp", :mimics, :mimics_soil, :c_soil_physical),
    ("mimicspool%LITmN", :mimics, :mimics_soil, :n_litter_metabolic),
    ("mimicspool%LITsN", :mimics, :mimics_soil, :n_litter_structural),
    ("mimicspool%MICrN", :mimics, :mimics_soil, :n_microbe_r),
    ("mimicspool%MICkN", :mimics, :mimics_soil, :n_microbe_k),
    ("mimicspool%SOMaN", :mimics, :mimics_soil, :n_soil_available),
    ("mimicspool%SOMcN", :mimics, :mimics_soil, :n_soil_chemical),
    ("mimicspool%SOMpN", :mimics, :mimics_soil, :n_soil_physical),
)

# -----------------------------------------------------------------------------
# Diagnostics and model construction
# -----------------------------------------------------------------------------

function mimics_cn_diagnostics(soil_parameters = nothing)
    flux(name, long_name, compute; units = "kg m-2 s-1") =
        (; name, long_name, units, compute)
    plant_carbon(index) = (_, p) -> getindex.(p.casa_plant.carbon_fluxes, index)
    nitrogen(index) = (_, p) -> getindex.(p.mimics_soil.nitrogen_fluxes, index)
    combined(index) = (_, p) -> getindex.(p.mimics_soil.combined_fluxes, index)
    structural_carbon =
        isnothing(soil_parameters) ? ((_, p) -> p.litter_structural_input) :
        (
            (Y, p) ->
                p.litter_structural_input .+
                SoilMIMICS.cwd_to_structural_flux.(
                    soil_parameters,
                    Y.mimics_soil.c_litter_cwd,
                    p.mimics_soil.soil_temperature,
                    p.mimics_soil.liquid_saturation,
                )
        )
    structural_nitrogen =
        isnothing(soil_parameters) ?
        ((_, p) -> p.nitrogen_litter_structural_input) :
        (
            (Y, p) ->
                p.nitrogen_litter_structural_input .+
                cwd_nitrogen_loss_flux.(
                    soil_parameters,
                    Y.mimics_soil.n_litter_cwd,
                    p.mimics_soil.soil_temperature,
                    p.mimics_soil.liquid_saturation,
                )
        )
    return (
        flux("diagnostic__cgpp", "gross primary production", plant_carbon(14)),
        flux("diagnostic__cnpp", "net primary production", plant_carbon(15)),
        flux(
            "diagnostic__mimics_respiration",
            "MIMICS heterotrophic respiration",
            (_, p) -> getindex.(p.mimics_soil.carbon_fluxes, 9),
        ),
        flux(
            "diagnostic__mimics_metabolic_input",
            "MIMICS metabolic litter carbon input",
            (_, p) -> p.litter_metabolic_input,
        ),
        flux(
            "diagnostic__mimics_structural_input",
            "MIMICS structural litter carbon input",
            structural_carbon,
        ),
        flux(
            "diagnostic__mimics_n_metabolic_input",
            "MIMICS metabolic litter nitrogen input",
            (_, p) -> p.nitrogen_litter_metabolic_input,
        ),
        flux(
            "diagnostic__mimics_n_structural_input",
            "MIMICS structural litter nitrogen input",
            structural_nitrogen,
        ),
        flux(
            "diagnostic__n_deposition",
            "mineral nitrogen deposition",
            (_, p) -> p.mimics_soil.nitrogen_deposition,
        ),
        flux(
            "diagnostic__n_fixation",
            "mineral nitrogen fixation",
            (_, p) -> p.mimics_soil.nitrogen_fixation,
        ),
        flux(
            "diagnostic__n_plant_uptake",
            "plant mineral nitrogen uptake",
            (_, p) -> p.nitrogen_plant_uptake,
        ),
        flux(
            "diagnostic__n_gaseous_loss",
            "gaseous mineral nitrogen loss",
            nitrogen(10),
        ),
        flux(
            "diagnostic__n_leaching",
            "mineral nitrogen leaching",
            nitrogen(11),
        ),
        flux(
            "diagnostic__mimics_litter_mineralization",
            "MIMICS litter nitrogen mineralization",
            nitrogen(12),
        ),
        flux(
            "diagnostic__mimics_soil_mineralization",
            "MIMICS soil nitrogen mineralization",
            nitrogen(13),
        ),
        flux(
            "diagnostic__mimics_immobilization",
            "MIMICS nitrogen immobilization",
            nitrogen(14),
        ),
        flux(
            "diagnostic__mimics_net_mineralization",
            "MIMICS net nitrogen mineralization",
            (_, p) ->
                getindex.(p.mimics_soil.nitrogen_fluxes, 12) .+
                getindex.(p.mimics_soil.nitrogen_fluxes, 13) .+
                getindex.(p.mimics_soil.nitrogen_fluxes, 14),
        ),
        flux(
            "diagnostic__mimics_overflow_r",
            "MIMICS r-strategist overflow respiration",
            combined(25),
        ),
        flux(
            "diagnostic__mimics_overflow_k",
            "MIMICS K-strategist overflow respiration",
            combined(26),
        ),
        flux(
            "diagnostic__mimics_working_din",
            "MIMICS end-of-map working dissolved inorganic nitrogen",
            combined(27);
            units = "kg N m-2",
        ),
        flux(
            "diagnostic__mimics_physical_protection",
            "MIMICS physical protection input",
            combined(28),
        ),
        flux(
            "diagnostic__mimics_microbial_assimilation",
            "MIMICS microbial carbon assimilation",
            combined(29),
        ),
    )
end

@inline function cwd_nitrogen_loss_flux(
    parameters,
    litter_cwd_nitrogen,
    soil_temperature,
    liquid_saturation,
)
    return parameters.cwd_base_rate *
           parameters.cwd_litter_optimum *
           SoilCASA.temperature_factor(
               parameters.cwd_q10,
               soil_temperature,
               parameters.freezing_temperature,
           ) *
           SoilCASA.moisture_factor(liquid_saturation, false) *
           litter_cwd_nitrogen
end

function build_gridded_model(
    grid,
    soils,
    plant_parameter_path,
    mimics_parameter_path,
    buffers,
    nitrogen_deposition;
    domain = native_casa().gridded_domain(length(grid)),
    boreal_fixation = false,
)
    plant_build = selected_casa().build_cn_model(
        grid,
        soils,
        plant_parameter_path,
        buffers,
        nitrogen_deposition;
        domain,
        boreal_fixation,
    )
    carbon = grid_parity().read_mimics_parameters(mimics_parameter_path)
    nitrogen =
        grid_parity().read_mimics_nitrogen_parameters(mimics_parameter_path)
    soil_points = map(grid) do point
        native_mimics().mimics_soil_parameters(
            carbon,
            plant_build.parameters[point.pft],
            soils[point.cell_id],
        )
    end
    fixation = plant_build.model.casa_soil.nitrogen_drivers.fixation(0.0)
    soil = SoilMIMICS.MIMICSSoilModel{Float64}(;
        configuration = SoilMIMICS.CarbonNitrogen(),
        parameters = native_casa().point_field(domain, soil_points),
        nitrogen_parameters = nitrogen,
        drivers = SoilMIMICS.PrescribedDrivers(
            _ -> buffers.soil_temperature,
            _ -> buffers.liquid_saturation,
            _ -> buffers.frozen_saturation,
            _ -> zero(buffers.gpp),
            _ -> zero(buffers.gpp),
            _ -> zero(buffers.gpp),
            _ -> buffers.litter_quality,
            _ -> buffers.annual_npp,
        ),
        nitrogen_drivers = SoilMIMICS.NitrogenPrescribedDrivers(
            _ -> zero(buffers.gpp),
            _ -> zero(buffers.gpp),
            _ -> zero(buffers.gpp),
            _ -> nitrogen_deposition,
            _ -> fixation,
            _ -> zero(buffers.gpp),
        ),
        domain,
    )
    model = ClimaLand.CASAPlantSoilModel{Float64}(
        plant_build.model.casa_plant,
        soil,
        plant_build.model.coupling,
    )
    return (; model, parameters = plant_build.parameters, carbon, nitrogen)
end

function gridded_initial_state(model, grid, parameter_path, nitrogen)
    point_states = map(grid) do point
        native_workflow().fortran_initial_state(
            parameter_path,
            point.pft;
            soil_model = :mimics,
            nutrients = :carbon_nitrogen,
            microbial_carbon_nitrogen = nitrogen.microbial_carbon_nitrogen_ratio,
        )
    end
    components = ClimaLand.land_components(model)
    return NamedTuple{components}(
        map(components) do component_name
            component = getproperty(model, component_name)
            variables = ClimaLand.prognostic_vars(component)
            NamedTuple{variables}(
                map(variables) do variable
                    native_casa().scalar_field(
                        component.domain,
                        [
                            getproperty(
                                getproperty(state, component_name),
                                variable,
                            ) for state in point_states
                        ],
                    )
                end,
            )
        end,
    )
end

function quantize_restart_fields!(component, variables, digits, scale)
    for variable in variables
        values = parent(getproperty(component, variable))
        for index in eachindex(values)
            serialized = scale * values[index]
            values[index] = round(serialized; digits) / scale
        end
    end
    return nothing
end

"""
    quantize_fortran_restart!(state)

Apply the decimal precision of the legacy CASA and MIMICS-CN restart CSVs to
an SI-unit state. CASA-carried pools use `f18.6` in grams; MIMICS organic pools
use `f18.10` in their native kg m⁻² representation. CASA resets its labile
carbon pool after reading the restart.
"""
function quantize_fortran_restart!(state)
    quantize_restart_fields!(state.casa_plant, CASA_RESTART_FIELDS, 6, 1000)
    fill!(parent(state.casa_plant.c_labile), 0)
    quantize_restart_fields!(
        state.mimics_soil,
        CASA_SOIL_RESTART_FIELDS,
        6,
        1000,
    )
    quantize_restart_fields!(state.mimics_soil, MIMICS_RESTART_FIELDS, 10, 1)
    return state
end

"""
    load_fortran_restart!(state, casa_path, mimics_path)

Initialize every prognostic CASA–MIMICS-CN pool from a paired legacy restart.
CASA values are stored in grams and converted to SI kilograms; MIMICS organic
pools are already stored in kg m⁻². As in `casa_init`, labile carbon is reset
after the CASA restart is read.

This is a diagnostic helper for isolating one-stage implementation error from
long-chain trajectory error. Acceptance runs keep Julia's own checkpoint chain.
"""
function load_fortran_restart!(state, casa_path, mimics_path)
    casa_columns, casa_rows = native_mimics().read_boundary_csv(casa_path)
    mimics_columns, mimics_rows = native_mimics().read_boundary_csv(mimics_path)
    length(casa_rows) == length(mimics_rows) ||
        error("CASA and MIMICS restart row counts differ")
    for (reference_name, source, component, variable) in BOUNDARY_VARIABLES
        columns, rows =
            source == :casa ? (casa_columns, casa_rows) :
            (mimics_columns, mimics_rows)
        haskey(columns, reference_name) ||
            error("Restart is missing $reference_name")
        destination =
            vec(parent(getproperty(getproperty(state, component), variable)))
        length(destination) == length(rows) ||
            error("Restart row count does not match native state")
        for index in eachindex(destination)
            value = parse(Float64, rows[index][columns[reference_name]])
            destination[index] = source == :casa ? value / 1000 : value
        end
    end
    fill!(parent(state.casa_plant.c_labile), 0)
    return state
end

function use_initial_plant_stoichiometry!(
    model,
    grid,
    parameters,
    initial_state,
)
    field = model.casa_plant.parameters.leaf_phosphorus_to_nitrogen
    values = vec(parent(field))
    fixed = copy(values)
    leaf_nitrogen = vec(parent(initial_state.casa_plant.n_leaf))
    for (index, point) in enumerate(grid)
        parameter = parameters[point.pft]
        parameter.inactive && continue
        values[index] = parameter.initial_leaf_phosphorus / leaf_nitrogen[index]
    end
    return fixed
end

function restore_plant_stoichiometry!(model, fixed)
    field = model.casa_plant.parameters.leaf_phosphorus_to_nitrogen
    vec(parent(field)) .= fixed
    return nothing
end

# -----------------------------------------------------------------------------
# Reference comparisons
# -----------------------------------------------------------------------------

function compare_boundary_csv(Y, casa_path, mimics_path; atol, rtol)
    casa_columns, casa_data = native_mimics().read_boundary_csv(casa_path)
    mimics_columns, mimics_data = native_mimics().read_boundary_csv(mimics_path)
    length(casa_data) == length(mimics_data) ||
        error("CASA and MIMICS restart row counts differ")
    variables = Dict{String, Any}()
    for (reference_name, source, component, variable) in BOUNDARY_VARIABLES
        columns, rows =
            source == :casa ? (casa_columns, casa_data) :
            (mimics_columns, mimics_data)
        haskey(columns, reference_name) ||
            error("Boundary is missing $reference_name")
        actual =
            1000 .*
            vec(Array(parent(getproperty(getproperty(Y, component), variable))))
        reference_scale =
            source == :casa ? 1.0 :
            native_mimics().boundary_reference_scale(:mimics)
        expected =
            reference_scale .*
            [parse(Float64, row[columns[reference_name]]) for row in rows]
        variables[reference_name] =
            native_casa().error_metrics(actual, expected; atol, rtol)
    end
    mineral = vec(Array(parent(Y.mimics_soil.n_mineral)))
    return Dict(
        "casa_reference" => abspath(casa_path),
        "mimics_reference" => abspath(mimics_path),
        "points" => length(casa_data),
        "variable" => variables,
        "working_din" => Dict(
            "reference_status" => "not written to Fortran restart CSV",
            "available_fraction" => "applied inside the ordered MIMICS map",
            "ecosystem_mineral_nitrogen_minimum_kg_n_m2" =>
                minimum(mineral),
            "ecosystem_mineral_nitrogen_maximum_kg_n_m2" =>
                maximum(mineral),
        ),
        "all_match" => all(metric["all_match"] for metric in values(variables)),
    )
end

function compare_reference_files(
    native_output,
    casa_path,
    mimics_path,
    grid,
    native_days;
    annual,
    atol,
    rtol,
)
    return NCDatasets.NCDataset(native_output) do native
        NCDatasets.NCDataset(casa_path) do casa_reference
            NCDatasets.NCDataset(mimics_path) do mimics_reference
                variables = Dict{String, Any}()
                for (name, source, native_name, scale) in HISTORICAL_VARIABLES
                    reference =
                        source == :casa ? casa_reference : mimics_reference
                    haskey(reference, name) ||
                        error("Historical reference is missing $name")
                    actual = native[native_name][:, native_days]
                    expected =
                        native_mimics().reference_values(reference, name, grid)
                    if annual
                        actual = native_mimics().annual_point_mean(actual)
                        expected = native_mimics().annual_point_mean(expected)
                    end
                    variables[name] = native_casa().error_metrics(
                        scale .* actual,
                        expected;
                        atol,
                        rtol,
                    )
                end
                return Dict(
                    "casa_reference" => abspath(casa_path),
                    "mimics_reference" => abspath(mimics_path),
                    "variable" => variables,
                    "all_match" => all(
                        metric["all_match"] for metric in values(variables)
                    ),
                )
            end
        end
    end
end

function compare_fresh_fortran(
    native_output,
    grid,
    historical_root,
    years;
    annual,
    atol,
    rtol,
)
    variables = Dict(
        name => native_mimics().empty_aggregate(atol, rtol) for
        (name, _, _, _) in HISTORICAL_VARIABLES
    )
    for year in years
        native_days = ((year - 1901) * 365 + 1):((year - 1900) * 365)
        comparison = compare_reference_files(
            native_output,
            joinpath(historical_root, "casaclm_pool_flux_$(year)_daily.nc"),
            joinpath(historical_root, "mimics_pool_flux_$(year)_daily.nc"),
            grid,
            native_days;
            annual,
            atol,
            rtol,
        )
        for (name, metric) in comparison["variable"]
            native_mimics().merge_metrics!(variables[name], metric)
        end
    end
    return Dict(
        "reference" => abspath(historical_root),
        "years" => collect(years),
        "variable" => variables,
        "all_match" => all(metric["all_match"] for metric in values(variables)),
    )
end

function compare_archive_annual(native_output, grid, archive_root; atol, rtol)
    variables = Dict(
        name => native_mimics().empty_aggregate(atol, rtol) for
        (name, _, _, _) in HISTORICAL_VARIABLES
    )
    return NCDatasets.NCDataset(native_output) do native
        NCDatasets.NCDataset(
            joinpath(archive_root, "ann_casaclm_pool_flux_1901_2014.nc"),
        ) do casa_reference
            NCDatasets.NCDataset(
                joinpath(archive_root, "ann_mimics_pool_flux_1901_2014.nc"),
            ) do mimics_reference
                for (name, source, native_name, scale) in HISTORICAL_VARIABLES
                    reference =
                        source == :casa ? casa_reference : mimics_reference
                    expected =
                        native_mimics().reference_values(reference, name, grid)
                    for year_index in axes(expected, 2)
                        days = ((year_index - 1) * 365 + 1):(year_index * 365)
                        actual = native_mimics().annual_point_mean(
                            native[native_name][:, days],
                        )
                        metric = native_casa().error_metrics(
                            scale .* actual,
                            view(expected, :, year_index);
                            atol,
                            rtol,
                        )
                        native_mimics().merge_metrics!(variables[name], metric)
                    end
                end
                return Dict(
                    "reference" => abspath(archive_root),
                    "variable" => variables,
                    "all_match" => all(
                        metric["all_match"] for metric in values(variables)
                    ),
                )
            end
        end
    end
end

function compare_archive_window(
    native_output,
    grid,
    archive_root,
    first_year,
    last_year;
    atol,
    rtol,
)
    stem = "$(first_year)_$(last_year)_daily.nc"
    days = ((first_year - 1901) * 365 + 1):((last_year - 1900) * 365)
    return compare_reference_files(
        native_output,
        joinpath(archive_root, "casaclm_pool_flux_$stem"),
        joinpath(archive_root, "mimics_pool_flux_$stem"),
        grid,
        days;
        annual = false,
        atol,
        rtol,
    )
end

function fresh_reference_root(reference_root)
    compact = joinpath(reference_root, "fresh_reference")
    annual = joinpath(compact, "ann_casaclm_pool_flux_1901_2014.nc")
    return isfile(annual) ? compact :
           joinpath(reference_root, "stages", "04-historical")
end

function compare_historical_outputs(
    native_output,
    fresh_grid,
    reference_root;
    archive_grid = fresh_grid,
    compare_fresh = true,
    compare_archive = false,
    fresh_atol,
    fresh_rtol,
    archive_atol,
    archive_rtol,
)
    fresh_fortran = if compare_fresh
        fresh_root = fresh_reference_root(reference_root)
        compact_fresh_annual =
            joinpath(fresh_root, "ann_casaclm_pool_flux_1901_2014.nc")
        fresh_annual =
            isfile(compact_fresh_annual) ?
            compare_archive_annual(
                native_output,
                fresh_grid,
                fresh_root;
                atol = fresh_atol,
                rtol = fresh_rtol,
            ) :
            compare_fresh_fortran(
                native_output,
                fresh_grid,
                fresh_root,
                1901:2014;
                annual = true,
                atol = fresh_atol,
                rtol = fresh_rtol,
            )
        fresh_daily = Dict(
            "1901_1905" => compare_fresh_fortran(
                native_output,
                fresh_grid,
                fresh_root,
                1901:1905;
                annual = false,
                atol = fresh_atol,
                rtol = fresh_rtol,
            ),
            "2010_2014" => compare_fresh_fortran(
                native_output,
                fresh_grid,
                fresh_root,
                2010:2014;
                annual = false,
                atol = fresh_atol,
                rtol = fresh_rtol,
            ),
        )
        Dict(
            "required" => true,
            "tolerance" => Dict("atol" => fresh_atol, "rtol" => fresh_rtol),
            "annual" => fresh_annual,
            "daily" => fresh_daily,
            "all_match" =>
                fresh_annual["all_match"] && all(
                    record["all_match"] for record in values(fresh_daily)
                ),
        )
    else
        Dict("required" => false, "status" => "not_available")
    end
    archive_root = joinpath(reference_root, "reference")
    published_archive = if compare_archive
        archive_annual = compare_archive_annual(
            native_output,
            archive_grid,
            archive_root,
            atol = archive_atol,
            rtol = archive_rtol,
        )
        archive_daily = Dict(
            "1901_1905" => compare_archive_window(
                native_output,
                archive_grid,
                archive_root,
                1901,
                1905;
                atol = archive_atol,
                rtol = archive_rtol,
            ),
            "2010_2014" => compare_archive_window(
                native_output,
                archive_grid,
                archive_root,
                2010,
                2014;
                atol = archive_atol,
                rtol = archive_rtol,
            ),
        )
        Dict(
            "required" => true,
            "tolerance" =>
                Dict("atol" => archive_atol, "rtol" => archive_rtol),
            "annual" => archive_annual,
            "daily" => archive_daily,
            "all_match" =>
                archive_annual["all_match"] && all(
                    record["all_match"] for record in values(archive_daily)
                ),
        )
    else
        Dict("required" => false, "status" => "not_requested")
    end
    return Dict(
        "output" => Dict("records" => 114 * 365),
        "fresh_fortran" => fresh_fortran,
        "published_archive" => published_archive,
    )
end

# -----------------------------------------------------------------------------
# Budgets and reports
# -----------------------------------------------------------------------------

mutable struct BudgetAccumulator
    area_m2::Vector{Float64}
    carbon_input::Dict{Symbol, CompensatedSum{Float64}}
    carbon_output::Dict{Symbol, CompensatedSum{Float64}}
    carbon_adjustment::Dict{Symbol, CompensatedSum{Float64}}
    nitrogen_input::Dict{Symbol, CompensatedSum{Float64}}
    nitrogen_output::Dict{Symbol, CompensatedSum{Float64}}
    nitrogen_adjustment::Dict{Symbol, CompensatedSum{Float64}}
end

BudgetAccumulator(grid) = BudgetAccumulator(
    getproperty.(grid, :area_m2),
    Dict{Symbol, CompensatedSum{Float64}}(),
    Dict{Symbol, CompensatedSum{Float64}}(),
    Dict{Symbol, CompensatedSum{Float64}}(),
    Dict{Symbol, CompensatedSum{Float64}}(),
    Dict{Symbol, CompensatedSum{Float64}}(),
    Dict{Symbol, CompensatedSum{Float64}}(),
)

function accumulate_budget_term!(table, stage, value)
    accumulator = get!(table, stage) do
        CompensatedSum(Float64)
    end
    native_workflow().add_term!(accumulator, value)
    return nothing
end

function accumulate_budget!(budget, stage, p)
    area = budget.area_m2
    plant_carbon = parent(p.casa_plant.carbon_fluxes)
    plant_nitrogen = parent(p.casa_plant.nitrogen_fluxes)
    soil_carbon = parent(p.mimics_soil.carbon_fluxes)
    soil_nitrogen = parent(p.mimics_soil.nitrogen_fluxes)
    deposition = parent(p.mimics_soil.nitrogen_deposition)
    fixation = parent(p.mimics_soil.nitrogen_fixation)
    carbon_input = carbon_output = carbon_adjustment = 0.0
    nitrogen_input = nitrogen_output = nitrogen_adjustment = 0.0
    for point in eachindex(area)
        weight = area[point]
        c_input = plant_carbon[1, 1, 14, point]
        c_output =
            plant_carbon[1, 1, 16, point] +
            plant_carbon[1, 1, 21, point] +
            soil_carbon[1, 1, 9, point]
        c_tendency =
            sum(view(plant_carbon, 1, 1, 1:4, point)) +
            sum(view(soil_carbon, 1, 1, 1:8, point))
        n_input = deposition[1, 1, 1, point] + fixation[1, 1, 1, point]
        n_output =
            soil_nitrogen[1, 1, 10, point] + soil_nitrogen[1, 1, 11, point]
        n_tendency =
            sum(view(plant_nitrogen, 1, 1, 1:3, point)) +
            sum(view(soil_nitrogen, 1, 1, 1:9, point))
        carbon_input += weight * c_input
        carbon_output += weight * c_output
        carbon_adjustment += weight * (c_tendency - (c_input - c_output))
        nitrogen_input += weight * n_input
        nitrogen_output += weight * n_output
        nitrogen_adjustment += weight * (n_tendency - (n_input - n_output))
    end
    name = stage.name
    for (table, value) in (
        (budget.carbon_input, carbon_input),
        (budget.carbon_output, carbon_output),
        (budget.carbon_adjustment, carbon_adjustment),
        (budget.nitrogen_input, nitrogen_input),
        (budget.nitrogen_output, nitrogen_output),
        (budget.nitrogen_adjustment, nitrogen_adjustment),
    )
        accumulate_budget_term!(table, name, DAY_SECONDS * value)
    end
    return nothing
end

function budget_report(budget, stage, initial_state, final_state, element; rtol)
    name = stage.name
    prefix = element == :carbon ? "c_" : "n_"
    units = element == :carbon ? "kg_c" : "kg_n"
    input = native_workflow().compensated_value(
        element == :carbon ? budget.carbon_input[name] :
        budget.nitrogen_input[name],
    )
    output = native_workflow().compensated_value(
        element == :carbon ? budget.carbon_output[name] :
        budget.nitrogen_output[name],
    )
    adjustment = native_workflow().compensated_value(
        element == :carbon ? budget.carbon_adjustment[name] :
        budget.nitrogen_adjustment[name],
    )
    start_stock = selected_casa().area_weighted_stock(
        initial_state,
        budget.area_m2,
        prefix,
    )
    stop_stock =
        selected_casa().area_weighted_stock(final_state, budget.area_m2, prefix)
    return selected_casa().budget_report(
        start_stock,
        stop_stock,
        input,
        output,
        units;
        adjustment,
        rtol,
    )
end

function process_comparison()
    return Dict(
        "litter_and_cwd_input" => [
            "diagnostic__mimics_metabolic_input",
            "diagnostic__mimics_structural_input",
            "diagnostic__mimics_n_metabolic_input",
            "diagnostic__mimics_n_structural_input",
        ],
        "microbial_assimilation" =>
            ["diagnostic__mimics_microbial_assimilation"],
        "overflow" =>
            ["diagnostic__mimics_overflow_r", "diagnostic__mimics_overflow_k"],
        "mineralization" => [
            "diagnostic__mimics_litter_mineralization",
            "diagnostic__mimics_soil_mineralization",
        ],
        "immobilization" => ["diagnostic__mimics_immobilization"],
        "uptake" => ["diagnostic__n_plant_uptake"],
        "external_losses" =>
            ["diagnostic__n_leaching", "diagnostic__n_gaseous_loss"],
    )
end

function write_report(
    path;
    historical_output,
    stage_budgets,
    nitrogen_stage_budgets,
    boundary_comparison,
    historical_comparison,
    stage_initialization,
)
    report = Dict(
        "schema_version" => 1,
        "issue" => 31,
        "scientific_configuration" => Dict(
            "issue_43_parameters" => MIMICS_PARAMETER_FILE,
            "parameter_sha256" => MIMICS_PARAMETER_SHA256,
            "mineral_nitrogen_owner" => "mimics_soil.n_mineral",
            "working_din" => "diagnostic__mimics_working_din stores end-of-map DIN",
            "native_checkpoint_handoff" => true,
            "stage_initialization" => stage_initialization,
        ),
        "historical_output" => historical_output,
        "boundary_comparison" => boundary_comparison,
        "historical_comparison" => historical_comparison,
        "process_budget_scope" => process_comparison(),
        "carbon_budget" => Dict(
            "stage" => stage_budgets,
            "all_close" => all(
                get(item, "close", false) for item in values(stage_budgets)
            ),
        ),
        "nitrogen_budget" => Dict(
            "stage" => nitrogen_stage_budgets,
            "all_close" => all(
                get(item, "close", false) for
                item in values(nitrogen_stage_budgets)
            ),
        ),
    )
    open(path, "w") do io
        TOML.print(io, report; sorted = true)
    end
    return path
end

function require_acceptance!(
    path;
    require_fresh = true,
    require_archive = false,
)
    report = TOML.parsefile(path)
    checks = Dict(
        "boundary comparisons" => all(
            comparison["all_match"] for
            comparison in values(report["boundary_comparison"])
        ),
        "carbon budget" => report["carbon_budget"]["all_close"],
        "nitrogen budget" => report["nitrogen_budget"]["all_close"],
    )
    require_fresh && (
        checks["fresh Fortran comparison"] =
            report["historical_comparison"]["fresh_fortran"]["all_match"]
    )
    require_archive && (
        checks["published archive comparison"] =
            report["historical_comparison"]["published_archive"]["all_match"]
    )
    failures = sort!([name for (name, passed) in checks if !passed])
    isempty(failures) || error(
        "MIMICS-CN reconstruction failed acceptance: $(join(failures, ", "))",
    )
    return path
end

# -----------------------------------------------------------------------------
# Native workflow execution
# -----------------------------------------------------------------------------

function run_case(
    initial_state,
    stages,
    output_root;
    model_for_stage,
    prepare_stage! = (_, _, _) -> nothing,
    update_forcing! = (_, _, _) -> nothing,
    after_step! = (_, _, _, _, _) -> nothing,
    diagnostics = mimics_cn_diagnostics(),
    provenance,
    compare_boundary,
    compare_historical,
    carbon_budget,
    nitrogen_budget,
    stage_initialization = "native_checkpoint_handoff",
    output_eltype = Float64,
    deflatelevel = 0,
)
    expected = (:prespin, :spin, :spin_continuation, :historical)
    getproperty.(stages, :name) == expected ||
        throw(ArgumentError("MIMICS-CN stages must be ordered $expected"))
    current_state = initial_state
    stage_results = NamedTuple[]
    stage_budgets = Dict{String, Any}()
    nitrogen_stage_budgets = Dict{String, Any}()
    boundary_comparison = Dict{String, Any}()
    historical_output = ""
    for stage in stages
        model = model_for_stage(stage)
        prepare_stage!(stage, current_state, model)
        stage_root = joinpath(output_root, "stages", String(stage.name))
        result = native_workflow().run_workflow(
            model,
            current_state,
            [stage],
            stage_root;
            update_forcing!,
            after_step!,
            diagnostics,
            output_eltype,
            deflatelevel,
            provenance = provenance(stage),
        )
        final_state = native_casa().state_as_initial_state(result.state, model)
        stage_budgets[String(stage.name)] =
            carbon_budget(stage, current_state, final_state)
        nitrogen_stage_budgets[String(stage.name)] =
            nitrogen_budget(stage, current_state, final_state)
        boundary_comparison[String(stage.name)] =
            compare_boundary(stage, result, model)
        checkpoint = only(result.checkpoints)
        checkpoint_state, _ = ClimaLand.read_checkpoint(checkpoint; model)
        current_state =
            native_casa().state_as_initial_state(checkpoint_state, model)
        roundtrip = native_casa().states_match(final_state, current_state)
        push!(
            stage_results,
            (;
                name = stage.name,
                checkpoint,
                checkpoint_roundtrip_verified = roundtrip,
                manifest = result.manifest,
            ),
        )
        stage.name == :historical && (historical_output = result.output)
    end
    historical_comparison = compare_historical(historical_output)
    historical_metadata = merge(
        Dict("path" => historical_output),
        pop!(historical_comparison, "output", Dict{String, Any}()),
    )
    report = write_report(
        joinpath(output_root, "reconstruction_report.toml");
        historical_output = historical_metadata,
        stage_budgets,
        nitrogen_stage_budgets,
        boundary_comparison,
        historical_comparison,
        stage_initialization,
    )
    return (; stages = Tuple(stage_results), output = historical_output, report)
end

function gridded_provenance(stage, plant_path, mimics_path, reference_root)
    directory = Dict(
        :prespin => "01-prespin",
        :spin => "02-spin",
        :spin_continuation => "03-spin_continuation",
        :historical => "04-historical",
    )[stage.name]
    metadata =
        joinpath(reference_root, "stages", directory, "stage_metadata.toml")
    return Dict(
        "model" => "ClimaLand integrated CASA and MIMICS carbon-nitrogen",
        "configuration" => "issue-31 using issue-43 KO4/FI30 parameters",
        "pft" => "IGBP 1:18 in pinned 4,263-cell grid order",
        "parameter_file" => Dict(
            "source" => abspath(mimics_path),
            "sha256" => native_workflow().sha256sum(mimics_path),
            "casa_source" => abspath(plant_path),
            "casa_sha256" => native_workflow().sha256sum(plant_path),
        ),
        "forcing" => [
            Dict(
                "stage" => String(stage.name),
                "source" => abspath(metadata),
                "sha256" => native_workflow().sha256sum(metadata),
            ),
        ],
    )
end

function run_gridded_case(
    source_root,
    forcing_root,
    reference_root,
    output_root;
    expected_points = 4263,
    archive_grid_path = nothing,
    grid_path = nothing,
    soil_path = nothing,
    prespin_parameters_path = nothing,
    compare_archive = false,
    boundary_atol = 5e-3,
    boundary_rtol = 1e-3,
    fresh_atol = 5e-3,
    fresh_rtol = 1e-3,
    archive_atol = 5e-3,
    archive_rtol = 1e-3,
    budget_rtol = 5e-12,
    reference_stage_initialization = false,
    compare_fresh = true,
)
    grid_path =
        isnothing(grid_path) ?
        joinpath(source_root, "GRID_CN", "gridinfo_igbpz_CLM5_GSWP3.csv") :
        grid_path
    soil_path =
        isnothing(soil_path) ?
        joinpath(source_root, "GRID_CN", "gridinfo_soil_CLM5_GSWP3.csv") :
        soil_path
    phenology_path =
        joinpath(source_root, "GRID_CN", "modis_phenology_wtundra.txt")
    prespin_path =
        isnothing(prespin_parameters_path) ?
        joinpath(
            reference_root,
            "candidates",
            "parameters",
            "pftlookup_igbp_updated4_borealNfix.candidate.csv",
        ) : prespin_parameters_path
    normal_path =
        joinpath(source_root, "GRID_CN", "pftlookup_igbp_updated4_exud0.csv")
    mimics_path = joinpath(
        source_root,
        "GRID_CN",
        "MIMICS_mod5_GSWP3_JAMES",
        MIMICS_PARAMETER_FILE,
    )
    native_workflow().sha256sum(mimics_path) == MIMICS_PARAMETER_SHA256 ||
        error("Issue-43 MIMICS parameter hash mismatch")
    grid = native_casa().read_grid(grid_path)
    length(grid) == expected_points || error(
        "Pinned MIMICS-CN grid must have $(expected_points) rows; found $(length(grid))",
    )
    archive_grid =
        isnothing(archive_grid_path) ? grid :
        native_casa().read_grid(archive_grid_path)
    length(archive_grid) == length(grid) || error(
        "Archive comparison grid must have $(length(grid)) rows; found $(length(archive_grid))",
    )
    soils = native_casa().read_soils(soil_path)
    domain = native_casa().gridded_domain(length(grid))
    buffers = native_mimics().MIMICSBuffers(domain)
    nitrogen_deposition =
        native_casa().scalar_field(domain, zeros(length(grid)))
    prespin = build_gridded_model(
        grid,
        soils,
        prespin_path,
        mimics_path,
        buffers,
        nitrogen_deposition;
        domain,
        boreal_fixation = true,
    )
    normal = build_gridded_model(
        grid,
        soils,
        normal_path,
        mimics_path,
        buffers,
        nitrogen_deposition;
        domain,
    )
    forcing = native_mimics().MIMICSForcing(
        grid,
        soils,
        normal.parameters,
        phenology_path,
        forcing_root,
        buffers;
        nitrogen_deposition,
        legacy_single_precision = true,
    )
    model_for_stage(stage) =
        stage.name == :prespin ? prespin.model : normal.model
    plant_for_stage(stage) = stage.name == :prespin ? prespin_path : normal_path
    directories = Dict(
        :prespin => "01-prespin",
        :spin => "02-spin",
        :spin_continuation => "03-spin_continuation",
        :historical => "04-historical",
    )
    predecessors = Dict(
        :spin => :prespin,
        :spin_continuation => :spin,
        :historical => :spin_continuation,
    )
    budget = BudgetAccumulator(grid)
    annual_npp = native_mimics().AnnualNPPTracker(domain)
    initial_state = gridded_initial_state(
        prespin.model,
        grid,
        prespin_path,
        prespin.nitrogen,
    )
    fixed_plant_stoichiometry = Dict{Symbol, Vector{Float64}}()
    function prepare_stage!(stage, current_state, model)
        if stage.name != :prespin
            if reference_stage_initialization
                predecessor = predecessors[stage.name]
                directory =
                    joinpath(reference_root, "stages", directories[predecessor])
                load_fortran_restart!(
                    current_state,
                    joinpath(directory, "casa_final.csv"),
                    joinpath(directory, "mimics_final.csv"),
                )
            else
                quantize_fortran_restart!(current_state)
            end
        end
        parameters =
            stage.name == :prespin ? prespin.parameters : normal.parameters
        fixed_plant_stoichiometry[stage.name] =
            use_initial_plant_stoichiometry!(
                model,
                grid,
                parameters,
                current_state,
            )
    end
    function update_drivers!(stage, index, time)
        native_mimics().update_forcing!(forcing, stage, index, time)
        native_mimics().prepare_annual_npp!(annual_npp, forcing, stage, index)
    end
    function after_step!(stage, step, _, p, _)
        native_mimics().accumulate_annual_npp!(annual_npp, p)
        accumulate_budget!(budget, stage, p)
        step == 1 && restore_plant_stoichiometry!(
            model_for_stage(stage),
            fixed_plant_stoichiometry[stage.name],
        )
    end
    function compare_boundary(stage, result, _)
        directory = joinpath(reference_root, "stages", directories[stage.name])
        return compare_boundary_csv(
            result.state,
            joinpath(directory, "casa_final.csv"),
            joinpath(directory, "mimics_final.csv");
            atol = boundary_atol,
            rtol = boundary_rtol,
        )
    end
    carbon_budget(stage, initial_state, final_state) = budget_report(
        budget,
        stage,
        initial_state,
        final_state,
        :carbon;
        rtol = budget_rtol,
    )
    nitrogen_budget(stage, initial_state, final_state) = budget_report(
        budget,
        stage,
        initial_state,
        final_state,
        :nitrogen;
        rtol = budget_rtol,
    )
    try
        result = run_case(
            initial_state,
            COMPLETE_STAGES,
            output_root;
            model_for_stage,
            prepare_stage!,
            update_forcing! = update_drivers!,
            after_step!,
            diagnostics = mimics_cn_diagnostics(
                normal.model.mimics_soil.parameters,
            ),
            output_eltype = Float32,
            deflatelevel = 1,
            provenance = stage -> gridded_provenance(
                stage,
                plant_for_stage(stage),
                mimics_path,
                reference_root,
            ),
            compare_boundary,
            compare_historical = path -> compare_historical_outputs(
                path,
                grid,
                reference_root;
                archive_grid,
                compare_fresh,
                compare_archive,
                fresh_atol,
                fresh_rtol,
                archive_atol,
                archive_rtol,
            ),
            carbon_budget,
            nitrogen_budget,
            stage_initialization = reference_stage_initialization ?
                                   "fresh_fortran_predecessor_restart" :
                                   "native_checkpoint_handoff",
        )
        require_acceptance!(
            result.report;
            require_fresh = compare_fresh,
            require_archive = compare_archive,
        )
        return result
    finally
        for stage in COMPLETE_STAGES
            haskey(fixed_plant_stoichiometry, stage.name) || continue
            restore_plant_stoichiometry!(
                model_for_stage(stage),
                fixed_plant_stoichiometry[stage.name],
            )
        end
        native_mimics().close_forcing!(forcing)
    end
end

# -----------------------------------------------------------------------------
# Synthetic smoke case and command-line entry point
# -----------------------------------------------------------------------------

function zero_initial_state(model)
    components = ClimaLand.land_components(model)
    return NamedTuple{components}(
        map(components) do component_name
            component = getproperty(model, component_name)
            variables = ClimaLand.prognostic_vars(component)
            NamedTuple{variables}(
                map(variables) do _
                    ClimaCore.Fields.zeros(
                        Float64,
                        component.domain.space.surface,
                    )
                end,
            )
        end,
    )
end

function synthetic_comparison(path)
    records = NCDatasets.NCDataset(path) do output
        size(output["time"], 1)
    end
    return Dict(
        "output" => Dict("records" => records),
        "fresh_fortran" =>
            Dict("source" => "fresh_fortran", "all_match" => true),
        "published_archive" =>
            Dict("source" => "published_archive", "all_match" => true),
    )
end

function run_synthetic_case(output_root)
    fixture = joinpath(@__DIR__, "fixtures", "selected_cells")
    grid =
        native_casa().read_grid(joinpath(fixture, "grid_selected_cells.csv"))[1:2]
    soils =
        native_casa().read_soils(joinpath(fixture, "soil_selected_cells.csv"))
    domain = native_casa().gridded_domain(length(grid))
    buffers = native_mimics().MIMICSBuffers(domain)
    buffers.air_temperature .= 273.15
    buffers.soil_temperature .= 273.15
    buffers.phase .= 2
    deposition = native_casa().scalar_field(domain, zeros(length(grid)))
    plant_path = joinpath(fixture, "pftlookup_igbp_updated4_exud0.csv")
    mimics_path = joinpath(fixture, MIMICS_PARAMETER_FILE)
    built = build_gridded_model(
        grid,
        soils,
        plant_path,
        mimics_path,
        buffers,
        deposition;
        domain,
    )
    stages = (
        native_workflow().NativeStage(:prespin, 2, 1; write_output = false),
        native_workflow().NativeStage(:spin, 2, 1; write_output = false),
        native_workflow().NativeStage(
            :spin_continuation,
            2,
            1;
            write_output = false,
        ),
        native_workflow().NativeStage(:historical, 2, 1),
    )
    budget = BudgetAccumulator(grid)
    after_step!(stage, _, _, p, _) = accumulate_budget!(budget, stage, p)
    compare_boundary(_, result, model) = Dict(
        "all_match" => all(
            all(isfinite, parent(getproperty(getproperty(result.state, c), v))) for c in ClimaLand.land_components(model) for
            v in ClimaLand.prognostic_vars(getproperty(model, c))
        ),
    )
    provenance(stage) = Dict(
        "model" => "ClimaLand integrated CASA and MIMICS carbon-nitrogen",
        "configuration" => "synthetic issue-31 acceptance case",
        "pft" => "two pinned fixture points",
        "parameter_file" => Dict(
            "source" => mimics_path,
            "sha256" => MIMICS_PARAMETER_SHA256,
        ),
        "forcing" => [
            Dict(
                "stage" => String(stage.name),
                "source" => "synthetic",
                "sha256" => "synthetic",
            ),
        ],
    )
    carbon_budget(stage, initial_state, final_state) = budget_report(
        budget,
        stage,
        initial_state,
        final_state,
        :carbon;
        rtol = 64eps(Float64),
    )
    nitrogen_budget(stage, initial_state, final_state) = budget_report(
        budget,
        stage,
        initial_state,
        final_state,
        :nitrogen;
        rtol = 64eps(Float64),
    )
    return run_case(
        zero_initial_state(built.model),
        stages,
        output_root;
        model_for_stage = _ -> built.model,
        after_step!,
        diagnostics = mimics_cn_diagnostics(built.model.mimics_soil.parameters),
        provenance,
        compare_boundary,
        compare_historical = synthetic_comparison,
        carbon_budget,
        nitrogen_budget,
        output_eltype = Float32,
        deflatelevel = 1,
    )
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 4 || error(
        "usage: native_mimics_cn_reconstruction.jl SOURCE_ROOT FORCING_ROOT REFERENCE_ROOT OUTPUT_ROOT",
    )
    TestbedNativeMIMICSCNReconstruction.run_gridded_case(ARGS...)
end
