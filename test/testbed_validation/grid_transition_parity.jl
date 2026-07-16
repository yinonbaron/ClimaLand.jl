module TestbedGridTransitionParity

import ClimaLand
import NCDatasets
import TOML
import Test

const CASA = ClimaLand.Soil.Biogeochemistry.CASA
const MIMICS = ClimaLand.Soil.Biogeochemistry.MIMICS
const DAYS_PER_YEAR = 365.0

function parameter_section(lines, header; required = true)
    header_index = findfirst(line -> startswith(strip(line), header), lines)
    if isnothing(header_index)
        required && error("Parameter section $header was not found")
        return nothing
    end
    rows = Dict{Int, Vector{Float64}}()
    for line in lines[(header_index + 2):(header_index + 19)]
        fields = split(strip(line), ','; keepempty = true)
        id = parse(Int, strip(fields[1]))
        values = strip.(fields[2:end])
        last_value = findlast(!isempty, values)
        isnothing(last_value) && error("Parameter row $id is empty")
        any(isempty, values[1:last_value]) &&
            error("Parameter row $id contains an empty value")
        rows[id] = parse.(Float64, values[1:last_value])
    end
    return rows
end

function read_casa_parameters(path)
    lines = readlines(path)
    turnover = parameter_section(lines, "nv1,Kroot")
    chemistry = parameter_section(lines, "nv3,C:N leaf")
    nutrients = parameter_section(lines, ",N/Cleafmi"; required = false)
    kinetics = parameter_section(lines, ",xnpmax,q01soil")
    efficiencies = parameter_section(lines, ",xkNlimit_min"; required = false)
    return Dict(
        pft => (;
            q10 = kinetics[pft][2],
            litter_optimum = kinetics[pft][3],
            soil_optimum = kinetics[pft][4],
            litter_rates = inv.(DAYS_PER_YEAR .* Tuple(turnover[pft][11:13])),
            soil_rates = inv.(DAYS_PER_YEAR .* Tuple(turnover[pft][14:16])),
            leaf_age = turnover[pft][8],
            fine_root_age = turnover[pft][10],
            carbon_nitrogen = Tuple(chemistry[pft][1:3]),
            plant_carbon_nitrogen_maximum =
                isnothing(nutrients) ? (NaN, NaN, NaN) : Tuple(
                    inv(nutrients[pft][index]) for index in (1, 3, 5)
                ),
            nitrogen_fraction_to_litter = Tuple(chemistry[pft][4:6]),
            lignin_leaf = chemistry[pft][7],
            lignin_wood = chemistry[pft][8],
            lignin_fine_root = chemistry[pft][9],
            cues = isnothing(efficiencies) ?
                   (0.45, 0.45, 0.7, 0.4, 0.7, 1.0, 1.0, 0.45) :
                   Tuple(efficiencies[pft][4:11]),
            is_cropland = pft == 12,
            constant_moisture = pft in (12, 14),
            nitrogen_ratio_minimum = Tuple(inv.(chemistry[pft][16:18])),
            nitrogen_ratio_maximum = Tuple(inv.(chemistry[pft][13:15])),
            limitation_minimum = isnothing(efficiencies) ? NaN :
                                 efficiencies[pft][1],
            limitation_maximum = isnothing(efficiencies) ? NaN :
                                 efficiencies[pft][2],
            maximum_fine_litter = kinetics[pft][7],
            maximum_cwd = kinetics[pft][8],
            nitrogen_loss_fraction = isnothing(nutrients) ? NaN :
                                       nutrients[pft][7],
            nitrogen_leach_fraction = isnothing(nutrients) ? NaN :
                                        10 * nutrients[pft][8] / DAYS_PER_YEAR,
        ) for pft in 1:18
    )
end

function read_mimics_nitrogen_parameters(path)
    values = Dict{String, Float64}()
    for line in readlines(path)
        fields = split(strip(line), ','; keepempty = true)
        length(fields) >= 2 || continue
        value = tryparse(Float64, strip(fields[1]))
        isnothing(value) && continue
        label = strip(fields[2])
        isempty(label) || (values[label] = value)
    end
    density_label = only(
        filter(label -> startswith(label, "densDep"), keys(values)),
    )
    return MIMICS.NitrogenParameters{Float64}(;
        nitrogen_use_efficiency =
            Tuple(values["NUE($index)"] for index in 1:4),
        microbial_carbon_nitrogen_ratio = (values["CNr"], values["CNk"]),
        carbon_nitrogen_modifier = values["cnModNum"],
        mineral_nitrogen_available_fraction = values["fracDINavailMIC"],
        microbial_turnover_density_exponent = values[density_label],
    )
end

function read_mimics_parameters(path)
    values = Dict{String, Float64}()
    for line in readlines(path)
        fields = split(strip(line), ','; keepempty = true)
        length(fields) >= 2 || continue
        value = tryparse(Float64, strip(fields[1]))
        isnothing(value) && continue
        label = strip(fields[2])
        isempty(label) || (values[label] = value)
    end
    tuple_values(prefix, names) =
        Tuple(values["$prefix($name)"] for name in names)
    return MIMICS.CarbonParameters{Float64}(;
        vmax_slope = tuple_values(
            "Vslope",
            ("r1", "r2", "r3", "k1", "k2", "k3"),
        ),
        vmax_intercept = tuple_values(
            "Vint",
            ("r1", "r2", "r3", "k1", "k2", "k3"),
        ),
        vmax_prefactor = ntuple(_ -> values["av(r1)"], 6),
        vmax_modifier = tuple_values(
            "Vmod",
            ("r1", "r2", "r3", "k1", "k2", "k3"),
        ),
        km_slope = tuple_values("Kslope", ("r1", "r2", "r3", "k1", "k2", "k3")),
        km_intercept = tuple_values(
            "Kint",
            ("r1", "r2", "r3", "k1", "k2", "k3"),
        ),
        km_prefactor = tuple_values("ak", ("r1", "r2", "r3", "k1", "k2", "k3")),
        km_modifier = tuple_values(
            "Kmod",
            ("r1", "r2", "r3", "k1", "k2", "k3"),
        ),
        oxidation_modifier = tuple_values("KO", ("1", "2")),
        microbial_growth_efficiency = tuple_values("MGE", ("1", "2", "3", "4")),
        r_turnover = tuple_values("tau_r", ("1", "2")),
        k_turnover = tuple_values("tau_k", ("1", "2")),
        turnover_npp_denominator = values["tauModDenom"],
        turnover_modifier_minimum = values["tauMod_MIN"],
        turnover_modifier_maximum = values["tauMod_MAX"],
        r_physical_partition = tuple_values("fPHYS_r", ("1", "2")),
        k_physical_partition = tuple_values("fPHYS_K", ("1", "2")),
        r_chemical_partition = tuple_values("fCHEM_r", ("1", "2", "3")),
        k_chemical_partition = tuple_values("fCHEM_K", ("1", "2", "3")),
        desorption = tuple_values("fSOM_p", ("1", "2")),
        physical_scalar = tuple_values("phys_scalar", ("1", "2")),
        input_protection = (values["FI(metb)"], values["FI(struc)"]),
        depth_cm = 100.0,
    )
end

function read_soil_parameters(path)
    rows = Dict{Int, NamedTuple}()
    for line in Iterators.drop(readlines(path), 1)
        fields = split(strip(line), ','; keepempty = true)
        cell_id = parse(Int, strip(fields[1]))
        rows[cell_id] = (;
            clay = parse(Float64, strip(fields[5])),
            silt = parse(Float64, strip(fields[6])),
            porosity = parse(Float64, strip(fields[9])),
        )
    end
    return rows
end

function finite_mean(values)
    total = 0.0
    count = 0
    for value in values
        if !ismissing(value) && isfinite(value) && abs(value) < 1e30
            total += Float64(value)
            count += 1
        end
    end
    return iszero(count) ? NaN : total / count
end

function add_selection!(selected, candidate, reason)
    reasons = get!(selected, candidate.cell_id, String[])
    push!(reasons, reason)
    return nothing
end

function select_representative_cells(output_path, soils; maximum_days = 365)
    return NCDatasets.NCDataset(output_path) do output
        days = 1:min(maximum_days, size(output["cgpp"], 3))
        cell_ids = output["cellid"][:, :]
        pfts = output["IGBP_PFT"][:, :]
        missing_mask = output["cellMissing"][:, :]
        gpp = output["cgpp"][:, :, days]
        temperature = output["tsoilC"][:, :, days]
        moisture = output["thetaLiq"][:, :, days]
        candidates = NamedTuple[]
        for index in CartesianIndices(cell_ids)
            cell_id = Int(cell_ids[index])
            haskey(soils, cell_id) || continue
            missing_mask[index] == 0 || continue
            mean_gpp = finite_mean(view(gpp, index[1], index[2], :))
            isfinite(mean_gpp) && mean_gpp > 0 || continue
            push!(
                candidates,
                (;
                    cell_id,
                    lon_index = index[1],
                    lat_index = index[2],
                    pft = Int(pfts[index]),
                    mean_gpp,
                    mean_temperature = finite_mean(
                        view(temperature, index[1], index[2], :),
                    ),
                    mean_moisture = finite_mean(
                        view(moisture, index[1], index[2], :),
                    ),
                    clay = soils[cell_id].clay,
                ),
            )
        end
        isempty(candidates) && error("No productive cells were found")

        selected = Dict{Int, Vector{String}}()
        for pft in sort!(unique(candidate.pft for candidate in candidates))
            pft_cells = filter(candidate -> candidate.pft == pft, candidates)
            candidate = pft_cells[argmax(getproperty.(pft_cells, :mean_gpp))]
            add_selection!(selected, candidate, "maximum mean GPP for PFT $pft")
        end
        for (field, label) in (
            (:mean_temperature, "mean soil temperature"),
            (:mean_moisture, "mean liquid saturation"),
            (:clay, "clay fraction"),
        )
            values = getproperty.(candidates, field)
            add_selection!(
                selected,
                candidates[argmin(values)],
                "minimum $label",
            )
            add_selection!(
                selected,
                candidates[argmax(values)],
                "maximum $label",
            )
        end

        boundary_index = findfirst(==(51), cell_ids)
        if !isnothing(boundary_index)
            boundary = (;
                cell_id = 51,
                lon_index = boundary_index[1],
                lat_index = boundary_index[2],
                pft = Int(pfts[boundary_index]),
                mean_gpp = 0.0,
                mean_temperature = finite_mean(
                    view(temperature, boundary_index[1], boundary_index[2], :),
                ),
                mean_moisture = finite_mean(
                    view(moisture, boundary_index[1], boundary_index[2], :),
                ),
                clay = soils[51].clay,
            )
            add_selection!(selected, boundary, "inactive ice/water boundary")
            push!(candidates, boundary)
        end

        by_id = Dict(candidate.cell_id => candidate for candidate in candidates)
        return map(sort!(collect(keys(selected)))) do cell_id
            merge(by_id[cell_id], (; reasons = selected[cell_id]))
        end
    end
end

relative_error(actual, expected) =
    iszero(expected) ? (iszero(actual) ? 0.0 : Inf) :
    abs(actual - expected) / abs(expected)

function record_error!(metrics, name, actual, expected, cell_id, day)
    absolute = abs(actual - expected)
    relative = relative_error(actual, expected)
    entry = metrics[name]
    if absolute > entry["maximum_absolute_error"]
        entry["maximum_absolute_error"] = absolute
        entry["absolute_error_cell"] = cell_id
        entry["absolute_error_day"] = day
    end
    if relative > entry["maximum_relative_error"]
        entry["maximum_relative_error"] = relative
        entry["relative_error_cell"] = cell_id
        entry["relative_error_day"] = day
    end
    return nothing
end

function casa_transfer_parameters(parameters)
    cues = parameters.cues
    return CASA.CarbonTransferParameters{Float64}(;
        lignin_leaf = parameters.lignin_leaf,
        lignin_wood = parameters.lignin_wood,
        cue_metabolic_to_microbial = cues[1],
        cue_structural_to_microbial = cues[2],
        cue_structural_to_slow = cues[3],
        cue_cwd_to_microbial = cues[4],
        cue_cwd_to_slow = cues[5],
        cue_microbial_to_slow = cues[6],
        cue_microbial_to_passive = cues[7],
        cue_slow_to_passive = cues[8],
    )
end

function read_series(output, name, selection, days)
    values = output[name][selection.lon_index, selection.lat_index, days]
    return Float64.(values)
end

function empty_metric()
    return Dict{String, Any}(
        "maximum_absolute_error" => 0.0,
        "maximum_relative_error" => 0.0,
        "absolute_error_cell" => 0,
        "absolute_error_day" => 0,
        "relative_error_cell" => 0,
        "relative_error_day" => 0,
    )
end

function compare_casa_transitions(
    output_path,
    pft_path,
    soil_path;
    selections = nothing,
    maximum_days = 365,
)
    pft_parameters = read_casa_parameters(pft_path)
    soils = read_soil_parameters(soil_path)
    isnothing(selections) && (
        selections =
            select_representative_cells(output_path, soils; maximum_days)
    )
    pool_names = ("csoilmic", "csoilslow", "csoilpass")
    metrics = Dict(
        "csoilmic" => empty_metric(),
        "csoilslow" => empty_metric(),
        "csoilpass" => empty_metric(),
        "cresp" => empty_metric(),
        "cpassInpt" => empty_metric(),
    )

    NCDatasets.NCDataset(output_path) do output
        last_day = min(maximum_days, size(output["time"], 1))
        days = 1:last_day
        for selection in selections
            parameters = pft_parameters[selection.pft]
            soil = soils[selection.cell_id]
            transfer_parameters = casa_transfer_parameters(parameters)
            transfers = CASA.transfer_fractions(
                transfer_parameters,
                soil.clay,
                soil.silt,
            )
            series = Dict(
                name => read_series(output, name, selection, days) for
                name in (
                    "clitmetb",
                    "clitstr",
                    "clitcwd",
                    "csoilmic",
                    "csoilslow",
                    "csoilpass",
                    "cresp",
                    "cpassInpt",
                    "fT",
                    "fW",
                )
            )
            for day in 2:last_day
                litter = (
                    series["clitmetb"][day - 1],
                    series["clitstr"][day - 1],
                    series["clitcwd"][day - 1],
                )
                next_litter = (
                    series["clitmetb"][day],
                    series["clitstr"][day],
                    series["clitcwd"][day],
                )
                soil_state = (
                    series["csoilmic"][day - 1],
                    series["csoilslow"][day - 1],
                    series["csoilpass"][day - 1],
                )
                next_soil = (
                    series["csoilmic"][day],
                    series["csoilslow"][day],
                    series["csoilpass"][day],
                )
                rates = CASA.decomposition_rates(
                    parameters.litter_optimum *
                    series["fT"][day] *
                    series["fW"][day],
                    parameters.soil_optimum *
                    series["fT"][day] *
                    series["fW"][day],
                    parameters.litter_rates,
                    parameters.soil_rates,
                    parameters.lignin_leaf,
                    soil.clay,
                    soil.silt,
                    parameters.is_cropland,
                )
                litter_inputs = ntuple(
                    index ->
                        next_litter[index] - litter[index] +
                        rates.litter[index] * litter[index],
                    3,
                )
                tendencies = CASA.carbon_tendencies(
                    litter,
                    soil_state,
                    litter_inputs,
                    rates.litter,
                    rates.soil,
                    transfers,
                )
                predicted_soil = soil_state .+ tendencies.soil
                for index in eachindex(pool_names)
                    record_error!(
                        metrics,
                        pool_names[index],
                        predicted_soil[index],
                        next_soil[index],
                        selection.cell_id,
                        day,
                    )
                end
                record_error!(
                    metrics,
                    "cresp",
                    tendencies.heterotrophic_respiration,
                    series["cresp"][day],
                    selection.cell_id,
                    day,
                )
                record_error!(
                    metrics,
                    "cpassInpt",
                    tendencies.passive_input,
                    series["cpassInpt"][day],
                    selection.cell_id,
                    day,
                )
            end
        end
    end

    return Dict(
        "schema_version" => 1,
        "model" => "CASA soil carbon",
        "source_output" => abspath(output_path),
        "source_parameters" => abspath(pft_path),
        "source_soil" => abspath(soil_path),
        "days" => maximum_days,
        "cell_count" => length(selections),
        "transition_count" => length(selections) * (maximum_days - 1),
        "cells" => [
            Dict(
                "cell_id" => selection.cell_id,
                "pft" => selection.pft,
                "lon_index" => selection.lon_index,
                "lat_index" => selection.lat_index,
                "reasons" => selection.reasons,
            ) for selection in selections
        ],
        "metrics" => metrics,
    )
end

function compare_casa_cn_transitions(
    output_path,
    pft_path,
    soil_path;
    selections = nothing,
    maximum_days = 365,
)
    pft_parameters = read_casa_parameters(pft_path)
    soils = read_soil_parameters(soil_path)
    isnothing(selections) && (
        selections =
            select_representative_cells(output_path, soils; maximum_days)
    )
    metric_names = (
        "nsoilmic",
        "nsoilslow",
        "nsoilpass",
        "nMineral",
        "nLitMineralization",
        "nSoilMineralization",
        "nSoilImmob",
        "nNetMineralization",
        "nMinLoss",
        "nMinLeach",
    )
    metrics = Dict(name => empty_metric() for name in metric_names)
    NCDatasets.NCDataset(output_path) do output
        last_day = min(maximum_days, size(output["time"], 1))
        days = 1:last_day
        for selection in selections
            parameters = pft_parameters[selection.pft]
            soil = soils[selection.cell_id]
            transfers = CASA.transfer_fractions(
                casa_transfer_parameters(parameters),
                soil.clay,
                soil.silt,
            )
            names = (
                "clitmetb",
                "clitstr",
                "clitcwd",
                "csoilmic",
                "csoilslow",
                "csoilpass",
                "nlitmetb",
                "nlitstr",
                "nlitcwd",
                "nsoilmic",
                "nsoilslow",
                "nsoilpass",
                "nMineral",
                "nMinDep",
                "nMinFix",
                "nMinUptake",
                "nMinLoss",
                "nMinLeach",
                "nLitMineralization",
                "nSoilMineralization",
                "nSoilImmob",
                "nNetMineralization",
                "fT",
                "fW",
                "tsoilC",
            )
            series = Dict(
                name => read_series(output, name, selection, days) for
                name in names
            )
            selection.mean_gpp > 0 || continue
            for day in 2:last_day
                litter = Tuple(series[name][day - 1] for name in names[1:3])
                soil_carbon =
                    Tuple(series[name][day - 1] for name in names[4:6])
                litter_nitrogen =
                    Tuple(series[name][day - 1] for name in names[7:9])
                soil_nitrogen =
                    Tuple(series[name][day - 1] for name in names[10:12])
                next_litter_nitrogen =
                    Tuple(series[name][day] for name in names[7:9])
                mineral = series["nMineral"][day - 1]
                limitation = CASA.nitrogen_limitation(
                    mineral,
                    parameters.limitation_minimum,
                    parameters.limitation_maximum,
                    litter,
                    parameters.maximum_fine_litter,
                    parameters.maximum_cwd,
                )
                rates = CASA.decomposition_rates(
                    parameters.litter_optimum *
                    series["fT"][day] *
                    series["fW"][day] *
                    limitation,
                    parameters.soil_optimum *
                    series["fT"][day] *
                    series["fW"][day],
                    parameters.litter_rates,
                    parameters.soil_rates,
                    parameters.lignin_leaf,
                    soil.clay,
                    soil.silt,
                    parameters.is_cropland,
                )
                litter_inputs = ntuple(
                    index ->
                        next_litter_nitrogen[index] -
                        litter_nitrogen[index] +
                        rates.litter[index] * litter_nitrogen[index],
                    3,
                )
                ratios = CASA.new_soil_nitrogen_ratios(
                    mineral,
                    parameters.nitrogen_ratio_minimum,
                    parameters.nitrogen_ratio_maximum,
                    parameters.limitation_maximum,
                )
                tendencies = CASA.nitrogen_tendencies(
                    litter,
                    soil_carbon,
                    litter_nitrogen,
                    soil_nitrogen,
                    litter_inputs,
                    rates.litter,
                    rates.soil,
                    transfers,
                    ratios,
                    mineral,
                    series["nMinDep"][day],
                    series["nMinFix"][day],
                    series["nMinUptake"][day],
                    parameters.nitrogen_loss_fraction,
                    parameters.nitrogen_leach_fraction,
                    series["tsoilC"][day] + 273.15,
                    2.0,
                )
                actual_states = (
                    (soil_nitrogen .+ tendencies.soil)...,
                    mineral + tendencies.mineral,
                )
                expected_states = (
                    series["nsoilmic"][day],
                    series["nsoilslow"][day],
                    series["nsoilpass"][day],
                    series["nMineral"][day],
                )
                for (name, actual, expected) in
                    zip(metric_names[1:4], actual_states, expected_states)
                    record_error!(
                        metrics,
                        name,
                        actual,
                        expected,
                        selection.cell_id,
                        day,
                    )
                end
                actual_fluxes = (
                    tendencies.litter_mineralization,
                    tendencies.soil_mineralization,
                    tendencies.soil_immobilization,
                    tendencies.net_mineralization,
                    tendencies.gaseous_loss,
                    tendencies.leaching,
                )
                for (name, actual) in zip(metric_names[5:10], actual_fluxes)
                    record_error!(
                        metrics,
                        name,
                        actual,
                        series[name][day],
                        selection.cell_id,
                        day,
                    )
                end
            end
        end
    end
    return Dict(
        "schema_version" => 1,
        "model" => "CASA soil carbon-nitrogen",
        "source_output" => abspath(output_path),
        "source_parameters" => abspath(pft_path),
        "source_soil" => abspath(soil_path),
        "days" => maximum_days,
        "cell_count" => length(selections),
        "active_cell_count" =>
            count(selection -> selection.mean_gpp > 0, selections),
        "inactive_boundary_cell_count" =>
            count(selection -> selection.mean_gpp <= 0, selections),
        "transition_count" =>
            count(selection -> selection.mean_gpp > 0, selections) *
            (maximum_days - 1),
        "cells" => [
            Dict(
                "cell_id" => selection.cell_id,
                "pft" => selection.pft,
                "lon_index" => selection.lon_index,
                "lat_index" => selection.lat_index,
                "active" => selection.mean_gpp > 0,
                "reasons" => selection.reasons,
            ) for selection in selections
        ],
        "metrics" => metrics,
    )
end

function mimics_litter_quality(mimics, casa, day, parameters)
    leaf_ratio = parameters.carbon_nitrogen[1] * parameters.lignin_leaf
    root_ratio = parameters.carbon_nitrogen[3] * parameters.lignin_fine_root
    wood_ratio = parameters.carbon_nitrogen[2] * parameters.lignin_wood
    leaf_fraction = 0.75 * (0.85 - 0.013 * leaf_ratio)
    root_fraction = 0.75 * (0.85 - 0.013 * root_ratio)
    root_turnover =
        casa["cfroot"][day - 1] / (parameters.fine_root_age * DAYS_PER_YEAR)
    metabolic = mimics["cLitInput_metb"][day]
    structural = mimics["cLitInput_struc"][day]
    leaf_turnover = (metabolic - root_fraction * root_turnover) / leaf_fraction
    cwd_to_structural =
        structural - leaf_turnover * (1 - leaf_fraction) -
        root_turnover * (1 - root_fraction)
    total = leaf_turnover + root_turnover + cwd_to_structural
    lignin_to_nitrogen = min(
        40.0,
        (
            leaf_ratio * leaf_turnover +
            root_ratio * root_turnover +
            wood_ratio * cwd_to_structural
        ) / max(0.001, total),
    )
    return 0.75 * (0.85 - 0.013 * lignin_to_nitrogen)
end

function mimics_model_parameters(carbon, casa_parameters, soil)
    transfer = casa_transfer_parameters(casa_parameters)
    cwd_to_soil =
        transfer.cue_cwd_to_microbial * (1 - transfer.lignin_wood) +
        transfer.cue_cwd_to_slow * transfer.lignin_wood
    parameter_type = MIMICS.MIMICSSoilModelParameters{Float64, typeof(carbon)}
    return parameter_type(;
        carbon,
        clay = soil.clay,
        freezing_temperature = 273.15,
        cwd_q10 = casa_parameters.q10,
        cwd_litter_optimum = casa_parameters.litter_optimum,
        cwd_base_rate = casa_parameters.litter_rates[3] / 86400,
        cwd_respiration_fraction = 1 - cwd_to_soil,
    )
end

function compare_mimics_transitions(
    mimics_output_path,
    casa_output_path,
    mimics_parameter_path,
    casa_parameter_path,
    soil_path;
    selections = nothing,
    maximum_days = 365,
)
    carbon = read_mimics_parameters(mimics_parameter_path)
    casa_parameters = read_casa_parameters(casa_parameter_path)
    soils = read_soil_parameters(soil_path)
    isnothing(selections) && (
        selections = select_representative_cells(
            casa_output_path,
            soils;
            maximum_days,
        )
    )
    state_names = (
        "cLITm",
        "cLITs",
        "clitcwd",
        "cMICr",
        "cMICk",
        "cSOMa",
        "cSOMc",
        "cSOMp",
    )
    metrics = Dict(name => empty_metric() for name in state_names)
    metrics["cHresp"] = empty_metric()
    metrics["fW"] = empty_metric()

    NCDatasets.NCDataset(mimics_output_path) do mimics_output
        NCDatasets.NCDataset(casa_output_path) do casa_output
            last_day = min(maximum_days, size(mimics_output["time"], 1))
            days = 1:last_day
            for selection in selections
                pft = casa_parameters[selection.pft]
                parameters = mimics_model_parameters(
                    carbon,
                    pft,
                    soils[selection.cell_id],
                )
                mimics = Dict(
                    name =>
                        read_series(mimics_output, name, selection, days)
                    for name in (
                        "cLITm",
                        "cLITs",
                        "cMICr",
                        "cMICk",
                        "cSOMa",
                        "cSOMc",
                        "cSOMp",
                        "cHresp",
                        "cLitInput_metb",
                        "cLitInput_struc",
                        "thetaLiq",
                        "thetaFrzn",
                        "fW",
                    )
                )
                casa = Dict(
                    name => read_series(casa_output, name, selection, days)
                    for name in ("clitcwd", "cfroot", "cgpp", "tsoilC")
                )
                annual_npp = sum(casa["cgpp"]) / 2 / 1000
                for day in 2:last_day
                    previous_cwd = casa["clitcwd"][day - 1] / 1000
                    expected_cwd = casa["clitcwd"][day] / 1000
                    temperature = casa["tsoilC"][day] + 273.15
                    liquid = mimics["thetaLiq"][day]
                    frozen = mimics["thetaFrzn"][day]
                    cwd_fraction =
                        pft.litter_optimum *
                        CASA.temperature_factor(pft.q10, temperature, 273.15) *
                        CASA.moisture_factor(liquid, false) *
                        pft.litter_rates[3]
                    cwd_loss = cwd_fraction * previous_cwd
                    cwd_to_structural =
                        (1 - parameters.cwd_respiration_fraction) * cwd_loss
                    cwd_input = expected_cwd - previous_cwd + cwd_loss
                    metabolic_input =
                        mimics["cLitInput_metb"][day] / 1000 / 86400
                    structural_input =
                        (
                            mimics["cLitInput_struc"][day] / 1000 -
                            cwd_to_structural
                        ) / 86400
                    state = (
                        mimics["cLITm"][day - 1] / 1000,
                        mimics["cLITs"][day - 1] / 1000,
                        previous_cwd,
                        mimics["cMICr"][day - 1] / 1000,
                        mimics["cMICk"][day - 1] / 1000,
                        mimics["cSOMa"][day - 1] / 1000,
                        mimics["cSOMc"][day - 1] / 1000,
                        mimics["cSOMp"][day - 1] / 1000,
                    )
                    expected = (
                        mimics["cLITm"][day] / 1000,
                        mimics["cLITs"][day] / 1000,
                        expected_cwd,
                        mimics["cMICr"][day] / 1000,
                        mimics["cMICk"][day] / 1000,
                        mimics["cSOMa"][day] / 1000,
                        mimics["cSOMc"][day] / 1000,
                        mimics["cSOMp"][day] / 1000,
                    )
                    fluxes = MIMICS.combined_carbon_fluxes(
                        parameters,
                        state...,
                        temperature,
                        liquid,
                        frozen,
                        metabolic_input,
                        structural_input,
                        cwd_input / 86400,
                        mimics_litter_quality(mimics, casa, day, pft),
                        annual_npp,
                    )
                    actual = state .+ 86400 .* Tuple(fluxes[1:8])
                    for index in eachindex(state_names)
                        record_error!(
                            metrics,
                            state_names[index],
                            actual[index],
                            expected[index],
                            selection.cell_id,
                            day,
                        )
                    end
                    record_error!(
                        metrics,
                        "cHresp",
                        fluxes[9],
                        mimics["cHresp"][day] / 1000 / 86400,
                        selection.cell_id,
                        day,
                    )
                    if selection.mean_gpp > 0
                        record_error!(
                            metrics,
                            "fW",
                            fluxes[10],
                            mimics["fW"][day],
                            selection.cell_id,
                            day,
                        )
                    end
                end
            end
        end
    end

    return Dict(
        "schema_version" => 1,
        "model" => "MIMICS soil carbon",
        "source_output" => abspath(mimics_output_path),
        "source_casa_output" => abspath(casa_output_path),
        "source_parameters" => abspath(mimics_parameter_path),
        "source_casa_parameters" => abspath(casa_parameter_path),
        "source_soil" => abspath(soil_path),
        "days" => maximum_days,
        "cell_count" => length(selections),
        "transition_count" => length(selections) * (maximum_days - 1),
        "cells" => [
            Dict(
                "cell_id" => selection.cell_id,
                "pft" => selection.pft,
                "lon_index" => selection.lon_index,
                "lat_index" => selection.lat_index,
                "reasons" => selection.reasons,
            ) for selection in selections
        ],
        "metrics" => metrics,
    )
end

function mimics_cn_litter_quality(
    mimics,
    casa,
    day,
    parameters,
    cwd_to_structural,
)
    previous = day - 1
    leaf_ratio =
        min(
            casa["cleaf"][previous] / max(1e-10, casa["nleaf"][previous]),
            parameters.plant_carbon_nitrogen_maximum[1],
        ) / parameters.nitrogen_fraction_to_litter[1] * parameters.lignin_leaf
    root_ratio =
        min(
            casa["cfroot"][previous] / max(1e-10, casa["nfroot"][previous]),
            parameters.plant_carbon_nitrogen_maximum[3],
        ) / parameters.nitrogen_fraction_to_litter[3] *
        parameters.lignin_fine_root
    wood_ratio = parameters.carbon_nitrogen[2] * parameters.lignin_wood
    total_fine_litter =
        mimics["cLitInput_metb"][day] +
        mimics["cLitInput_struc"][day] - cwd_to_structural
    root_turnover =
        casa["cfroot"][previous] /
        (parameters.fine_root_age * DAYS_PER_YEAR)
    leaf_turnover = total_fine_litter - root_turnover
    total = leaf_turnover + root_turnover + cwd_to_structural
    lignin_to_nitrogen = min(
        40.0,
        (
            leaf_ratio * leaf_turnover + root_ratio * root_turnover +
            wood_ratio * cwd_to_structural
        ) / max(0.001, total),
    )
    return 0.75 * (0.85 - 0.013 * lignin_to_nitrogen)
end

function compare_mimics_cn_transitions(
    mimics_output_path,
    casa_output_path,
    mimics_parameter_path,
    casa_parameter_path,
    soil_path;
    selections = nothing,
    maximum_days = 365,
)
    carbon_parameters = read_mimics_parameters(mimics_parameter_path)
    nitrogen_parameters =
        read_mimics_nitrogen_parameters(mimics_parameter_path)
    casa_parameters = read_casa_parameters(casa_parameter_path)
    soils = read_soil_parameters(soil_path)
    isnothing(selections) && (
        selections = select_representative_cells(
            casa_output_path,
            soils;
            maximum_days,
        )
    )
    carbon_names =
        ("cLITm", "cLITs", "cMICr", "cMICk", "cSOMa", "cSOMc", "cSOMp")
    nitrogen_names =
        ("nLITm", "nLITs", "nMICr", "nMICk", "nSOMa", "nSOMc", "nSOMp")
    diagnostic_names = (
        "DIN",
        "cHresp",
        "cOverflow_r",
        "cOverflow_k",
        "nLitMineralization",
        "nSoilMineralization",
        "nSoilImmob",
        "fW",
    )
    metrics = Dict(
        name => empty_metric() for
        name in (carbon_names..., nitrogen_names..., diagnostic_names...)
    )

    NCDatasets.NCDataset(mimics_output_path) do mimics_output
        NCDatasets.NCDataset(casa_output_path) do casa_output
            last_day = min(maximum_days, size(mimics_output["time"], 1))
            days = 1:last_day
            for selection in selections
                selection.mean_gpp > 0 || continue
                pft = casa_parameters[selection.pft]
                soil = soils[selection.cell_id]
                model_parameters =
                    mimics_model_parameters(carbon_parameters, pft, soil)
                mimics = Dict(
                    name =>
                        read_series(mimics_output, name, selection, days) for
                    name in (
                        carbon_names...,
                        nitrogen_names...,
                        "DIN",
                        "cHresp",
                        "cOverflow_r",
                        "cOverflow_k",
                        "cLitInput_metb",
                        "cLitInput_struc",
                        "nLitInput_metb",
                        "nLitInput_struc",
                        "thetaLiq",
                        "thetaFrzn",
                        "fW",
                    )
                )
                casa = Dict(
                    name => read_series(casa_output, name, selection, days) for
                    name in (
                        "clitcwd",
                        "cleaf",
                        "cfroot",
                        "nleaf",
                        "nfroot",
                        "nMineral",
                        "nMinLeach",
                        "nLitMineralization",
                        "nSoilMineralization",
                        "nSoilImmob",
                        "cgpp",
                        "tsoilC",
                    )
                )
                annual_npp = sum(casa["cgpp"]) / 2
                for day in 2:last_day
                    temperature_c = casa["tsoilC"][day]
                    liquid = mimics["thetaLiq"][day]
                    frozen = mimics["thetaFrzn"][day]
                    cwd_fraction =
                        pft.litter_optimum *
                        CASA.temperature_factor(
                            pft.q10,
                            temperature_c + 273.15,
                            273.15,
                        ) *
                        CASA.moisture_factor(liquid, false) *
                        pft.litter_rates[3]
                    cwd_loss = cwd_fraction * casa["clitcwd"][day - 1]
                    cwd_to_structural =
                        (1 - model_parameters.cwd_respiration_fraction) *
                        cwd_loss
                    litter_quality = mimics_cn_litter_quality(
                        mimics,
                        casa,
                        day,
                        pft,
                        cwd_to_structural,
                    )
                    environment = MIMICS.environmental_parameters(
                        carbon_parameters,
                        temperature_c,
                        liquid,
                        frozen,
                        litter_quality,
                        annual_npp,
                        soil.clay,
                    )
                    carbon = ntuple(
                        index -> mimics[carbon_names[index]][day - 1] / 1000,
                        7,
                    )
                    nitrogen = ntuple(
                        index -> mimics[nitrogen_names[index]][day - 1] / 1000,
                        7,
                    )
                    carbon_inputs = (
                        mimics["cLitInput_metb"][day] / 1000,
                        mimics["cLitInput_struc"][day] / 1000,
                    )
                    nitrogen_inputs = (
                        mimics["nLitInput_metb"][day] / 1000,
                        mimics["nLitInput_struc"][day] / 1000,
                    )
                    available_fraction =
                        nitrogen_parameters.mineral_nitrogen_available_fraction
                    mineral_nitrogen =
                        available_fraction * (
                            casa["nMineral"][day - 1] -
                            casa["nMinLeach"][day]
                        ) / 1000
                    mapped = MIMICS.daily_carbon_nitrogen_map(
                        carbon_parameters,
                        nitrogen_parameters,
                        carbon,
                        nitrogen,
                        mineral_nitrogen,
                        carbon_inputs,
                        nitrogen_inputs,
                        environment,
                    )
                    for index in eachindex(carbon_names)
                        record_error!(
                            metrics,
                            carbon_names[index],
                            mapped.carbon[index],
                            mimics[carbon_names[index]][day] / 1000,
                            selection.cell_id,
                            day,
                        )
                        record_error!(
                            metrics,
                            nitrogen_names[index],
                            mapped.nitrogen[index],
                            mimics[nitrogen_names[index]][day] / 1000,
                            selection.cell_id,
                            day,
                        )
                    end
                    record_error!(
                        metrics,
                        "DIN",
                        mapped.mineral_nitrogen,
                        mimics["DIN"][day] / 1000,
                        selection.cell_id,
                        day,
                    )
                    cwd_respiration =
                        model_parameters.cwd_respiration_fraction * cwd_loss /
                        1000
                    for (name, actual, expected) in (
                        (
                            "cHresp",
                            mapped.respiration + cwd_respiration,
                            mimics["cHresp"][day] / 1000,
                        ),
                        (
                            "cOverflow_r",
                            mapped.overflow_r,
                            mimics["cOverflow_r"][day] / 1000,
                        ),
                        (
                            "cOverflow_k",
                            mapped.overflow_k,
                            mimics["cOverflow_k"][day] / 1000,
                        ),
                        (
                            "nLitMineralization",
                            mapped.litter_mineralization,
                            casa["nLitMineralization"][day] / 1000,
                        ),
                        (
                            "nSoilMineralization",
                            mapped.soil_mineralization,
                            casa["nSoilMineralization"][day] / 1000,
                        ),
                        (
                            "nSoilImmob",
                            mapped.immobilization,
                            casa["nSoilImmob"][day] / 1000,
                        ),
                        ("fW", environment.moisture, mimics["fW"][day]),
                    )
                        record_error!(
                            metrics,
                            name,
                            actual,
                            expected,
                            selection.cell_id,
                            day,
                        )
                    end
                end
            end
        end
    end

    active_cells = count(selection -> selection.mean_gpp > 0, selections)
    return Dict(
        "schema_version" => 1,
        "model" => "MIMICS soil carbon-nitrogen",
        "source_output" => abspath(mimics_output_path),
        "source_casa_output" => abspath(casa_output_path),
        "source_parameters" => abspath(mimics_parameter_path),
        "source_casa_parameters" => abspath(casa_parameter_path),
        "source_soil" => abspath(soil_path),
        "days" => maximum_days,
        "cell_count" => length(selections),
        "active_cell_count" => active_cells,
        "inactive_boundary_cell_count" => length(selections) - active_cells,
        "transition_count" => active_cells * (maximum_days - 1),
        "cells" => [
            Dict(
                "cell_id" => selection.cell_id,
                "pft" => selection.pft,
                "lon_index" => selection.lon_index,
                "lat_index" => selection.lat_index,
                "active" => selection.mean_gpp > 0,
                "reasons" => selection.reasons,
            ) for selection in selections
        ],
        "metrics" => metrics,
    )
end

function write_test_parameter_file(path; include_efficiencies = true)
    open(path, "w") do io
        sections = [
            ("nv1,Kroot", fill(1.0, 18)),
            ("nv3,C:N leaf", fill(0.2, 20)),
            (",xnpmax,q01soil", fill(0.4, 10)),
        ]
        include_efficiencies &&
            push!(sections, (",xkNlimit_min", fill(0.45, 11)))
        for (header, values) in sections
            println(io, header)
            println(io, "units")
            for pft in 1:18
                println(io, join((pft, values...), ','))
            end
        end
    end
end

function write_test_mimics_parameter_file(path)
    pairs = Pair{String, Float64}[]
    for prefix in ("Vslope", "Vint", "Vmod", "Kslope", "Kint", "ak", "Kmod")
        for name in ("r1", "r2", "r3", "k1", "k2", "k3")
            push!(pairs, "$prefix($name)" => 1.0)
        end
    end
    append!(
        pairs,
        [
            "av(r1)" => 1.0,
            "KO(1)" => 1.0,
            "KO(2)" => 1.0,
            ("MGE($index)" => 1.0 for index in 1:4)...,
            "tau_r(1)" => 1.0,
            "tau_r(2)" => 1.0,
            "tau_k(1)" => 1.0,
            "tau_k(2)" => 1.0,
            "tauModDenom" => 1.0,
            "tauMod_MIN" => 1.0,
            "tauMod_MAX" => 1.0,
            "fPHYS_r(1)" => 1.0,
            "fPHYS_r(2)" => 1.0,
            "fPHYS_K(1)" => 1.0,
            "fPHYS_K(2)" => 1.0,
            ("fCHEM_r($index)" => 1.0 for index in 1:3)...,
            ("fCHEM_K($index)" => 1.0 for index in 1:3)...,
            "fSOM_p(1)" => 1.0,
            "fSOM_p(2)" => 1.0,
            "phys_scalar(1)" => 1.0,
            "phys_scalar(2)" => 1.0,
            "FI(metb)" => 1.0,
            "FI(struc)" => 1.0,
            ("NUE($index)" => 0.85 for index in 1:4)...,
            "CNr" => 6.0,
            "CNk" => 10.0,
            "cnModNum" => 0.4,
            "fracDINavailMIC" => 0.5,
            "densDep synthetic" => 1.0,
        ],
    )
    open(path, "w") do io
        println(io, "Fixed Parameters")
        for (label, value) in pairs
            println(io, "$value,$label")
        end
    end
end

function write_test_selection_file(path)
    NCDatasets.NCDataset(path, "c") do output
        NCDatasets.defDim(output, "lon", 2)
        NCDatasets.defDim(output, "lat", 2)
        NCDatasets.defDim(output, "time", 2)
        cellid = NCDatasets.defVar(output, "cellid", Int32, ("lon", "lat"))
        pft = NCDatasets.defVar(output, "IGBP_PFT", Int32, ("lon", "lat"))
        missing =
            NCDatasets.defVar(output, "cellMissing", Int32, ("lon", "lat"))
        cellid[:, :] = Int32[1 2; 3 51]
        pft[:, :] = Int32[1 1; 2 17]
        missing[:, :] .= 0
        for (name, values) in (
            ("cgpp", Float32[1, 3, 2, 0, 1, 3, 2, 0]),
            ("tsoilC", Float32[1, 3, 2, 4, 1, 3, 2, 4]),
            ("thetaLiq", Float32[4, 3, 2, 1, 4, 3, 2, 1]),
        )
            variable =
                NCDatasets.defVar(output, name, Float32, ("lon", "lat", "time"))
            variable[:, :, :] = reshape(values, 2, 2, 2)
        end
    end
end

function self_test()
    Test.@testset "grid transition parity tools" begin
        mktempdir() do directory
            parameters_path = joinpath(directory, "parameters.csv")
            write_test_parameter_file(parameters_path)
            parameters = read_casa_parameters(parameters_path)
            Test.@test length(parameters) == 18
            Test.@test parameters[1].q10 == 0.4
            Test.@test parameters[12].is_cropland
            Test.@test !parameters[14].is_cropland
            Test.@test parameters[14].constant_moisture

            legacy_parameters_path =
                joinpath(directory, "legacy_parameters.csv")
            write_test_parameter_file(
                legacy_parameters_path;
                include_efficiencies = false,
            )
            legacy_parameters = read_casa_parameters(legacy_parameters_path)
            Test.@test legacy_parameters[1].cues ==
                       (0.45, 0.45, 0.7, 0.4, 0.7, 1.0, 1.0, 0.45)

            mimics_path = joinpath(directory, "mimics.csv")
            write_test_mimics_parameter_file(mimics_path)
            mimics_parameters = read_mimics_parameters(mimics_path)
            Test.@test mimics_parameters.vmax_slope == ntuple(_ -> 1.0, 6)
            Test.@test mimics_parameters.input_protection == (1.0, 1.0)
            mimics_nitrogen_parameters =
                read_mimics_nitrogen_parameters(mimics_path)
            Test.@test mimics_nitrogen_parameters.nitrogen_use_efficiency ==
                       ntuple(_ -> 0.85, 4)
            nitrogen = mimics_nitrogen_parameters
            microbial_ratios = nitrogen.microbial_carbon_nitrogen_ratio
            Test.@test microbial_ratios == (6.0, 10.0)

            soil_path = joinpath(directory, "soil.csv")
            open(soil_path, "w") do io
                println(io, "id,lat,lon,sand,clay,silt,wwilt,wfield,wsat")
                for cell_id in (1, 2, 3, 51)
                    println(io, "$cell_id,0,0,0.2,0.$cell_id,0.3,0,0,0.4")
                end
            end
            soils = read_soil_parameters(soil_path)
            Test.@test soils[3].clay == 0.3

            output_path = joinpath(directory, "output.nc")
            write_test_selection_file(output_path)
            selected = select_representative_cells(
                output_path,
                soils;
                maximum_days = 2,
            )
            selected_ids = getproperty.(selected, :cell_id)
            Test.@test 2 in selected_ids
            Test.@test 3 in selected_ids
            Test.@test 51 in selected_ids
        end
        Test.@test relative_error(1.0, 1.0) == 0.0
        Test.@test isinf(relative_error(1.0, 0.0))
    end
    return true
end

function main(args)
    isempty(args) && return 2
    report = if first(args) == "casa"
        length(args) in (4, 5) || begin
            println(
                stderr,
                "Usage: julia grid_transition_parity.jl casa " *
                "<casa-output.nc> <casa-parameters.csv> <soil.csv> " *
                "[report.toml]",
            )
            return 2
        end
        compare_casa_transitions(args[2], args[3], args[4])
    elseif first(args) == "casa-cn"
        length(args) in (4, 5) || begin
            println(
                stderr,
                "Usage: julia grid_transition_parity.jl casa-cn " *
                "<casa-output.nc> <casa-parameters.csv> <soil.csv> " *
                "[report.toml]",
            )
            return 2
        end
        compare_casa_cn_transitions(args[2], args[3], args[4])
    elseif first(args) == "mimics"
        length(args) in (6, 7) || begin
            println(
                stderr,
                "Usage: julia grid_transition_parity.jl mimics " *
                "<mimics-output.nc> <casa-output.nc> " *
                "<mimics-parameters.csv> <casa-parameters.csv> <soil.csv> " *
                "[report.toml]",
            )
            return 2
        end
        compare_mimics_transitions(args[2], args[3], args[4], args[5], args[6])
    elseif first(args) == "mimics-cn"
        length(args) in (6, 7) || begin
            println(
                stderr,
                "Usage: julia grid_transition_parity.jl mimics-cn " *
                "<mimics-output.nc> <casa-output.nc> " *
                "<mimics-parameters.csv> <casa-parameters.csv> <soil.csv> " *
                "[report.toml]",
            )
            return 2
        end
        compare_mimics_cn_transitions(
            args[2],
            args[3],
            args[4],
            args[5],
            args[6],
        )
    else
        println(stderr, "Model must be casa, casa-cn, mimics, or mimics-cn")
        return 2
    end
    report_path =
        first(args) in ("casa", "casa-cn") ? get(args, 5, nothing) :
        get(args, 7, nothing)
    if !isnothing(report_path)
        open(report_path, "w") do io
            TOML.print(io, report; sorted = true)
        end
    else
        TOML.print(stdout, report; sorted = true)
    end
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end

end
