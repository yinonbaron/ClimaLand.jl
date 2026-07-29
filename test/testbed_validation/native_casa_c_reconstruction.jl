if !isdefined(@__MODULE__, :TestbedNativeWorkflow)
    include(joinpath(@__DIR__, "native_workflow.jl"))
end

module TestbedNativeCASACReconstruction

import ClimaComms
import ClimaCore
import ClimaLand
import NCDatasets
import TOML

const PlantCASA = ClimaLand.Vegetation.CASA
const SoilCASA = ClimaLand.Soil.Biogeochemistry.CASA
const DAY_SECONDS = 86400.0
const YEAR_SECONDS = 365DAY_SECONDS
const STOCK_VARIABLES = (
    "cleaf" => (:casa_plant, :c_leaf),
    "cwood" => (:casa_plant, :c_wood),
    "cfroot" => (:casa_plant, :c_fine_root),
    "clitmetb" => (:casa_soil, :c_litter_metabolic),
    "clitstr" => (:casa_soil, :c_litter_structural),
    "clitcwd" => (:casa_soil, :c_litter_cwd),
    "csoilmic" => (:casa_soil, :c_soil_microbial),
    "csoilslow" => (:casa_soil, :c_soil_slow),
    "csoilpass" => (:casa_soil, :c_soil_passive),
)
const FLUX_VARIABLES = (
    "cgpp" => "diagnostic__cgpp",
    "cnpp" => "diagnostic__cnpp",
    "cresp" => "diagnostic__cresp",
    "cLitInptMet" => "diagnostic__c_litter_metabolic_input",
    "cLitInptStruc" => "diagnostic__c_litter_structural_input",
    "cpassInpt" => "diagnostic__c_passive_input",
)

native_workflow() = getfield(parentmodule(@__MODULE__), :TestbedNativeWorkflow)

@inline function structural_litter_diagnostic(
    parameters,
    cwd_tendency,
    cwd_input,
    plant_structural_input,
)
    # The Fortran output folds CWD-to-soil transfer into cLitInptStruc even
    # though that transfer is already represented in the CASA soil equations.
    transfers = SoilCASA.transfer_fractions(
        parameters.transfers,
        parameters.clay,
        parameters.silt,
    )
    cwd_loss = cwd_input - cwd_tendency
    cwd_to_soil =
        (transfers.cwd_to_microbial + transfers.cwd_to_slow) * cwd_loss
    return plant_structural_input + cwd_to_soil
end

function casa_diagnostics(soil_parameters = nothing)
    flux(name, long_name, compute) =
        (; name, long_name, units = "kg C m-2 s-1", compute)
    structural_compute =
        isnothing(soil_parameters) ? ((_, p) -> p.litter_structural_input) :
        (
            (_, p) ->
                structural_litter_diagnostic.(
                    soil_parameters,
                    getindex.(p.casa_soil.carbon_fluxes, 3),
                    p.litter_cwd_input,
                    p.litter_structural_input,
                )
        )
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
            "diagnostic__cresp",
            "heterotrophic respiration",
            (_, p) -> getindex.(p.casa_soil.carbon_fluxes, 7),
        ),
        flux(
            "diagnostic__c_litter_metabolic_input",
            "metabolic litter carbon input",
            (_, p) -> p.litter_metabolic_input,
        ),
        flux(
            "diagnostic__c_litter_structural_input",
            "structural litter carbon input",
            structural_compute,
        ),
        flux(
            "diagnostic__c_passive_input",
            "passive soil carbon input",
            (_, p) -> getindex.(p.casa_soil.carbon_fluxes, 8),
        ),
    )
end

function historical_variables()
    stocks = (
        reference_name => (
            native_name = native_workflow().output_name(component, variable),
            scale = 1000.0,
        ) for (reference_name, (component, variable)) in STOCK_VARIABLES
    )
    fluxes = (
        reference_name =>
            (; native_name = native_name, scale = 1000.0 * DAY_SECONDS) for
        (reference_name, native_name) in FLUX_VARIABLES
    )
    return (stocks..., fluxes...)
end

function parse_rows(path)
    lines = readlines(path)
    header = strip.(split(first(lines), ','))
    return map(Iterators.drop(lines, 1)) do line
        values = strip.(split(line, ','; keepempty = true))
        NamedTuple{Tuple(Symbol.(header))}(Tuple(values[1:length(header)]))
    end
end

function read_grid(path)
    return map(parse_rows(path)) do row
        (;
            cell_id = parse(Int, row.ijcam),
            latitude = parse(Float64, row.lat),
            longitude = parse(Float64, row.lon),
            pft = parse(Int, row.ivt_igbp),
            soil_order = parse(Int, row.iso),
            area_m2 = parse(Float64, row.landarea),
            latitude_index = parse(Int, row.ilat),
            longitude_index = parse(Int, row.ilon),
        )
    end
end

function read_soils(path)
    return Dict(
        parse(Int, row.ijcam) => (;
            clay = parse(Float64, row.clay),
            silt = parse(Float64, row.silt),
            wilting = parse(Float64, row.wwilt),
            field_capacity = parse(Float64, row.wfield),
            porosity = parse(Float64, row.wsat),
        ) for row in parse_rows(path)
    )
end

function parameter_section(path, header; required = true)
    lines = readlines(path)
    header_index = findfirst(line -> startswith(strip(line), header), lines)
    if isnothing(header_index)
        required && error("Parameter section $header was not found")
        return nothing
    end
    rows = Dict{Int, Vector{Float64}}()
    for line in lines[(header_index + 2):(header_index + 19)]
        fields = strip.(split(line, ','; keepempty = true))
        final = findlast(!isempty, fields)
        rows[parse(Int, fields[1])] = map(fields[2:final]) do value
            isempty(value) ? NaN : parse(Float64, value)
        end
    end
    return rows
end

function pft_categories(path)
    rows = native_workflow().pft_categories(path)
    return Dict(
        pft => (
            inactive = category == native_workflow().InactivePFT,
            nonwoody = category != native_workflow().WoodyPFT,
        ) for (pft, category) in rows
    )
end

function read_pft_parameters(path)
    turnover = parameter_section(path, "nv1,Kroot")
    allocation = parameter_section(path, "NV2,Calloc_leaf")
    chemistry = parameter_section(path, "nv3,C:N leaf")
    initial_carbon = parameter_section(path, ",Leaf C")
    initial_nitrogen = parameter_section(path, ",Nleaf")
    initial_phosphorus = parameter_section(path, ",Pleaf")
    plant_stoichiometry = parameter_section(path, ",N/Pleafmin")
    phenology = parameter_section(path, "IGBP:,Tkshed")
    kinetics = parameter_section(path, ",xnpmax,q01soil")
    efficiencies = parameter_section(path, ",xkNlimit_min"; required = false)
    categories = pft_categories(path)
    return Dict(
        pft => (;
            root_coefficient = turnover[pft][1],
            root_depth = turnover[pft][2],
            allocation = Tuple(allocation[pft][1:3]),
            turnover_rates = Tuple(
                index == 8 ?
                inv(
                    YEAR_SECONDS *
                    turnover[pft][index] *
                    (1 - turnover[pft][7]),
                ) : inv(YEAR_SECONDS * turnover[pft][index]) for
                index in (8, 9, 10)
            ),
            maintenance_rates = Tuple(allocation[pft][4:6]) ./ YEAR_SECONDS,
            plant_nitrogen = Tuple(initial_nitrogen[pft][1:3]) ./ 1000,
            plant_nitrogen_ratio = Tuple(inv.(chemistry[pft][1:3])),
            leaf_phosphorus_to_nitrogen = initial_nitrogen[pft][1] > 0 ?
                                          initial_phosphorus[pft][1] /
                                          initial_nitrogen[pft][1] : 0.0,
            leaf_nitrogen_to_phosphorus = plant_stoichiometry[pft][1],
            initial_leaf_phosphorus = initial_phosphorus[pft][1] / 1000,
            labile_loss_rate = inv(YEAR_SECONDS * turnover[pft][17]),
            specific_leaf_area = 1000turnover[pft][18],
            maximum_leaf_area_index = chemistry[pft][19],
            minimum_leaf_area_index = chemistry[pft][20],
            shedding_temperature = phenology[pft][1],
            cold_turnover_maximum = phenology[pft][2] / YEAR_SECONDS,
            cold_turnover_exponent = phenology[pft][3],
            drought_turnover_maximum = phenology[pft][4] / YEAR_SECONDS,
            drought_turnover_exponent = phenology[pft][5],
            q10 = kinetics[pft][2],
            litter_optimum = kinetics[pft][3],
            soil_optimum = kinetics[pft][4],
            litter_rates = Tuple(
                inv(YEAR_SECONDS * turnover[pft][index]) for
                index in (11, 12, 13)
            ),
            soil_rates = Tuple(
                inv(YEAR_SECONDS * turnover[pft][index]) for
                index in (14, 15, 16)
            ),
            lignin_leaf = chemistry[pft][7],
            lignin_wood = chemistry[pft][8],
            lignin_root = chemistry[pft][9],
            nitrogen_fraction_to_litter = Tuple(chemistry[pft][4:6]),
            cues = isnothing(efficiencies) ?
                   (0.45, 0.45, 0.7, 0.4, 0.7, 1.0, 1.0, 0.45) :
                   Tuple(efficiencies[pft][4:11]),
            initial_carbon = Tuple(initial_carbon[pft][1:9]) ./ 1000,
            inactive = categories[pft].inactive,
            nonwoody = categories[pft].nonwoody,
            constant_moisture = pft in (12, 14),
        ) for pft in 1:18
    )
end

function root_fractions(parameters)
    thickness = (0.022, 0.058, 0.154, 0.409, 1.085, 2.872)
    return SoilCASA.legacy_root_fractions(
        parameters.root_coefficient,
        parameters.root_depth,
        thickness,
    )
end

function metabolic_fraction(parameters, organ)
    index = organ == :leaf ? 1 : 3
    lignin = organ == :leaf ? parameters.lignin_leaf : parameters.lignin_root
    lignin_nitrogen =
        inv(parameters.plant_nitrogen_ratio[index]) /
        parameters.nitrogen_fraction_to_litter[index] * lignin
    return max(0.001, 0.75 * (0.85 - 0.013 * lignin_nitrogen))
end

function point_field(domain, values)
    indices = ClimaCore.Fields.zeros(Float64, domain.space.surface)
    vec(parent(indices)) .= eachindex(values)
    table = Tuple(values)
    return ((index) -> table[Int(index)]).(indices)
end

function scalar_field(domain, values)
    field = ClimaCore.Fields.zeros(Float64, domain.space.surface)
    vec(parent(field)) .= values
    return field
end

function gridded_domain(points)
    return ClimaLand.Domains.Plane(;
        xlim = (0.0, Float64(points)),
        ylim = (0.0, 1.0),
        nelements = (points, 1),
        npolynomial = 0,
        context = ClimaComms.context(),
    )
end

mutable struct CarbonOnlyPlantStoichiometry
    nitrogen::Vector{Float64}
    nitrogen_per_carbon::Vector{Float64}
    nitrogen_to_phosphorus::Vector{Float64}
    initial_phosphorus::Vector{Float64}
    phosphorus_to_nitrogen::Vector{Float64}
end

mutable struct CarbonOnlyPlantStoichiometryTracker{S}
    stoichiometry::S
    active_stage::Union{Nothing, Symbol}
end

function CarbonOnlyPlantStoichiometry(grid, parameters)
    nitrogen_per_carbon =
        [parameters[point.pft].plant_nitrogen_ratio[1] for point in grid]
    nitrogen_to_phosphorus =
        [parameters[point.pft].leaf_nitrogen_to_phosphorus for point in grid]
    initial_phosphorus =
        [parameters[point.pft].initial_leaf_phosphorus for point in grid]
    nitrogen = [
        parameters[point.pft].initial_carbon[1] * nitrogen_per_carbon[index] for (index, point) in enumerate(grid)
    ]
    phosphorus_to_nitrogen = [
        nitrogen[index] > 0 ? initial_phosphorus[index] / nitrogen[index] : 0.0 for index in eachindex(nitrogen)
    ]
    return CarbonOnlyPlantStoichiometry(
        nitrogen,
        nitrogen_per_carbon,
        nitrogen_to_phosphorus,
        initial_phosphorus,
        phosphorus_to_nitrogen,
    )
end

function CarbonOnlyPlantStoichiometryTracker(grid, parameters)
    return CarbonOnlyPlantStoichiometryTracker(
        CarbonOnlyPlantStoichiometry(grid, parameters),
        nothing,
    )
end

function reset_stoichiometry!(stoichiometry)
    # A standalone Fortran stage restores carbon only, recomputes N from C,
    # and leaves P at its parameter-table initial value for the first day.
    for index in eachindex(stoichiometry.nitrogen)
        nitrogen = stoichiometry.nitrogen[index]
        stoichiometry.phosphorus_to_nitrogen[index] =
            nitrogen > 0 ? stoichiometry.initial_phosphorus[index] / nitrogen :
            0.0
    end
    return nothing
end

function restore_stoichiometry!(stoichiometry, initial_state)
    leaf_carbon = vec(parent(initial_state.casa_plant.c_leaf))
    for index in eachindex(leaf_carbon)
        stoichiometry.nitrogen[index] =
            max(0.0, leaf_carbon[index]) *
            stoichiometry.nitrogen_per_carbon[index]
    end
    reset_stoichiometry!(stoichiometry)
    return nothing
end

function update_stoichiometry!(stoichiometry, Y)
    leaf_carbon = vec(parent(Y.casa_plant.c_leaf))
    for index in eachindex(leaf_carbon)
        nitrogen =
            max(0.0, leaf_carbon[index]) *
            stoichiometry.nitrogen_per_carbon[index]
        stoichiometry.phosphorus_to_nitrogen[index] =
            nitrogen > 0 ?
            stoichiometry.nitrogen[index] /
            stoichiometry.nitrogen_to_phosphorus[index] / nitrogen : 0.0
        stoichiometry.nitrogen[index] = nitrogen
    end
    return nothing
end

function apply_stoichiometry!(stoichiometry, model)
    field = model.casa_plant.parameters.leaf_phosphorus_to_nitrogen
    vec(parent(field)) .= stoichiometry.phosphorus_to_nitrogen
    return nothing
end

function apply_stoichiometry!(
    tracker::CarbonOnlyPlantStoichiometryTracker,
    stage,
    model,
)
    if tracker.active_stage != stage
        reset_stoichiometry!(tracker.stoichiometry)
        tracker.active_stage = stage
    end
    apply_stoichiometry!(tracker.stoichiometry, model)
    return nothing
end

function update_stoichiometry!(tracker::CarbonOnlyPlantStoichiometryTracker, Y)
    return update_stoichiometry!(tracker.stoichiometry, Y)
end

function soil_parameters(values, soil, pft; passive_rate_multiplier = 1)
    cues = values.cues
    transfers = SoilCASA.CarbonTransferParameters{Float64}(;
        lignin_leaf = values.lignin_leaf,
        lignin_wood = values.lignin_wood,
        cue_metabolic_to_microbial = cues[1],
        cue_structural_to_microbial = cues[2],
        cue_structural_to_slow = cues[3],
        cue_cwd_to_microbial = cues[4],
        cue_cwd_to_slow = cues[5],
        cue_microbial_to_slow = cues[6],
        cue_microbial_to_passive = cues[7],
        cue_slow_to_passive = cues[8],
    )
    return SoilCASA.CASASoilModelParameters{Float64, typeof(transfers)}(;
        q10 = values.q10,
        litter_optimum = values.litter_optimum,
        soil_optimum = values.soil_optimum,
        porosity = soil.porosity,
        clay = soil.clay,
        silt = soil.silt,
        freezing_temperature = 273.15,
        litter_base_rates = values.litter_rates,
        soil_base_rates = Base.setindex(
            values.soil_rates,
            passive_rate_multiplier * values.soil_rates[3],
            3,
        ),
        transfers,
        is_cropland = pft == 12,
        constant_moisture = values.constant_moisture,
    )
end

function build_gridded_model(
    grid,
    soils,
    parameter_path,
    buffers;
    domain = gridded_domain(length(grid)),
    passive_rate_multiplier = 1,
)
    passive_rate_multiplier > 0 ||
        throw(ArgumentError("passive_rate_multiplier must be positive"))
    parameters = read_pft_parameters(parameter_path)
    plant_points = map(grid) do point
        values = parameters[point.pft]
        PlantCASA.CASAPlantModelParameters{Float64}(;
            allocation = values.allocation,
            turnover_rates = values.turnover_rates,
            maintenance_rates = values.maintenance_rates,
            plant_nitrogen = values.plant_nitrogen,
            plant_nitrogen_ratio = values.plant_nitrogen_ratio,
            leaf_phosphorus_to_nitrogen = values.leaf_phosphorus_to_nitrogen,
            labile_loss_rate = values.labile_loss_rate,
            specific_leaf_area = values.specific_leaf_area,
            minimum_leaf_area_index = values.minimum_leaf_area_index,
            maximum_leaf_area_index = values.maximum_leaf_area_index,
            shedding_temperature = values.shedding_temperature,
            cold_turnover_maximum = values.cold_turnover_maximum,
            cold_turnover_exponent = values.cold_turnover_exponent,
            drought_turnover_maximum = values.drought_turnover_maximum,
            drought_turnover_exponent = values.drought_turnover_exponent,
            freezing_temperature = 273.15,
            nonwoody = values.nonwoody,
        )
    end
    plant = PlantCASA.CASAPlantModel{Float64}(;
        parameters = point_field(domain, plant_points),
        drivers = PlantCASA.PrescribedDrivers(
            _ -> buffers.gpp,
            _ -> buffers.air_temperature,
            _ -> buffers.soil_temperature,
            _ -> buffers.water_stress,
            _ -> buffers.phase,
            _ -> 1.0,
            _ -> 0.0,
        ),
        domain,
    )
    soil_points = map(grid) do point
        values = parameters[point.pft]
        soil = soils[point.cell_id]
        soil_parameters(values, soil, point.pft; passive_rate_multiplier)
    end
    soil = SoilCASA.CASASoilModel{Float64}(;
        parameters = point_field(domain, soil_points),
        drivers = SoilCASA.PrescribedDrivers(
            _ -> buffers.soil_temperature,
            _ -> buffers.liquid_water,
            _ -> 0.0,
            _ -> 0.0,
            _ -> 0.0,
        ),
        domain,
    )
    coupling_points = map(grid) do point
        values = parameters[point.pft]
        ClimaLand.LitterCouplingParameters{Float64}(;
            leaf_metabolic_fraction = metabolic_fraction(values, :leaf),
            root_metabolic_fraction = metabolic_fraction(values, :root),
        )
    end
    coupling = point_field(domain, coupling_points)
    return (
        model = ClimaLand.CASAPlantSoilModel{Float64}(plant, soil, coupling),
        parameters,
    )
end

mutable struct GriddedBuffers{F}
    gpp::F
    air_temperature::F
    soil_temperature::F
    water_stress::F
    liquid_water::F
    phase::F
end

function GriddedBuffers(domain)
    fields = ntuple(
        _ -> scalar_field(
            domain,
            zeros(
                length(
                    parent(
                        ClimaCore.Fields.zeros(Float64, domain.space.surface),
                    ),
                ),
            ),
        ),
        6,
    )
    return GriddedBuffers(fields...)
end

function read_phenology(path, grid)
    lines = readlines(path)
    pfts = parse.(Int, split(strip(lines[2]))[1:11])
    greenup = fill(-50, 271, 18)
    fall = fill(367, 271, 18)
    initial = fill(2, 271, 18)
    for (latitude_index, line) in enumerate(lines[3:end])
        values = split(strip(line))
        for (column, pft) in enumerate(pfts)
            greenup[latitude_index, pft] = parse(Int, values[1 + column])
            fall[latitude_index, pft] =
                parse(Int, values[1 + length(pfts) + column])
            initial[latitude_index, pft] =
                parse(Int, values[1 + 2length(pfts) + column])
        end
    end
    return map(grid) do point
        latitude_index =
            clamp(trunc(Int, (79.75 - point.latitude + 0.25) / 0.5) + 1, 1, 271)
        first_day = greenup[latitude_index, point.pft]
        third_day = fall[latitude_index, point.pft]
        second_day = first_day + 14
        fourth_day = third_day + 14
        second_day > 365 && (second_day -= 365)
        fourth_day > 365 && (fourth_day -= 365)
        (;
            initial = initial[latitude_index, point.pft],
            evergreen = point.pft in (1, 2),
            transition = (first_day, second_day, third_day, fourth_day),
        )
    end
end

mutable struct YearForcingCache
    loaded::BitVector
    gpp::Matrix{Float64}
    nitrogen_deposition::Matrix{Float64}
    air_temperature::Matrix{Float64}
    soil_temperature::Matrix{Float64}
    water_stress::Matrix{Float64}
    liquid_water::Matrix{Float64}
end

mutable struct GriddedForcing{P, D, B, N}
    root_fraction::Matrix{Float64}
    field_capacity::Vector{Float64}
    wilting::Vector{Float64}
    longitude_index::Vector{Int}
    latitude_index::Vector{Int}
    active::BitVector
    legacy_single_precision::Bool
    phenology::P
    phase::Vector{Int}
    forcing_root::String
    current_year::Int
    dataset::D
    buffers::B
    nitrogen_deposition::N
    spin_cache::Dict{Int, YearForcingCache}
    transient_year::Int
    transient_cache::YearForcingCache
end

function GriddedForcing(
    grid,
    soils,
    parameters,
    phenology_path,
    forcing_root,
    buffers,
    ;
    nitrogen_deposition = nothing,
    legacy_single_precision = false,
)
    phenology = read_phenology(phenology_path, grid)
    forcing_root = abspath(forcing_root)
    dataset = NCDatasets.NCDataset(joinpath(forcing_root, "met_1901_1901.nc"))
    return GriddedForcing(
        reduce(
            vcat,
            [
                reshape(collect(root_fractions(parameters[p.pft])), 1, :) for
                p in grid
            ],
        ),
        [soils[p.cell_id].field_capacity for p in grid],
        [soils[p.cell_id].wilting for p in grid],
        getproperty.(grid, :longitude_index),
        getproperty.(grid, :latitude_index),
        BitVector(!parameters[p.pft].inactive for p in grid),
        legacy_single_precision,
        phenology,
        getproperty.(phenology, :initial),
        forcing_root,
        1901,
        dataset,
        buffers,
        nitrogen_deposition,
        Dict{Int, YearForcingCache}(),
        0,
        empty_year_cache(length(grid)),
    )
end

function close_forcing!(forcing)
    isopen(forcing.dataset) && close(forcing.dataset)
    forcing.current_year = 0
    return nothing
end

function forcing_year_day(stage, index)
    year = 1901 + (index - 1) ÷ 365
    return year, mod1(index, 365)
end

function update_phenology!(forcing, day)
    for point in eachindex(forcing.phase)
        if forcing.phenology[point].evergreen
            forcing.phase[point] = 2
            continue
        end
        transitions = forcing.phenology[point].transition
        phase = forcing.phase[point]
        start = transitions[mod1(phase, 4)]
        stop = transitions[mod1(phase + 1, 4)]
        duration = stop - start
        duration < 0 && (duration += 365)
        elapsed = day - start
        elapsed < 0 && (elapsed += 365)
        elapsed > duration && (forcing.phase[point] = mod(phase + 1, 4))
    end
    destination = parent(parent(forcing.buffers.phase))
    for point in eachindex(forcing.phase)
        @inbounds destination[point] = forcing.phase[point]
    end
    return nothing
end

function ensure_forcing_year!(forcing, year)
    forcing.current_year == year &&
        isopen(forcing.dataset) &&
        return forcing.dataset
    isopen(forcing.dataset) && close(forcing.dataset)
    path = joinpath(forcing.forcing_root, "met_$(year)_$(year).nc")
    forcing.dataset = NCDatasets.NCDataset(path)
    forcing.current_year = year
    return forcing.dataset
end

function empty_year_cache(points)
    return YearForcingCache(
        falses(365),
        zeros(points, 365),
        zeros(points, 365),
        zeros(points, 365),
        zeros(points, 365),
        zeros(points, 365),
        zeros(points, 365),
    )
end

function year_cache!(forcing, year)
    if year <= 1920
        if haskey(forcing.spin_cache, year)
            return forcing.spin_cache[year]
        end
        cache = empty_year_cache(length(forcing.phase))
        forcing.spin_cache[year] = cache
        return cache
    end
    if forcing.transient_year != year
        forcing.transient_year = year
        forcing.transient_cache = empty_year_cache(length(forcing.phase))
    end
    return forcing.transient_cache
end

"""
    forcing_value(forcing, value)

When requested by a reconstruction, reproduce the legacy NetCDF handoff that
reads every meteorological driver through an explicit `real(4)` array before
assigning it to the model's double-precision forcing arrays.
"""
@inline function forcing_value(forcing, value)
    return forcing.legacy_single_precision ? Float64(Float32(value)) :
           Float64(value)
end

function load_forcing_day!(forcing, cache, year, day)
    cache.loaded[day] && return cache
    dataset = ensure_forcing_year!(forcing, year)
    longitude = forcing.longitude_index
    latitude = forcing.latitude_index
    gpp_grid = dataset["xcgpp"][:, :, day]
    deposition_grid =
        isnothing(forcing.nitrogen_deposition) ? nothing :
        dataset["ndep"][:, :, day]
    air_grid = dataset["xtairk"][:, :, day]
    temperature_grid = dataset["xtsoil"][:, :, :, day]
    moisture_grid = dataset["xmoist"][:, :, :, day]
    for point in eachindex(longitude)
        if forcing.active[point]
            lon = longitude[point]
            lat = latitude[point]
            roots = view(forcing.root_fraction, point, :)
            cache.gpp[point, day] =
                forcing_value(forcing, gpp_grid[lon, lat]) / 1000 / DAY_SECONDS
            isnothing(deposition_grid) || (
                cache.nitrogen_deposition[point, day] =
                    forcing_value(forcing, deposition_grid[lon, lat]) / 1000 / DAY_SECONDS
            )
            cache.air_temperature[point, day] =
                forcing_value(forcing, air_grid[lon, lat])
            temperature = 0.0
            moisture = 0.0
            stress = 0.0
            for layer in eachindex(roots)
                root = roots[layer]
                water = min(
                    forcing.field_capacity[point],
                    forcing_value(forcing, moisture_grid[lon, lat, layer]),
                )
                temperature +=
                    root *
                    forcing_value(forcing, temperature_grid[lon, lat, layer])
                moisture += root * water
                stress +=
                    root * (
                        (water - forcing.wilting[point]) / (
                            forcing.field_capacity[point] -
                            forcing.wilting[point]
                        )
                    )
            end
            cache.soil_temperature[point, day] = temperature
            cache.liquid_water[point, day] = moisture
            cache.water_stress[point, day] = stress
        else
            cache.air_temperature[point, day] = 273.15
            cache.soil_temperature[point, day] = 273.15
        end
    end
    cache.loaded[day] = true
    return cache
end

function copy_forcing_day!(field, values, day)
    destination = parent(parent(field))
    for point in axes(values, 1)
        @inbounds destination[point] = values[point, day]
    end
    return field
end

function update_forcing!(forcing::GriddedForcing, stage, index, _)
    year, day = forcing_year_day(stage, index)
    cache = load_forcing_day!(forcing, year_cache!(forcing, year), year, day)
    copy_forcing_day!(forcing.buffers.gpp, cache.gpp, day)
    copy_forcing_day!(
        forcing.buffers.air_temperature,
        cache.air_temperature,
        day,
    )
    copy_forcing_day!(
        forcing.buffers.soil_temperature,
        cache.soil_temperature,
        day,
    )
    copy_forcing_day!(forcing.buffers.water_stress, cache.water_stress, day)
    copy_forcing_day!(forcing.buffers.liquid_water, cache.liquid_water, day)
    if !isnothing(forcing.nitrogen_deposition)
        copy_forcing_day!(
            forcing.nitrogen_deposition,
            cache.nitrogen_deposition,
            day,
        )
    end
    update_phenology!(forcing, day)
    return nothing
end

function gridded_initial_state(model, grid, parameters)
    values(variable) =
        map(grid) do point
            pft = parameters[point.pft]
            pft.inactive && return 0.0
            carbon = pft.initial_carbon
            variable == :c_leaf && return carbon[1]
            variable == :c_wood && return pft.nonwoody ? 0.0 : carbon[2]
            variable == :c_fine_root && return carbon[3]
            variable == :c_labile && return 0.0
            variable == :c_litter_metabolic && return carbon[4]
            variable == :c_litter_structural && return carbon[5]
            variable == :c_litter_cwd && return pft.nonwoody ? 0.0 : carbon[6]
            variable == :c_soil_microbial && return carbon[7]
            variable == :c_soil_slow && return carbon[8]
            variable == :c_soil_passive && return carbon[9]
            error("Unknown CASA-C state variable $variable")
        end
    field(variable) = scalar_field(model.casa_plant.domain, values(variable))
    return (;
        casa_plant = (;
            c_leaf = field(:c_leaf),
            c_wood = field(:c_wood),
            c_fine_root = field(:c_fine_root),
            c_labile = field(:c_labile),
        ),
        casa_soil = (;
            c_litter_metabolic = field(:c_litter_metabolic),
            c_litter_structural = field(:c_litter_structural),
            c_litter_cwd = field(:c_litter_cwd),
            c_soil_microbial = field(:c_soil_microbial),
            c_soil_slow = field(:c_soil_slow),
            c_soil_passive = field(:c_soil_passive),
        ),
    )
end

function error_metrics(actual, expected; atol = 0.0, rtol = 0.0)
    size(actual) == size(expected) || throw(
        DimensionMismatch(
            "comparison shapes differ: $(size(actual)) != $(size(expected))",
        ),
    )
    maximum_absolute = 0.0
    maximum_relative = 0.0
    failures = 0
    compared = 0
    for (value, reference) in zip(actual, expected)
        compared += 1
        if ismissing(reference) || !isfinite(reference)
            failures += 1
            maximum_absolute = Inf
            maximum_relative = Inf
            continue
        end
        if ismissing(value) || !isfinite(value)
            failures += 1
            maximum_absolute = Inf
            maximum_relative = Inf
            continue
        end
        absolute = abs(value - reference)
        relative =
            iszero(reference) ? (iszero(value) ? 0.0 : Inf) :
            absolute / abs(reference)
        maximum_absolute = max(maximum_absolute, absolute)
        maximum_relative = max(maximum_relative, relative)
        failures += absolute > atol + rtol * abs(reference)
    end
    return Dict(
        "compared_values" => compared,
        "failed_values" => failures,
        "maximum_absolute_error" => maximum_absolute,
        "maximum_relative_error" => maximum_relative,
        "atol" => atol,
        "rtol" => rtol,
        "all_match" => compared > 0 && iszero(failures),
    )
end

function read_boundary_csv(path)
    lines = readlines(path)
    header = strip.(split(first(lines), ','))
    columns = Dict(name => index for (index, name) in enumerate(header))
    data = [strip.(split(line, ',')) for line in lines[2:end]]
    return columns, data
end

const BOUNDARY_VARIABLES = (
    "casapool%clabile" => (:casa_plant, :c_labile),
    "casapool%cplant(LEAF)" => (:casa_plant, :c_leaf),
    "casapool%cplant(WOOD)" => (:casa_plant, :c_wood),
    "casapool%cplant(FROOT)" => (:casa_plant, :c_fine_root),
    "casapool%clitter(METB)" => (:casa_soil, :c_litter_metabolic),
    "casapool%clitter(STR)" => (:casa_soil, :c_litter_structural),
    "casapool%clitter(CWD)" => (:casa_soil, :c_litter_cwd),
    "casapool%csoil(MIC)" => (:casa_soil, :c_soil_microbial),
    "casapool%csoil(SLOW)" => (:casa_soil, :c_soil_slow),
    "casapool%csoil(PASS)" => (:casa_soil, :c_soil_passive),
)

function compare_boundary_csv(Y, path; atol = 0.0, rtol = 0.0)
    columns, data = read_boundary_csv(path)
    metrics = Dict{String, Any}()
    for (reference_name, (component, variable)) in BOUNDARY_VARIABLES
        actual =
            1000 .*
            vec(Array(parent(getproperty(getproperty(Y, component), variable))))
        expected =
            [parse(Float64, row[columns[reference_name]]) for row in data]
        metrics[reference_name] = error_metrics(actual, expected; atol, rtol)
    end
    return Dict(
        "reference" => abspath(path),
        "points" => length(data),
        "variable" => metrics,
        "all_match" => all(metric["all_match"] for metric in values(metrics)),
    )
end

function reference_points(variable, grid, days = Colon())
    values = Array(variable[:, :, days])
    time_length = ndims(values) == 2 ? 1 : size(values, 3)
    flattened = reshape(values, :, time_length)
    indices = [
        point.longitude_index + (point.latitude_index - 1) * size(values, 1) for point in grid
    ]
    return flattened[indices, :]
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

empty_aggregate(atol, rtol) = Dict(
    "compared_values" => 0,
    "failed_values" => 0,
    "maximum_absolute_error" => 0.0,
    "maximum_relative_error" => 0.0,
    "atol" => atol,
    "rtol" => rtol,
    "all_match" => true,
)

function compare_annual(native_output, reference_path, grid; atol, rtol)
    return NCDatasets.NCDataset(native_output) do native
        NCDatasets.NCDataset(reference_path) do reference
            report = Dict{String, Any}()
            for (reference_name, variable) in historical_variables()
                aggregate = empty_aggregate(atol, rtol)
                reference_values =
                    reference_points(reference[reference_name], grid, Colon())
                for year_index in axes(reference_values, 2)
                    days = ((year_index - 1) * 365 + 1):(year_index * 365)
                    native_mean = vec(
                        sum(native[variable.native_name][:, days]; dims = 2) ./ 365,
                    )
                    metric = error_metrics(
                        variable.scale .* native_mean,
                        view(reference_values, :, year_index);
                        atol,
                        rtol,
                    )
                    merge_metrics!(aggregate, metric)
                end
                report[reference_name] = aggregate
            end
            return Dict(
                "reference" => abspath(reference_path),
                "variable" => report,
                "all_match" =>
                    all(metric["all_match"] for metric in values(report)),
            )
        end
    end
end

function compare_daily(
    native_output,
    reference_path,
    grid,
    native_days;
    atol,
    rtol,
)
    return NCDatasets.NCDataset(native_output) do native
        NCDatasets.NCDataset(reference_path) do reference
            report = Dict{String, Any}()
            for (reference_name, variable) in historical_variables()
                actual =
                    variable.scale .*
                    native[variable.native_name][:, native_days]
                expected =
                    reference_points(reference[reference_name], grid, Colon())
                report[reference_name] =
                    error_metrics(actual, expected; atol, rtol)
            end
            return Dict(
                "reference" => abspath(reference_path),
                "variable" => report,
                "all_match" =>
                    all(metric["all_match"] for metric in values(report)),
            )
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
    return NCDatasets.NCDataset(native_output) do native
        report = Dict(
            name => empty_aggregate(atol, rtol) for
            (name, _) in historical_variables()
        )
        for year in years
            path =
                joinpath(historical_root, "casaclm_pool_flux_$(year)_daily.nc")
            NCDatasets.NCDataset(path) do reference
                native_days = ((year - 1901) * 365 + 1):((year - 1900) * 365)
                for (reference_name, variable) in historical_variables()
                    actual = native[variable.native_name][:, native_days]
                    expected = reference_points(
                        reference[reference_name],
                        grid,
                        Colon(),
                    )
                    if annual
                        actual = sum(actual; dims = 2) ./ 365
                        expected = sum(expected; dims = 2) ./ 365
                    end
                    metric = error_metrics(
                        variable.scale .* actual,
                        expected;
                        atol,
                        rtol,
                    )
                    merge_metrics!(report[reference_name], metric)
                end
            end
        end
        return Dict(
            "reference" => abspath(historical_root),
            "years" => collect(years),
            "variable" => report,
            "all_match" =>
                all(metric["all_match"] for metric in values(report)),
        )
    end
end

function compare_historical_outputs(
    native_output,
    grid,
    reference_root;
    atol = 0.0,
    rtol = 1e-3,
)
    archive = joinpath(reference_root, "reference")
    fresh = joinpath(reference_root, "stages", "04-historical")
    annual = compare_annual(
        native_output,
        joinpath(archive, "ann_casaclm_pool_flux_1901_2014.nc"),
        grid;
        atol,
        rtol,
    )
    first = compare_daily(
        native_output,
        joinpath(archive, "casaclm_pool_flux_1901_1905_daily.nc"),
        grid,
        1:(5 * 365);
        atol,
        rtol,
    )
    last = compare_daily(
        native_output,
        joinpath(archive, "casaclm_pool_flux_2010_2014_daily.nc"),
        grid,
        (109 * 365 + 1):(114 * 365);
        atol,
        rtol,
    )
    fresh_annual = compare_fresh_fortran(
        native_output,
        grid,
        fresh,
        1901:2014;
        annual = true,
        atol,
        rtol,
    )
    fresh_first = compare_fresh_fortran(
        native_output,
        grid,
        fresh,
        1901:1905;
        annual = false,
        atol,
        rtol,
    )
    fresh_last = compare_fresh_fortran(
        native_output,
        grid,
        fresh,
        2010:2014;
        annual = false,
        atol,
        rtol,
    )
    return Dict(
        "output" => Dict("records" => 114 * 365),
        "annual" => Dict(
            "fresh_fortran" => fresh_annual,
            "published_archive" => annual,
            "provenance_scope" => "archive postprocessing differences are reported separately",
        ),
        "daily" => Dict(
            "fresh_fortran" =>
                Dict("1901_1905" => fresh_first, "2010_2014" => fresh_last),
            "published_archive" =>
                Dict("1901_1905" => first, "2010_2014" => last),
        ),
    )
end

mutable struct CarbonBudgetAccumulator
    area_m2::Vector{Float64}
    input_kg::Dict{String, Float64}
    output_kg::Dict{String, Float64}
end

CarbonBudgetAccumulator(grid) = CarbonBudgetAccumulator(
    getproperty.(grid, :area_m2),
    Dict{String, Float64}(),
    Dict{String, Float64}(),
)

function accumulate_budget!(budget, stage, _, _, p, _)
    name = String(stage.name)
    plant_fluxes = p.casa_plant.carbon_fluxes
    soil_fluxes = p.casa_soil.carbon_fluxes
    area = budget.area_m2
    gpp = vec(Array(parent(getindex.(plant_fluxes, 14))))
    autotrophic = vec(Array(parent(getindex.(plant_fluxes, 16))))
    labile_loss = vec(Array(parent(getindex.(plant_fluxes, 21))))
    heterotrophic = vec(Array(parent(getindex.(soil_fluxes, 7))))
    budget.input_kg[name] =
        get(budget.input_kg, name, 0.0) + sum(area .* gpp) * DAY_SECONDS
    budget.output_kg[name] =
        get(budget.output_kg, name, 0.0) +
        sum(area .* (autotrophic .+ labile_loss .+ heterotrophic)) * DAY_SECONDS
    return nothing
end

function area_weighted_carbon(state, area)
    total = 0.0
    for component in values(state), variable in propertynames(component)
        startswith(String(variable), "c_") || continue
        total +=
            sum(area .* vec(Array(parent(getproperty(component, variable)))))
    end
    return total
end

function gridded_provenance(stage, parameter_path, reference_root)
    stage_number = Dict(
        :prespin => "01-prespin",
        :accelerated_spin => "02-accelerated_spin",
        :normal_spin => "03-normal_spin",
        :historical => "04-historical",
    )[stage.name]
    metadata =
        joinpath(reference_root, "stages", stage_number, "stage_metadata.toml")
    return Dict(
        "model" => "ClimaLand integrated CASA carbon-only",
        "configuration" => "issue-28 4,263-point gridded reconstruction",
        "pft" => "IGBP 1:18 in pinned grid order",
        "parameter_file" => Dict(
            "source" => abspath(parameter_path),
            "sha256" => native_workflow().sha256sum(parameter_path),
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

Execute issue 28 with the grid and parameter files selected by issue 22.
`reference_root` is the fresh `archive_predecessor` reconstruction directory,
which also contains the separately-provenanced published archive products.
"""
function run_gridded_case(
    source_root,
    forcing_root,
    reference_root,
    output_root;
    boundary_atol = 5e-3,
    boundary_rtol = 1e-3,
    historical_atol = 5e-3,
    historical_rtol = 1e-3,
    budget_rtol = 5e-12,
    boundary_only = false,
)
    grid_path =
        joinpath(source_root, "GRID_CN", "gridinfo_igbpz_CLM5_GSWP3.csv")
    soil_path = joinpath(source_root, "GRID_CN", "gridinfo_soil_CLM5_GSWP3.csv")
    phenology_path =
        joinpath(source_root, "GRID_CN", "modis_phenology_wtundra.txt")
    normal_path =
        joinpath(source_root, "GRID_CN", "pftlookup_igbp_updated4_exud0.csv")
    accelerated_path =
        joinpath(source_root, "GRID_CN", "pftlookup_igbp_updated4_exud0AD.csv")
    grid = read_grid(grid_path)
    length(grid) == 4263 || error("Pinned CASA-C grid must have 4,263 rows")
    soils = read_soils(soil_path)
    domain = gridded_domain(length(grid))
    buffers = GriddedBuffers(domain)
    normal = build_gridded_model(grid, soils, normal_path, buffers; domain)
    accelerated =
        build_gridded_model(grid, soils, accelerated_path, buffers; domain)
    forcing = GriddedForcing(
        grid,
        soils,
        normal.parameters,
        phenology_path,
        forcing_root,
        buffers,
    )
    stages = (
        native_workflow().NativeStage(:prespin, 365, 100; write_output = false),
        native_workflow().NativeStage(
            :accelerated_spin,
            20 * 365,
            499;
            write_output = false,
        ),
        native_workflow().NativeStage(
            :normal_spin,
            20 * 365,
            499;
            write_output = false,
        ),
        native_workflow().NativeStage(
            :historical,
            114 * 365,
            1;
            write_output = !boundary_only,
        ),
    )
    model_for_stage(stage) =
        stage.name == :accelerated_spin ? accelerated.model : normal.model
    parameter_for_stage(stage) =
        stage.name == :accelerated_spin ? accelerated_path : normal_path
    boundary_directories = Dict(
        :prespin => "01-prespin",
        :accelerated_spin => "02-accelerated_spin",
        :normal_spin => "03-normal_spin",
        :historical => "04-historical",
    )
    compare_boundary(stage, result, _) = compare_boundary_csv(
        result.state,
        joinpath(
            reference_root,
            "stages",
            boundary_directories[stage.name],
            "casa_final.csv",
        );
        atol = boundary_atol,
        rtol = boundary_rtol,
    )
    budget = CarbonBudgetAccumulator(grid)
    stoichiometry = CarbonOnlyPlantStoichiometryTracker(grid, normal.parameters)
    function carbon_budget(stage, result, _, _, initial_state, _)
        boundary_only && return Dict("skipped" => "boundary calibration only")
        name = String(stage.name)
        start_stock = area_weighted_carbon(initial_state, budget.area_m2)
        stop_stock = area_weighted_carbon(
            state_as_initial_state(result.state, model_for_stage(stage)),
            budget.area_m2,
        )
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
            "rtol" => budget_rtol,
            "close" => abs(residual) <= budget_rtol * scale,
        )
    end
    try
        return run_case(
            gridded_initial_state(normal.model, grid, normal.parameters),
            stages,
            output_root;
            model_for_stage,
            update_forcing! = function (stage, index, time)
                update_forcing!(forcing, stage, index, time)
                apply_stoichiometry!(
                    stoichiometry,
                    stage.name,
                    model_for_stage(stage),
                )
            end,
            after_step! = boundary_only ?
                          (_, _, Y, _, _) ->
                update_stoichiometry!(stoichiometry, Y) :
                          function (stage, step, Y, p, time)
                accumulate_budget!(budget, stage, step, Y, p, time)
                update_stoichiometry!(stoichiometry, Y)
            end,
            diagnostics = boundary_only ? () :
                          casa_diagnostics(normal.model.casa_soil.parameters),
            provenance = stage -> gridded_provenance(
                stage,
                parameter_for_stage(stage),
                reference_root,
            ),
            compare_boundary,
            compare_historical = boundary_only ?
                                 (_, _) -> Dict(
                "output" => Dict("records" => 0),
                "skipped" => "boundary calibration only",
            ) :
                                 (path, _) -> compare_historical_outputs(
                path,
                grid,
                reference_root;
                atol = historical_atol,
                rtol = historical_rtol,
            ),
            carbon_budget,
        )
    finally
        close_forcing!(forcing)
    end
end

function synthetic_model(::Type{FT} = Float64) where {FT}
    day = FT(86400)
    domain = ClimaLand.Domains.Plane(;
        xlim = FT.((0, 2)),
        ylim = FT.((0, 1)),
        nelements = (2, 1),
        npolynomial = 0,
        context = ClimaComms.context(),
    )
    plant_parameters = PlantCASA.CASAPlantModelParameters{FT}(;
        allocation = (one(FT), zero(FT), zero(FT)),
        turnover_rates = ntuple(_ -> zero(FT), 3),
        maintenance_rates = ntuple(_ -> zero(FT), 3),
        plant_nitrogen = ntuple(_ -> zero(FT), 3),
        leaf_phosphorus_to_nitrogen = one(FT),
        labile_loss_rate = zero(FT),
        specific_leaf_area = one(FT),
        minimum_leaf_area_index = zero(FT),
        maximum_leaf_area_index = one(FT),
        shedding_temperature = zero(FT),
        cold_turnover_maximum = zero(FT),
        cold_turnover_exponent = one(FT),
        drought_turnover_maximum = zero(FT),
        drought_turnover_exponent = one(FT),
        freezing_temperature = FT(273.15),
    )
    plant_drivers = PlantCASA.PrescribedDrivers(
        _ -> zero(FT),
        _ -> FT(280),
        _ -> FT(280),
        _ -> one(FT),
        _ -> zero(FT),
        _ -> one(FT),
        _ -> zero(FT),
    )
    plant = PlantCASA.CASAPlantModel{FT}(;
        parameters = plant_parameters,
        drivers = plant_drivers,
        domain,
    )

    transfers = SoilCASA.CarbonTransferParameters{FT}(;
        lignin_leaf = zero(FT),
        lignin_wood = zero(FT),
        cue_metabolic_to_microbial = one(FT),
        cue_structural_to_microbial = one(FT),
        cue_structural_to_slow = zero(FT),
        cue_cwd_to_microbial = one(FT),
        cue_cwd_to_slow = zero(FT),
        cue_microbial_to_slow = one(FT),
        cue_microbial_to_passive = zero(FT),
        cue_slow_to_passive = zero(FT),
    )
    soil_parameter_type =
        SoilCASA.CASASoilModelParameters{FT, typeof(transfers)}
    soil_parameters = soil_parameter_type(;
        q10 = one(FT),
        litter_optimum = one(FT),
        soil_optimum = one(FT),
        porosity = one(FT),
        clay = zero(FT),
        silt = zero(FT),
        freezing_temperature = FT(273.15),
        litter_base_rates = ntuple(_ -> zero(FT) / day, 3),
        soil_base_rates = ntuple(_ -> zero(FT) / day, 3),
        transfers,
    )
    soil_drivers = SoilCASA.PrescribedDrivers(
        _ -> FT(280),
        _ -> FT(0.5),
        _ -> zero(FT),
        _ -> zero(FT),
        _ -> zero(FT),
    )
    soil = SoilCASA.CASASoilModel{FT}(;
        parameters = soil_parameters,
        drivers = soil_drivers,
        domain,
    )
    coupling = ClimaLand.LitterCouplingParameters{FT}(;
        leaf_metabolic_fraction = FT(0.5),
        root_metabolic_fraction = FT(0.5),
    )
    return ClimaLand.CASAPlantSoilModel{FT}(plant, soil, coupling)
end

function two_point_field(domain, values, ::Type{FT}) where {FT}
    field = ClimaCore.Fields.zeros(FT, domain.space.surface)
    vec(parent(field)) .= FT.(values)
    return field
end

function synthetic_initial_state(model, ::Type{FT} = Float64) where {FT}
    field(values) = two_point_field(model.casa_plant.domain, values, FT)
    return (;
        casa_plant = (;
            c_leaf = field((0, 0)),
            c_wood = field((0, 0)),
            c_fine_root = field((0, 0)),
            c_labile = field((0, 0)),
        ),
        casa_soil = (;
            c_litter_metabolic = field((0, 0)),
            c_litter_structural = field((0, 0)),
            c_litter_cwd = field((0, 0)),
            c_soil_microbial = field((0, 0)),
            c_soil_slow = field((0, 0)),
            c_soil_passive = field((0.1, 0)),
        ),
    )
end

function state_as_initial_state(Y, model)
    components = ClimaLand.land_components(model)
    values = map(components) do component_name
        component = getproperty(model, component_name)
        state = getproperty(Y, component_name)
        variables = ClimaLand.prognostic_vars(component)
        NamedTuple{variables}(
            map(variable -> getproperty(state, variable), variables),
        )
    end
    return NamedTuple{components}(values)
end

function total_carbon(Y, model)
    total = 0.0
    for component_name in ClimaLand.land_components(model)
        component = getproperty(model, component_name)
        state = getproperty(Y, component_name)
        for variable in ClimaLand.prognostic_vars(component)
            startswith(String(variable), "c_") || continue
            total += sum(Array(parent(getproperty(state, variable))))
        end
    end
    return total
end

function synthetic_provenance(stage)
    return Dict(
        "model" => "CASA carbon-only",
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
end

function checkpoint_matches(checkpoint, model, expected_passive)
    Y, _ = ClimaLand.read_checkpoint(checkpoint; model)
    for component_name in ClimaLand.land_components(model)
        component = getproperty(model, component_name)
        state = getproperty(Y, component_name)
        for variable in ClimaLand.prognostic_vars(component)
            values = vec(Array(parent(getproperty(state, variable))))
            expected =
                variable == :c_soil_passive ? expected_passive :
                zeros(length(values))
            values == expected || return false
        end
    end
    return true
end

function save_restored_checkpoint(Y, time, model, output_root)
    directory = joinpath(output_root, "checkpoints", "passive_restoration")
    mkpath(directory)
    ClimaLand.save_checkpoint(Y, time, directory; model)
    return only(
        filter(
            path -> endswith(path, ".hdf5"),
            readdir(directory; join = true),
        ),
    )
end

function write_report(
    path;
    stage_results,
    historical_output,
    passive_restoration,
    stage_budgets,
    nitrogen_stage_budgets,
    workflow_budgets,
    boundary_comparison,
    historical_comparison,
    initialization_comparison,
)
    report = Dict(
        "schema_version" => 1,
        "passive_restoration" => passive_restoration,
        "historical_output" => historical_output,
        "boundary_comparison" => boundary_comparison,
        "historical_comparison" => historical_comparison,
        "carbon_budget" => Dict(
            "stage" => stage_budgets,
            "all_close" => all(
                get(budget, "close", false) for budget in values(stage_budgets)
            ),
        ),
    )
    isnothing(initialization_comparison) ||
        (report["initialization_comparison"] = initialization_comparison)
    if !isnothing(workflow_budgets)
        carbon_workflow = workflow_budgets["carbon"]
        report["carbon_budget"]["workflow"] = carbon_workflow
        report["carbon_budget"]["all_close"] &=
            get(carbon_workflow, "close", false)
    end
    if !isnothing(nitrogen_stage_budgets)
        report["nitrogen_budget"] = Dict(
            "stage" => nitrogen_stage_budgets,
            "all_close" => all(
                get(budget, "close", false) for
                budget in values(nitrogen_stage_budgets)
            ),
        )
        if !isnothing(workflow_budgets)
            nitrogen_workflow = workflow_budgets["nitrogen"]
            report["nitrogen_budget"]["workflow"] = nitrogen_workflow
            report["nitrogen_budget"]["all_close"] &=
                get(nitrogen_workflow, "close", false)
        end
    end
    open(path, "w") do io
        TOML.print(io, report; sorted = true)
    end
    return path
end

function state_snapshot(Y)
    snapshot = Dict{String, Vector{Float64}}()
    for component_name in propertynames(Y)
        component = getproperty(Y, component_name)
        for variable in propertynames(component)
            snapshot[string(component_name, '.', variable)] =
                vec(Array(parent(getproperty(component, variable))))
        end
    end
    return snapshot
end

function restore_passive_carbon!(Y, multiplier)
    before_state = state_snapshot(Y)
    before = before_state["casa_soil.c_soil_passive"]
    Y.casa_soil.c_soil_passive .*= multiplier
    after = vec(Array(parent(Y.casa_soil.c_soil_passive)))
    unaffected = sort!(collect(keys(before_state)))
    deleteat!(unaffected, findfirst(==("casa_soil.c_soil_passive"), unaffected))
    verified = after == multiplier .* before
    return Dict(
        "multiplier" => multiplier,
        "before" => before,
        "after" => after,
        "verified" => verified,
        "carbon" =>
            Dict("before" => before, "after" => after, "verified" => verified),
        "unaffected_fields" => unaffected,
        "unaffected_verified" => all(unaffected) do name
            component_name, variable = Symbol.(split(name, '.'))
            before_state[name] == vec(
                Array(
                    parent(
                        getproperty(getproperty(Y, component_name), variable),
                    ),
                ),
            )
        end,
    )
end

function states_match(first_state, second_state)
    propertynames(first_state) == propertynames(second_state) || return false
    for component_name in propertynames(first_state)
        first_component = getproperty(first_state, component_name)
        second_component = getproperty(second_state, component_name)
        propertynames(first_component) == propertynames(second_component) ||
            return false
        for variable in propertynames(first_component)
            first_values = Array(parent(getproperty(first_component, variable)))
            second_values =
                Array(parent(getproperty(second_component, variable)))
            first_values == second_values || return false
        end
    end
    return true
end

"""
    run_case(initial_state, stages, output_root; ...)

Run the four-stage native CASA-C reconstruction contract. Models may differ by
stage (the accelerated-spin parameter table does), but every stage advances
through the native workflow and round-trips through a native checkpoint.

Boundary and historical comparisons are deliberately supplied by the case:
the tiny acceptance case compares in-memory synthetic references, while the
4,263-point case compares the pinned Fortran CSV and NetCDF artifacts.
"""
function run_case(
    initial_state,
    stages,
    output_root;
    model_for_stage,
    update_forcing! = (_, _, _) -> nothing,
    after_step! = (_, _, _, _, _) -> nothing,
    diagnostics = (),
    provenance,
    compare_boundary,
    compare_historical,
    carbon_budget,
    initialization_comparison = nothing,
    nitrogen_budget = nothing,
    workflow_budget = nothing,
    prepare_stage! = (_, _, _) -> nothing,
    restore_passive! = restore_passive_carbon!,
    passive_multiplier = 10,
    output_eltype = Float64,
    deflatelevel = 0,
)
    expected_names = (:prespin, :accelerated_spin, :normal_spin, :historical)
    getproperty.(stages, :name) == expected_names || throw(
        ArgumentError(
            "CASA-C stages must be ordered $(join(expected_names, ", "))",
        ),
    )
    passive_multiplier > 0 ||
        throw(ArgumentError("passive_multiplier must be positive"))

    stages = (stages...,)
    stage_results = NamedTuple[]
    stage_budgets = Dict{String, Any}()
    nitrogen_stage_budgets =
        isnothing(nitrogen_budget) ? nothing : Dict{String, Any}()
    boundary_comparison = Dict{String, Any}()
    passive_restoration = Dict{String, Any}()
    current_state = initial_state
    historical_output = ""

    for stage in stages
        model = model_for_stage(stage)
        prepare_stage!(stage, current_state, model)
        stage_root = joinpath(output_root, "stages", String(stage.name))
        start_carbon = sum(
            sum(Array(parent(getproperty(component, variable)))) for
            (_, component) in pairs(current_state) for
            variable in propertynames(component) if
            startswith(String(variable), "c_")
        )
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
        checkpoint = only(result.checkpoints)
        stop_carbon = total_carbon(result.state, model)
        stage_budgets[String(stage.name)] = carbon_budget(
            stage,
            result,
            start_carbon,
            stop_carbon,
            current_state,
            model,
        )
        if !isnothing(nitrogen_budget)
            nitrogen_stage_budgets[String(stage.name)] =
                nitrogen_budget(stage, result, current_state, model)
        end
        boundary_comparison[String(stage.name)] =
            compare_boundary(stage, result, model)
        expected_checkpoint_state = state_as_initial_state(result.state, model)
        checkpoint_state, _ = ClimaLand.read_checkpoint(checkpoint; model)
        current_state = state_as_initial_state(checkpoint_state, model)
        checkpoint_roundtrip_verified =
            states_match(expected_checkpoint_state, current_state)
        handoff_checkpoint = checkpoint

        if stage.name == :accelerated_spin
            passive_restoration =
                restore_passive!(result.state, passive_multiplier)
            expected_restored = state_as_initial_state(result.state, model)
            restored = save_restored_checkpoint(
                result.state,
                result.time,
                model,
                output_root,
            )
            restored_state, _ = ClimaLand.read_checkpoint(restored; model)
            current_state = state_as_initial_state(restored_state, model)
            handoff_checkpoint = restored
            passive_restoration["checkpoint_roundtrip_verified"] =
                states_match(expected_restored, current_state)
        elseif stage.name == :historical
            historical_output = result.output
        end
        push!(
            stage_results,
            (;
                name = stage.name,
                checkpoint,
                handoff_checkpoint,
                checkpoint_roundtrip_verified,
                manifest = result.manifest,
                output = result.output,
                model,
            ),
        )
    end

    historical_comparison =
        compare_historical(historical_output, last(stage_results))
    historical_metadata = merge(
        Dict("path" => historical_output),
        get(historical_comparison, "output", Dict{String, Any}()),
    )
    pop!(historical_comparison, "output", nothing)
    workflow_budgets =
        isnothing(workflow_budget) ? nothing :
        workflow_budget(
            stage_budgets,
            nitrogen_stage_budgets,
            passive_restoration,
        )
    report = write_report(
        joinpath(output_root, "reconstruction_report.toml");
        stage_results,
        historical_output = historical_metadata,
        passive_restoration,
        stage_budgets,
        nitrogen_stage_budgets,
        workflow_budgets,
        boundary_comparison,
        historical_comparison,
        initialization_comparison,
    )
    public_results = Tuple(
        (;
            name = result.name,
            checkpoint = result.checkpoint,
            handoff_checkpoint = result.handoff_checkpoint,
            checkpoint_roundtrip_verified = result.checkpoint_roundtrip_verified,
            manifest = result.manifest,
        ) for result in stage_results
    )
    return (;
        stages = public_results,
        output = historical_output,
        report,
        initialization_comparison,
    )
end

function synthetic_historical_comparison(historical_output)
    expected_passive = [1.0, 0.0]
    return NCDatasets.NCDataset(historical_output) do output
        daily = Array(output["casa_soil__c_soil_passive"][:, :])
        Dict(
            "output" => Dict("records" => size(daily, 2)),
            "annual" => Dict(
                "all_match" =>
                    vec(sum(daily; dims = 2) ./ size(daily, 2)) ==
                    expected_passive,
            ),
            "daily" => Dict(
                "all_match" =>
                    daily == repeat(reshape(expected_passive, :, 1), 1, 2),
            ),
        )
    end
end

"""
    run_synthetic_case(output_root)

Exercise `run_case` with two points and two forcing days per stage using the
real native CASA model, ClimaTimeSteppers integration, and checkpoints.
"""
function run_synthetic_case(output_root)
    FT = Float64
    model = synthetic_model(FT)
    stages = (
        native_workflow().NativeStage(:prespin, 2, 1; write_output = false),
        native_workflow().NativeStage(
            :accelerated_spin,
            2,
            1;
            write_output = false,
        ),
        native_workflow().NativeStage(:normal_spin, 2, 1; write_output = false),
        native_workflow().NativeStage(:historical, 2, 1),
    )
    compare_boundary(stage, result, active_model) = Dict(
        "all_match" => checkpoint_matches(
            only(result.checkpoints),
            active_model,
            stage.name in (:prespin, :accelerated_spin) ? [0.1, 0.0] :
            [1.0, 0.0],
        ),
    )
    carbon_budget(_, _, start_carbon, stop_carbon, _, _) = Dict(
        "start_carbon" => start_carbon,
        "stop_carbon" => stop_carbon,
        "absolute_residual" => abs(stop_carbon - start_carbon),
        "close" => abs(stop_carbon - start_carbon) <= 8eps(FT),
    )
    return run_case(
        synthetic_initial_state(model, FT),
        stages,
        output_root;
        model_for_stage = _ -> model,
        diagnostics = casa_diagnostics(),
        provenance = synthetic_provenance,
        compare_boundary,
        compare_historical = (path, _) -> synthetic_historical_comparison(path),
        carbon_budget,
    )
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 4 || error(
        "usage: native_casa_c_reconstruction.jl SOURCE_ROOT FORCING_ROOT REFERENCE_ROOT OUTPUT_ROOT",
    )
    TestbedNativeCASACReconstruction.run_gridded_case(ARGS...)
end
