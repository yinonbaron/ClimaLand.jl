if !isdefined(@__MODULE__, :TestbedNativeWorkflow)
    include(joinpath(@__DIR__, "native_workflow.jl"))
end
if !isdefined(@__MODULE__, :TestbedNativeCASACReconstruction)
    include(joinpath(@__DIR__, "native_casa_c_reconstruction.jl"))
end
if !isdefined(@__MODULE__, :TestbedGridTransitionParity)
    include(joinpath(@__DIR__, "grid_transition_parity.jl"))
end

module TestbedNativeMIMICSCReconstruction

import ClimaComms
import ClimaCore
import ClimaLand
import NCDatasets
import TOML

const PlantCASA = ClimaLand.Vegetation.CASA
const SoilMIMICS = ClimaLand.Soil.Biogeochemistry.MIMICS
const DAY_SECONDS = 86400.0
const PROCESS_VARIABLES = Dict(
    "respiration" => ["diagnostic__mimics_respiration"],
    "litter_inputs" => [
        "diagnostic__mimics_metabolic_input",
        "diagnostic__mimics_structural_input",
    ],
    "microbial_turnover" =>
        ["diagnostic__mimics_r_turnover", "diagnostic__mimics_k_turnover"],
    "protection" => [
        "diagnostic__mimics_physical_protection",
        "diagnostic__mimics_chemical_protection",
    ],
    "desorption" => ["diagnostic__mimics_desorption"],
    "oxidation" => ["diagnostic__mimics_oxidation"],
    "cwd_transfer" => ["diagnostic__mimics_cwd_transfer"],
)
const BOUNDARY_VARIABLES = (
    ("casapool%clabile", :casa, :casa_plant, :c_labile),
    ("casapool%cplant(LEAF)", :casa, :casa_plant, :c_leaf),
    ("casapool%cplant(WOOD)", :casa, :casa_plant, :c_wood),
    ("casapool%cplant(FROOT)", :casa, :casa_plant, :c_fine_root),
    ("casapool%clitter(CWD)", :casa, :mimics_soil, :c_litter_cwd),
    ("mimicspool%LITm", :mimics, :mimics_soil, :c_litter_metabolic),
    ("mimicspool%LITs", :mimics, :mimics_soil, :c_litter_structural),
    ("mimicspool%MICr", :mimics, :mimics_soil, :c_microbe_r),
    ("mimicspool%MICk", :mimics, :mimics_soil, :c_microbe_k),
    ("mimicspool%SOMa", :mimics, :mimics_soil, :c_soil_available),
    ("mimicspool%SOMc", :mimics, :mimics_soil, :c_soil_chemical),
    ("mimicspool%SOMp", :mimics, :mimics_soil, :c_soil_physical),
)
const HISTORICAL_VARIABLES = (
    ("cleaf", :casa, "casa_plant__c_leaf", 1000.0),
    ("cwood", :casa, "casa_plant__c_wood", 1000.0),
    ("cfroot", :casa, "casa_plant__c_fine_root", 1000.0),
    ("clitcwd", :casa, "mimics_soil__c_litter_cwd", 1000.0),
    ("cgpp", :casa, "diagnostic__cgpp", 1000DAY_SECONDS),
    ("cnpp", :casa, "diagnostic__cnpp", 1000DAY_SECONDS),
    ("cLITm", :mimics, "mimics_soil__c_litter_metabolic", 1000.0),
    ("cLITs", :mimics, "mimics_soil__c_litter_structural", 1000.0),
    ("cMICr", :mimics, "mimics_soil__c_microbe_r", 1000.0),
    ("cMICk", :mimics, "mimics_soil__c_microbe_k", 1000.0),
    ("cSOMa", :mimics, "mimics_soil__c_soil_available", 1000.0),
    ("cSOMc", :mimics, "mimics_soil__c_soil_chemical", 1000.0),
    ("cSOMp", :mimics, "mimics_soil__c_soil_physical", 1000.0),
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
)

native_workflow() = getfield(parentmodule(@__MODULE__), :TestbedNativeWorkflow)
casa() = getfield(parentmodule(@__MODULE__), :TestbedNativeCASACReconstruction)
grid_parity() =
    getfield(parentmodule(@__MODULE__), :TestbedGridTransitionParity)

function mimics_diagnostics()
    flux(name, long_name, compute) =
        (; name, long_name, units = "kg C m-2 s-1", compute)
    carbon_flux(index) = (_, p) -> getindex.(p.mimics_soil.carbon_fluxes, index)
    return (
        flux(
            "diagnostic__cgpp",
            "gross primary production",
            (_, p) -> getindex.(p.casa_plant.carbon_fluxes, 14),
        ),
        flux(
            "diagnostic__cnpp",
            "net primary production",
            (_, p) -> getindex.(p.casa_plant.carbon_fluxes, 15),
        ),
        flux(
            "diagnostic__mimics_respiration",
            "MIMICS heterotrophic respiration",
            carbon_flux(9),
        ),
        flux(
            "diagnostic__mimics_physical_protection",
            "MIMICS physical-protection input",
            carbon_flux(13),
        ),
        flux(
            "diagnostic__mimics_r_turnover",
            "MIMICS r-strategist microbial turnover",
            carbon_flux(11),
        ),
        flux(
            "diagnostic__mimics_k_turnover",
            "MIMICS K-strategist microbial turnover",
            carbon_flux(12),
        ),
        flux(
            "diagnostic__mimics_chemical_protection",
            "MIMICS chemical-protection input",
            carbon_flux(14),
        ),
        flux(
            "diagnostic__mimics_desorption",
            "MIMICS physical-pool desorption",
            carbon_flux(15),
        ),
        flux(
            "diagnostic__mimics_oxidation",
            "MIMICS chemical-pool oxidation",
            carbon_flux(16),
        ),
        flux(
            "diagnostic__mimics_cwd_transfer",
            "MIMICS coarse-woody-debris transfer to structural litter",
            carbon_flux(17),
        ),
        flux(
            "diagnostic__mimics_metabolic_input",
            "MIMICS metabolic-litter input",
            (_, p) -> p.mimics_soil.litter_metabolic_input,
        ),
        flux(
            "diagnostic__mimics_structural_input",
            "MIMICS structural-litter input including CWD transfer",
            (_, p) ->
                p.mimics_soil.litter_structural_input .+
                getindex.(p.mimics_soil.carbon_fluxes, 17),
        ),
    )
end

mutable struct MIMICSBuffers{F}
    gpp::F
    air_temperature::F
    soil_temperature::F
    water_stress::F
    liquid_water::F
    phase::F
    liquid_saturation::F
    frozen_saturation::F
    annual_npp::F
    litter_quality::F
end

function MIMICSBuffers(domain)
    template = ClimaCore.Fields.zeros(Float64, domain.space.surface)
    npoints = length(parent(template))
    fields = ntuple(_ -> casa().scalar_field(domain, zeros(npoints)), 10)
    return MIMICSBuffers(fields...)
end

mutable struct FrozenYearCache
    loaded::BitVector
    saturation::Matrix{Float64}
end

mutable struct MIMICSForcing{F, B, G}
    base::F
    buffers::B
    grid::G
    porosity::Vector{Float64}
    root_fraction::Matrix{Float64}
    annual_npp_cache::Dict{Int, Vector{Float64}}
    frozen_cache::Dict{Int, FrozenYearCache}
    transient_frozen_year::Int
    transient_frozen_cache::FrozenYearCache
end

empty_frozen_cache(points) = FrozenYearCache(falses(365), zeros(points, 365))

function MIMICSForcing(
    grid,
    soils,
    plant_parameters,
    phenology_path,
    forcing_root,
    buffers,
)
    base = casa().GriddedForcing(
        grid,
        soils,
        plant_parameters,
        phenology_path,
        forcing_root,
        buffers,
    )
    return MIMICSForcing(
        base,
        buffers,
        collect(grid),
        [soils[point.cell_id].porosity for point in grid],
        base.root_fraction,
        Dict{Int, Vector{Float64}}(),
        Dict{Int, FrozenYearCache}(),
        0,
        empty_frozen_cache(length(grid)),
    )
end

close_forcing!(forcing) = casa().close_forcing!(forcing.base)

function read_mimics_scalars(path)
    values = Dict{String, Float64}()
    for line in readlines(path)
        fields = split(strip(line), ','; keepempty = true)
        length(fields) >= 2 || continue
        value = tryparse(Float64, strip(fields[1]))
        isnothing(value) && continue
        label = strip(fields[2])
        isempty(label) || (values[label] = value)
    end
    return values
end

function mimics_metabolic_fraction(parameters, organ, mimics)
    carbon_nitrogen =
        organ == :leaf ? inv(parameters.plant_nitrogen_ratio[1]) :
        inv(parameters.plant_nitrogen_ratio[3])
    lignin = organ == :leaf ? parameters.lignin_leaf : parameters.lignin_root
    return max(
        0.001,
        mimics["fmet_p(1)"] *
        (mimics["fmet_p(2)"] - mimics["fmet_p(3)"] * carbon_nitrogen * lignin),
    )
end

function forced_annual_npp!(forcing, year)
    return get!(forcing.annual_npp_cache, year) do
        dataset = casa().ensure_forcing_year!(forcing.base, year)
        gpp = dataset["xcgpp"][:, :, :]
        values = zeros(length(forcing.grid))
        for (index, point) in enumerate(forcing.grid)
            forcing.base.active[index] || continue
            values[index] =
                sum(gpp[point.longitude_index, point.latitude_index, :]) / 2 /
                1000
        end
        values
    end
end

function frozen_year_cache!(forcing, year)
    if year <= 1920
        return get!(forcing.frozen_cache, year) do
            empty_frozen_cache(length(forcing.grid))
        end
    end
    if forcing.transient_frozen_year != year
        forcing.transient_frozen_year = year
        forcing.transient_frozen_cache =
            empty_frozen_cache(length(forcing.grid))
    end
    return forcing.transient_frozen_cache
end

function load_frozen_saturation!(forcing, year, day)
    cache = frozen_year_cache!(forcing, year)
    cache.loaded[day] && return view(cache.saturation, :, day)
    dataset = casa().ensure_forcing_year!(forcing.base, year)
    frozen = dataset["xfrznmoist"][:, :, :, day]
    for point_index in eachindex(forcing.grid)
        forcing.base.active[point_index] || continue
        point = forcing.grid[point_index]
        frozen_water = 0.0
        for layer in axes(forcing.root_fraction, 2)
            frozen_water +=
                forcing.root_fraction[point_index, layer] *
                frozen[point.longitude_index, point.latitude_index, layer]
        end
        cache.saturation[point_index, day] =
            min(1.0, frozen_water / forcing.porosity[point_index])
    end
    cache.loaded[day] = true
    return view(cache.saturation, :, day)
end

function update_forcing!(forcing, stage, index, time)
    casa().update_forcing!(forcing.base, stage, index, time)
    year, day = casa().forcing_year_day(stage, index)
    liquid_values = vec(parent(forcing.buffers.liquid_water))
    liquid_saturation = vec(parent(forcing.buffers.liquid_saturation))
    frozen_saturation = vec(parent(forcing.buffers.frozen_saturation))
    frozen_saturation .= load_frozen_saturation!(forcing, year, day)
    for point_index in eachindex(forcing.grid)
        if forcing.base.active[point_index]
            porosity = forcing.porosity[point_index]
            liquid_saturation[point_index] =
                min(1.0, liquid_values[point_index] / porosity)
        else
            liquid_saturation[point_index] = 0.0
        end
    end
    return nothing
end

function mimics_soil_parameters(carbon, plant, soil)
    cwd_transfer =
        plant.cues[4] * (1 - plant.lignin_wood) +
        plant.cues[5] * plant.lignin_wood
    parameter_type =
        SoilMIMICS.MIMICSSoilModelParameters{Float64, typeof(carbon)}
    return parameter_type(;
        carbon,
        clay = soil.clay,
        freezing_temperature = 273.15,
        cwd_q10 = plant.q10,
        cwd_litter_optimum = plant.litter_optimum,
        cwd_base_rate = plant.litter_rates[3],
        cwd_respiration_fraction = 1 - cwd_transfer,
    )
end

function build_gridded_model(
    grid,
    soils,
    plant_parameter_path,
    mimics_parameter_path,
    buffers;
    domain = casa().gridded_domain(length(grid)),
)
    plant_build = casa().build_gridded_model(
        grid,
        soils,
        plant_parameter_path,
        buffers;
        domain,
    )
    carbon = grid_parity().read_mimics_parameters(mimics_parameter_path)
    mimics = read_mimics_scalars(mimics_parameter_path)
    soil_points = map(grid) do point
        mimics_soil_parameters(
            carbon,
            plant_build.parameters[point.pft],
            soils[point.cell_id],
        )
    end
    coupling_points = map(grid) do point
        parameters = plant_build.parameters[point.pft]
        ClimaLand.LitterCouplingParameters{Float64}(;
            leaf_metabolic_fraction = mimics_metabolic_fraction(
                parameters,
                :leaf,
                mimics,
            ),
            root_metabolic_fraction = mimics_metabolic_fraction(
                parameters,
                :root,
                mimics,
            ),
        )
    end
    soil = SoilMIMICS.MIMICSSoilModel{Float64}(;
        parameters = casa().point_field(domain, soil_points),
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
        domain,
    )
    model = ClimaLand.CASAPlantSoilModel{Float64}(
        plant_build.model.casa_plant,
        soil,
        casa().point_field(domain, coupling_points),
    )
    return (; model, parameters = plant_build.parameters, mimics)
end

function initial_mimics_carbon(variable)
    variable in (:c_litter_metabolic, :c_litter_structural) && return 1.0
    variable == :c_microbe_r && return 0.015
    variable == :c_microbe_k && return 0.025
    variable in (:c_soil_available, :c_soil_chemical, :c_soil_physical) &&
        return 1.0
    error("Unknown initialized MIMICS-C state variable $variable")
end

function gridded_initial_state(model, grid, parameters)
    plant = casa().gridded_initial_state(model, grid, parameters).casa_plant
    values(variable) =
        map(grid) do point
            plant_values = parameters[point.pft]
            plant_values.inactive && return 0.0
            variable == :c_litter_cwd && return plant_values.nonwoody ? 0.0 :
                   plant_values.initial_carbon[6]
            return initial_mimics_carbon(variable)
        end
    field(variable) =
        casa().scalar_field(model.casa_plant.domain, values(variable))
    mimics = NamedTuple{ClimaLand.prognostic_vars(model.mimics_soil)}(
        map(field, ClimaLand.prognostic_vars(model.mimics_soil)),
    )
    return (; casa_plant = plant, mimics_soil = mimics)
end

mutable struct AnnualNPPTracker{F}
    active_stage::Union{Nothing, Symbol}
    accumulated::F
end

AnnualNPPTracker(domain) = AnnualNPPTracker(
    nothing,
    ClimaCore.Fields.zeros(Float64, domain.space.surface),
)

function prepare_annual_npp!(tracker, forcing, stage, index)
    year, day = casa().forcing_year_day(stage, index)
    day == 1 || return nothing
    values = vec(parent(forcing.buffers.annual_npp))
    if tracker.active_stage != stage.name
        tracker.active_stage = stage.name
        values .= forced_annual_npp!(forcing, year)
    else
        forcing.buffers.annual_npp .= tracker.accumulated
    end
    tracker.accumulated .= 0.0
    return nothing
end

function accumulate_annual_npp!(tracker, p)
    @. tracker.accumulated +=
        DAY_SECONDS * getindex(p.casa_plant.carbon_fluxes, 15)
    return nothing
end

@inline function litter_quality_value(
    point,
    plant_fluxes,
    soil_fluxes,
    fmet_scale,
    fmet_intercept,
    fmet_slope,
)
    point.inactive && return 0.0
    leaf_ratio = inv(point.plant_nitrogen_ratio[1]) * point.lignin_leaf
    root_ratio = inv(point.plant_nitrogen_ratio[3]) * point.lignin_root
    wood_ratio = inv(point.plant_nitrogen_ratio[2]) * point.lignin_wood
    leaf_turnover = plant_fluxes[8]
    root_turnover = plant_fluxes[10]
    cwd_transfer = soil_fluxes[17]
    total = leaf_turnover + root_turnover + cwd_transfer
    average = min(
        40.0,
        (
            leaf_ratio * leaf_turnover +
            root_ratio * root_turnover +
            wood_ratio * cwd_transfer
        ) / max(0.001 / 1000 / DAY_SECONDS, total),
    )
    return fmet_scale * (fmet_intercept - fmet_slope * average)
end

function update_litter_quality!(
    buffers,
    set_initial_cache!,
    parameters,
    fmet_coefficients,
    Y,
    p,
    time,
)
    set_initial_cache!(p, Y, time)
    fmet_scale, fmet_intercept, fmet_slope = fmet_coefficients
    compute(point, plant_fluxes, soil_fluxes) = litter_quality_value(
        point,
        plant_fluxes,
        soil_fluxes,
        fmet_scale,
        fmet_intercept,
        fmet_slope,
    )
    @. buffers.litter_quality = compute(
        parameters,
        p.casa_plant.carbon_fluxes,
        p.mimics_soil.carbon_fluxes,
    )
    return nothing
end

function read_boundary_csv(path)
    lines = readlines(path)
    header = strip.(split(first(lines), ','))
    columns = Dict(name => index for (index, name) in enumerate(header))
    data = [strip.(split(line, ',')) for line in lines[2:end]]
    return columns, data
end

boundary_reference_scale(source) = source == :casa ? 1000.0 : 1.0

function compare_boundary_csv(Y, casa_path, mimics_path; atol, rtol)
    casa_columns, casa_data = read_boundary_csv(casa_path)
    mimics_columns, mimics_data = read_boundary_csv(mimics_path)
    length(casa_data) == length(mimics_data) ||
        error("CASA and MIMICS restart row counts differ")
    report = Dict{String, Any}()
    for (reference_name, source, component, variable) in BOUNDARY_VARIABLES
        columns, data =
            source == :casa ? (casa_columns, casa_data) :
            (mimics_columns, mimics_data)
        scale = boundary_reference_scale(source)
        actual =
            scale .*
            vec(Array(parent(getproperty(getproperty(Y, component), variable))))
        expected =
            [parse(Float64, row[columns[reference_name]]) for row in data]
        report[reference_name] =
            casa().error_metrics(actual, expected; atol, rtol)
    end
    return Dict(
        "casa_reference" => abspath(casa_path),
        "mimics_reference" => abspath(mimics_path),
        "points" => length(casa_data),
        "variable" => report,
        "all_match" => all(metric["all_match"] for metric in values(report)),
    )
end

function empty_aggregate(atol, rtol)
    return Dict(
        "compared_values" => 0,
        "failed_values" => 0,
        "maximum_absolute_error" => 0.0,
        "maximum_relative_error" => 0.0,
        "atol" => atol,
        "rtol" => rtol,
        "all_match" => true,
    )
end

function merge_metrics!(aggregate, metric)
    aggregate["compared_values"] += metric["compared_values"]
    aggregate["failed_values"] += metric["failed_values"]
    aggregate["maximum_absolute_error"] = max(
        aggregate["maximum_absolute_error"],
        metric["maximum_absolute_error"],
    )
    aggregate["maximum_relative_error"] = max(
        aggregate["maximum_relative_error"],
        metric["maximum_relative_error"],
    )
    aggregate["all_match"] &= metric["all_match"]
    return aggregate
end

function reference_values(dataset, name, grid, days = Colon())
    return casa().reference_points(dataset[name], grid, days)
end

annual_point_mean(values) = vec(sum(values; dims = 2)) ./ size(values, 2)

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
                report = Dict{String, Any}()
                for (name, source, native_name, scale) in HISTORICAL_VARIABLES
                    reference =
                        source == :casa ? casa_reference : mimics_reference
                    actual = native[native_name][:, native_days]
                    expected = reference_values(reference, name, grid, Colon())
                    if annual
                        actual = annual_point_mean(actual)
                        expected = annual_point_mean(expected)
                    end
                    report[name] = casa().error_metrics(
                        scale .* actual,
                        expected;
                        atol,
                        rtol,
                    )
                end
                return Dict(
                    "casa_reference" => abspath(casa_path),
                    "mimics_reference" => abspath(mimics_path),
                    "variable" => report,
                    "all_match" =>
                        all(metric["all_match"] for metric in values(report)),
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
    report = Dict(
        name => empty_aggregate(atol, rtol) for
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
            merge_metrics!(report[name], metric)
        end
    end
    return Dict(
        "reference" => abspath(historical_root),
        "years" => collect(years),
        "variable" => report,
        "all_match" => all(metric["all_match"] for metric in values(report)),
    )
end

function compare_archive_annual(native_output, grid, archive_root; atol, rtol)
    report = Dict(
        name => empty_aggregate(atol, rtol) for
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
                    expected = reference_values(reference, name, grid, Colon())
                    for year_index in axes(expected, 2)
                        days = ((year_index - 1) * 365 + 1):(year_index * 365)
                        actual = annual_point_mean(native[native_name][:, days])
                        metric = casa().error_metrics(
                            scale .* actual,
                            view(expected, :, year_index);
                            atol,
                            rtol,
                        )
                        merge_metrics!(report[name], metric)
                    end
                end
                return Dict(
                    "reference" => abspath(archive_root),
                    "variable" => report,
                    "all_match" =>
                        all(metric["all_match"] for metric in values(report)),
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
    native_days = ((first_year - 1901) * 365 + 1):((last_year - 1900) * 365)
    stem = "$(first_year)_$(last_year)_daily.nc"
    return compare_reference_files(
        native_output,
        joinpath(archive_root, "casaclm_pool_flux_$stem"),
        joinpath(archive_root, "mimics_pool_flux_$stem"),
        grid,
        native_days;
        annual = false,
        atol,
        rtol,
    )
end

function compare_historical_outputs(
    native_output,
    grid,
    reference_root;
    fortran_atol,
    fortran_rtol,
    archive_atol,
    archive_rtol,
)
    fresh_root = joinpath(reference_root, "stages", "03-historical")
    archive_root = joinpath(reference_root, "reference")
    fresh = Dict(
        "tolerance_scope" => "measured Julia-Fresh-Fortran tolerance",
        "annual" => compare_fresh_fortran(
            native_output,
            grid,
            fresh_root,
            1901:2014;
            annual = true,
            atol = fortran_atol,
            rtol = fortran_rtol,
        ),
        "daily" => Dict(
            "1901_1905" => compare_fresh_fortran(
                native_output,
                grid,
                fresh_root,
                1901:1905;
                annual = false,
                atol = fortran_atol,
                rtol = fortran_rtol,
            ),
            "2010_2014" => compare_fresh_fortran(
                native_output,
                grid,
                fresh_root,
                2010:2014;
                annual = false,
                atol = fortran_atol,
                rtol = fortran_rtol,
            ),
        ),
    )
    archive = Dict(
        "tolerance_scope" => "measured Julia-published-archive tolerance",
        "annual" => compare_archive_annual(
            native_output,
            grid,
            archive_root;
            atol = archive_atol,
            rtol = archive_rtol,
        ),
        "daily" => Dict(
            "1901_1905" => compare_archive_window(
                native_output,
                grid,
                archive_root,
                1901,
                1905;
                atol = archive_atol,
                rtol = archive_rtol,
            ),
            "2010_2014" => compare_archive_window(
                native_output,
                grid,
                archive_root,
                2010,
                2014;
                atol = archive_atol,
                rtol = archive_rtol,
            ),
        ),
    )
    return Dict(
        "output" => Dict("records" => 114 * 365),
        "fresh_fortran" => fresh,
        "published_archive" => archive,
    )
end

function process_comparison()
    return Dict(
        process => Dict(
            "native_diagnostics" => variables,
            "formula_regression" => "dual-precision analytical checks in test/standalone/Soil/Biogeochemistry/mimics.jl",
            "reference_scope" => "direct where the Fortran NetCDF exposes the flux; otherwise constrained by boundary and historical pool comparisons",
        ) for (process, variables) in PROCESS_VARIABLES
    )
end

mutable struct CarbonBudgetAccumulator{F}
    area_m2::Vector{Float64}
    area::F
    input_rate::F
    output_rate::F
    input_kg::Dict{Symbol, Float64}
    output_kg::Dict{Symbol, Float64}
end

function CarbonBudgetAccumulator(grid)
    area = getproperty.(grid, :area_m2)
    return CarbonBudgetAccumulator(
        area,
        area,
        zeros(length(area)),
        zeros(length(area)),
        Dict{Symbol, Float64}(),
        Dict{Symbol, Float64}(),
    )
end

function CarbonBudgetAccumulator(grid, domain)
    area_m2 = getproperty.(grid, :area_m2)
    area = casa().scalar_field(domain, area_m2)
    return CarbonBudgetAccumulator(
        area_m2,
        area,
        zero(area),
        zero(area),
        Dict{Symbol, Float64}(),
        Dict{Symbol, Float64}(),
    )
end

function accumulate_budget!(budget, stage, p)
    name = stage.name
    @. budget.input_rate =
        budget.area * getindex(p.casa_plant.carbon_fluxes, 14)
    @. budget.output_rate =
        budget.area * (
            getindex(p.casa_plant.carbon_fluxes, 16) +
            getindex(p.casa_plant.carbon_fluxes, 21) +
            getindex(p.mimics_soil.carbon_fluxes, 9)
        )
    input = sum(parent(budget.input_rate))
    output = sum(parent(budget.output_rate))
    budget.input_kg[name] =
        get(budget.input_kg, name, 0.0) + input * DAY_SECONDS
    budget.output_kg[name] =
        get(budget.output_kg, name, 0.0) + output * DAY_SECONDS
    return nothing
end

function carbon_budget_report(budget, stage, initial_state, final_state, rtol)
    name = stage.name
    start_stock = casa().area_weighted_carbon(initial_state, budget.area_m2)
    stop_stock = casa().area_weighted_carbon(final_state, budget.area_m2)
    input = budget.input_kg[name]
    output = budget.output_kg[name]
    residual = stop_stock - start_stock - (input - output)
    scale = max(abs(stop_stock - start_stock), abs(input), abs(output), 1.0)
    return Dict(
        "start_stock_kg_c" => start_stock,
        "stop_stock_kg_c" => stop_stock,
        "external_input_kg_c" => input,
        "external_output_kg_c" => output,
        "residual_kg_c" => residual,
        "relative_residual" => abs(residual) / scale,
        "rtol" => rtol,
        "close" => abs(residual) <= rtol * scale,
    )
end

function write_report(
    path;
    historical_output,
    stage_budgets,
    boundary_comparison,
    historical_comparison,
)
    report = Dict(
        "schema_version" => 1,
        "issue" => 29,
        "historical_output" => historical_output,
        "boundary_comparison" => boundary_comparison,
        "historical_comparison" => historical_comparison,
        "process_comparison" => process_comparison(),
        "carbon_budget" => Dict(
            "stage" => stage_budgets,
            "all_close" => all(
                get(budget, "close", false) for budget in values(stage_budgets)
            ),
        ),
    )
    open(path, "w") do io
        TOML.print(io, report; sorted = true)
    end
    return path
end

"""Run the pinned prespin, long-spin, and historical MIMICS-C stages."""
function run_case(
    initial_state,
    stages,
    output_root;
    model,
    update_forcing! = (_, _, _) -> nothing,
    before_step! = (_, _, _, _, _) -> nothing,
    after_step! = (_, _, _, _, _) -> nothing,
    diagnostics = mimics_diagnostics(),
    output_eltype = Float64,
    deflatelevel = 0,
    provenance,
    compare_boundary,
    compare_historical,
    carbon_budget,
)
    expected_names = (:prespin, :spin, :historical)
    getproperty.(stages, :name) == expected_names || throw(
        ArgumentError(
            "MIMICS-C stages must be ordered $(join(expected_names, ", "))",
        ),
    )
    stage_results = NamedTuple[]
    stage_budgets = Dict{String, Any}()
    boundary_comparison = Dict{String, Any}()
    current_state = initial_state
    historical_output = ""
    for stage in stages
        stage_root = joinpath(output_root, "stages", String(stage.name))
        result = native_workflow().run_workflow(
            model,
            current_state,
            [stage],
            stage_root;
            update_forcing!,
            before_step!,
            after_step!,
            diagnostics,
            output_eltype,
            deflatelevel,
            provenance = provenance(stage),
        )
        checkpoint = only(result.checkpoints)
        final_state = casa().state_as_initial_state(result.state, model)
        stage_budgets[String(stage.name)] =
            carbon_budget(stage, current_state, final_state)
        boundary_comparison[String(stage.name)] =
            compare_boundary(stage, result)
        push!(stage_results, (; name = stage.name, checkpoint))
        current_state = final_state
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
        boundary_comparison,
        historical_comparison,
    )
    return (; stages = Tuple(stage_results), output = historical_output, report)
end

function gridded_provenance(stage, plant_path, mimics_path, reference_root)
    stage_directory = Dict(
        :prespin => "01-prespin",
        :spin => "02-spin",
        :historical => "03-historical",
    )[stage.name]
    metadata = joinpath(
        reference_root,
        "stages",
        stage_directory,
        "stage_metadata.toml",
    )
    return Dict(
        "model" => "ClimaLand integrated CASA plant and MIMICS carbon-only soil",
        "configuration" => "issue-29 4,263-point gridded reconstruction",
        "pft" => "IGBP 1:18 in pinned grid order",
        "parameter_file" => Dict(
            "source" => abspath(mimics_path),
            "sha256" => native_workflow().sha256sum(mimics_path),
            "casa_source" => abspath(plant_path),
            "casa_sha256" => native_workflow().sha256sum(plant_path),
        ),
        "forcing" => [
            Dict(
                "stage" => String(stage.name),
                "source" => "pinned GSWP3/CLM5 yearly files; manifest $(abspath(metadata))",
                "sha256" => native_workflow().sha256sum(metadata),
            ),
        ],
    )
end

"""
    run_gridded_case(source_root, forcing_root, reference_root, output_root)

Execute issue 29 with the exact setup selected by the issue-23 Fortran
investigation. Fresh-Fortran and published-archive tolerances remain separate.
"""
function run_gridded_case(
    source_root,
    forcing_root,
    reference_root,
    output_root;
    boundary_atol = 5e-3,
    boundary_rtol = 1e-3,
    fortran_atol = 5e-3,
    fortran_rtol = 1e-3,
    archive_atol = 5e-3,
    archive_rtol = 1e-3,
    budget_rtol = 5e-12,
)
    grid_path =
        joinpath(source_root, "GRID_CN", "gridinfo_igbpz_CLM5_GSWP3.csv")
    soil_path = joinpath(source_root, "GRID_CN", "gridinfo_soil_CLM5_GSWP3.csv")
    phenology_path =
        joinpath(source_root, "GRID_CN", "modis_phenology_wtundra.txt")
    plant_path = joinpath(source_root, "GRID_CN", "pftlookup_igbp_updated4.csv")
    mimics_path = joinpath(
        source_root,
        "GRID_CN",
        "MIMICS_mod5_GSWP3_KO4_push",
        "pftlookup_LIDET-MIM-REV_CN_desorb2xKO4_micCN_FI30.csv",
    )
    grid = casa().read_grid(grid_path)
    length(grid) == 4263 || error("Pinned MIMICS-C grid must have 4,263 rows")
    soils = casa().read_soils(soil_path)
    domain = casa().gridded_domain(length(grid))
    buffers = MIMICSBuffers(domain)
    built = build_gridded_model(
        grid,
        soils,
        plant_path,
        mimics_path,
        buffers;
        domain,
    )
    forcing = MIMICSForcing(
        grid,
        soils,
        built.parameters,
        phenology_path,
        forcing_root,
        buffers,
    )
    stages = (
        native_workflow().NativeStage(:prespin, 365, 100; write_output = false),
        native_workflow().NativeStage(
            :spin,
            20 * 365,
            499;
            write_output = false,
        ),
        native_workflow().NativeStage(:historical, 114 * 365, 1),
    )
    boundary_directories = Dict(
        :prespin => "01-prespin",
        :spin => "02-spin",
        :historical => "03-historical",
    )
    compare_boundary(stage, result) = compare_boundary_csv(
        result.state,
        joinpath(
            reference_root,
            "stages",
            boundary_directories[stage.name],
            "casa_final.csv",
        ),
        joinpath(
            reference_root,
            "stages",
            boundary_directories[stage.name],
            "mimics_final.csv",
        );
        atol = boundary_atol,
        rtol = boundary_rtol,
    )
    budget = CarbonBudgetAccumulator(grid, domain)
    npp = AnnualNPPTracker(domain)
    stoichiometry =
        casa().CarbonOnlyPlantStoichiometryTracker(grid, built.parameters)
    plant_points = casa().point_field(
        domain,
        [built.parameters[point.pft] for point in grid],
    )
    fmet_coefficients = (
        built.mimics["fmet_p(1)"],
        built.mimics["fmet_p(2)"],
        built.mimics["fmet_p(3)"],
    )
    set_initial_cache! = ClimaLand.make_set_initial_cache(built.model)
    function update_drivers!(stage, index, time)
        update_forcing!(forcing, stage, index, time)
        casa().apply_stoichiometry!(stoichiometry, stage.name, built.model)
        prepare_annual_npp!(npp, forcing, stage, index)
    end
    function before_step!(stage, _, Y, p, time)
        update_litter_quality!(
            buffers,
            set_initial_cache!,
            plant_points,
            fmet_coefficients,
            Y,
            p,
            time,
        )
    end
    function after_step!(stage, _, Y, p, _)
        accumulate_annual_npp!(npp, p)
        accumulate_budget!(budget, stage, p)
        casa().update_stoichiometry!(stoichiometry, Y)
    end
    function budget_report(stage, initial_state, final_state)
        return carbon_budget_report(
            budget,
            stage,
            initial_state,
            final_state,
            budget_rtol,
        )
    end
    try
        return run_case(
            gridded_initial_state(built.model, grid, built.parameters),
            stages,
            output_root;
            model = built.model,
            update_forcing! = update_drivers!,
            before_step!,
            after_step!,
            output_eltype = Float32,
            deflatelevel = 1,
            provenance = stage -> gridded_provenance(
                stage,
                plant_path,
                mimics_path,
                reference_root,
            ),
            compare_boundary,
            compare_historical = path -> compare_historical_outputs(
                path,
                grid,
                reference_root;
                fortran_atol,
                fortran_rtol,
                archive_atol,
                archive_rtol,
            ),
            carbon_budget = budget_report,
        )
    finally
        close_forcing!(forcing)
    end
end

function synthetic_model(::Type{FT} = Float64) where {FT}
    casa_model = casa().synthetic_model(FT)
    carbon = SoilMIMICS.CarbonParameters{FT}(;
        vmax_slope = ntuple(_ -> zero(FT), 6),
        vmax_intercept = ntuple(_ -> zero(FT), 6),
        vmax_prefactor = ntuple(_ -> zero(FT), 6),
        vmax_modifier = ntuple(_ -> one(FT), 6),
        km_slope = ntuple(_ -> zero(FT), 6),
        km_intercept = ntuple(_ -> zero(FT), 6),
        km_prefactor = ntuple(_ -> one(FT), 6),
        km_modifier = ntuple(_ -> one(FT), 6),
        oxidation_modifier = (one(FT), one(FT)),
        microbial_growth_efficiency = ntuple(_ -> one(FT), 4),
        r_turnover = (zero(FT), zero(FT)),
        k_turnover = (zero(FT), zero(FT)),
        turnover_npp_denominator = one(FT),
        turnover_modifier_minimum = one(FT),
        turnover_modifier_maximum = one(FT),
        r_physical_partition = (zero(FT), zero(FT)),
        k_physical_partition = (zero(FT), zero(FT)),
        r_chemical_partition = (zero(FT), zero(FT), zero(FT)),
        k_chemical_partition = (zero(FT), zero(FT), zero(FT)),
        desorption = (zero(FT), zero(FT)),
        physical_scalar = (one(FT), zero(FT)),
        input_protection = (zero(FT), zero(FT)),
        depth_cm = FT(100),
    )
    parameter_type = SoilMIMICS.MIMICSSoilModelParameters{FT, typeof(carbon)}
    parameters = parameter_type(;
        carbon,
        clay = zero(FT),
        freezing_temperature = FT(273.15),
        cwd_q10 = one(FT),
        cwd_litter_optimum = one(FT),
        cwd_base_rate = zero(FT),
        cwd_respiration_fraction = zero(FT),
    )
    soil = SoilMIMICS.MIMICSSoilModel{FT}(;
        parameters,
        drivers = SoilMIMICS.PrescribedDrivers(
            _ -> FT(280),
            _ -> FT(0.5),
            _ -> zero(FT),
            _ -> zero(FT),
            _ -> zero(FT),
            _ -> zero(FT),
            _ -> FT(0.5),
            _ -> zero(FT),
        ),
        domain = casa_model.casa_plant.domain,
    )
    return ClimaLand.CASAPlantSoilModel{FT}(
        casa_model.casa_plant,
        soil,
        casa_model.coupling,
    )
end

function synthetic_initial_state(model, ::Type{FT} = Float64) where {FT}
    field(values) = casa().two_point_field(model.casa_plant.domain, values, FT)
    zero_field = field((0, 0))
    return (;
        casa_plant = (;
            c_leaf = zero_field,
            c_wood = field((0, 0)),
            c_fine_root = field((0, 0)),
            c_labile = field((0, 0)),
        ),
        mimics_soil = (;
            c_litter_metabolic = field((0, 0)),
            c_litter_structural = field((0, 0)),
            c_litter_cwd = field((0, 0)),
            c_microbe_r = field((0, 0)),
            c_microbe_k = field((0, 0)),
            c_soil_available = field((0, 0)),
            c_soil_chemical = field((0, 0)),
            c_soil_physical = field((0.1, 0)),
        ),
    )
end

function synthetic_historical_comparison(path)
    return NCDatasets.NCDataset(path) do output
        records = size(output["mimics_soil__c_soil_physical"], 2)
        Dict(
            "output" => Dict("records" => records),
            "fresh_fortran" => Dict("all_match" => true),
            "published_archive" => Dict("all_match" => true),
        )
    end
end

function run_synthetic_case(output_root)
    FT = Float64
    model = synthetic_model(FT)
    stages = (
        native_workflow().NativeStage(:prespin, 2, 1; write_output = false),
        native_workflow().NativeStage(:spin, 2, 1; write_output = false),
        native_workflow().NativeStage(:historical, 2, 1),
    )
    compare_boundary(_, result) =
        Dict("all_match" => isfile(only(result.checkpoints)))
    carbon_budget(_, initial_state, final_state) =
        let
            start = casa().area_weighted_carbon(initial_state, [1.0, 1.0])
            stop = casa().area_weighted_carbon(final_state, [1.0, 1.0])
            Dict(
                "close" => start == stop,
                "start_carbon" => start,
                "stop_carbon" => stop,
            )
        end
    provenance(stage) = Dict(
        "model" => "CASA plant and MIMICS carbon-only soil",
        "configuration" => "synthetic two-point acceptance case",
        "pft" => "active and inactive",
        "parameter_file" =>
            Dict("source" => "synthetic", "sha256" => "synthetic"),
        "forcing" => [
            Dict(
                "stage" => String(stage.name),
                "source" => "synthetic",
                "sha256" => "synthetic",
            ),
        ],
    )
    before_step_calls = Ref(0)
    result = run_case(
        synthetic_initial_state(model, FT),
        stages,
        output_root;
        model,
        output_eltype = Float32,
        deflatelevel = 1,
        before_step! = (_, _, _, _, _) -> (before_step_calls[] += 1),
        provenance,
        compare_boundary,
        compare_historical = synthetic_historical_comparison,
        carbon_budget,
    )
    return merge(result, (; before_step_calls = before_step_calls[]))
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 4 || error(
        "usage: native_mimics_c_reconstruction.jl SOURCE_ROOT FORCING_ROOT REFERENCE_ROOT OUTPUT_ROOT",
    )
    TestbedNativeMIMICSCReconstruction.run_gridded_case(ARGS...)
end
