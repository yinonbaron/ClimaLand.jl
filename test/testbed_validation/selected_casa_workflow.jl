if !isdefined(@__MODULE__, :TestbedNativeWorkflow)
    include(joinpath(@__DIR__, "native_workflow.jl"))
end
if !isdefined(@__MODULE__, :TestbedNativeCASACReconstruction)
    include(joinpath(@__DIR__, "native_casa_c_reconstruction.jl"))
end
if !isdefined(@__MODULE__, :TestbedSelectedCellFixtures)
    include(joinpath(@__DIR__, "selected_cell_fixtures.jl"))
end
if !isdefined(@__MODULE__, :TestbedReferenceCellComparisons)
    include(joinpath(@__DIR__, "reference_cell_comparisons.jl"))
end

module TestbedSelectedCASAWorkflow

import Dates
import TOML

import NCDatasets

import ClimaLand

const PlantCASA = ClimaLand.Vegetation.CASA
const SoilCASA = ClimaLand.Soil.Biogeochemistry.CASA
native_workflow() = getfield(parentmodule(@__MODULE__), :TestbedNativeWorkflow)
native_casa() =
    getfield(parentmodule(@__MODULE__), :TestbedNativeCASACReconstruction)
native_casa_cn() =
    getfield(parentmodule(@__MODULE__), :TestbedNativeCASACNReconstruction)
reference_cells() =
    getfield(parentmodule(@__MODULE__), :TestbedReferenceCellComparisons)

const REFERENCE_PATH = joinpath(
    @__DIR__,
    "fixtures",
    "selected_cells",
    "complete_casa_workflow.toml",
)

const COMPLETE_STAGES = (
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
    native_workflow().NativeStage(:historical, 114 * 365, 1),
)

const STRUCTURAL_LITTER_CARBON_TO_NITROGEN = 150.0

supported_configurations() = (:carbon_only, :carbon_nitrogen)

canonical_schedule(stages) = Tuple(stages) == COMPLETE_STAGES

function selected_grid(path, cell_ids)
    by_id =
        Dict(point.cell_id => point for point in native_casa().read_grid(path))
    return map(cell_ids) do cell_id
        haskey(by_id, cell_id) || error("Selected cell $cell_id is missing")
        by_id[cell_id]
    end
end

function read_cn_parameters(path; boreal_fixation = false)
    year_seconds = 365 * 86400.0
    base = native_casa().read_pft_parameters(path)
    turnover = native_casa().parameter_section(path, "nv1,Kroot")
    chemistry = native_casa().parameter_section(path, "nv3,C:N leaf")
    nutrients = native_casa().parameter_section(path, ",N/Cleafmi")
    initial_nitrogen = native_casa().parameter_section(path, ",Nleaf")
    kinetics = native_casa().parameter_section(path, ",xnpmax,q01soil")
    efficiencies =
        native_casa().parameter_section(path, ",xkNlimit_min"; required = false)
    return Dict(
        pft => merge(
            base[pft],
            (;
                leaf_phosphorus_to_nitrogen = inv(
                    base[pft].leaf_nitrogen_to_phosphorus,
                ),
                initial_nitrogen = Tuple(initial_nitrogen[pft][1:10]) ./ 1000,
                nitrogen_ratio_minimum = Tuple(
                    nutrients[pft][index] for index in (1, 3, 5)
                ),
                nitrogen_ratio_maximum = Tuple(
                    nutrients[pft][index] for index in (2, 4, 6)
                ),
                structural_litter_nitrogen_ratio = inv(
                    STRUCTURAL_LITTER_CARBON_TO_NITROGEN,
                ),
                soil_nitrogen_ratio_minimum = Tuple(
                    inv.(chemistry[pft][16:18]),
                ),
                soil_nitrogen_ratio_maximum = Tuple(
                    inv.(chemistry[pft][13:15]),
                ),
                limitation_minimum = (
                    isnothing(efficiencies) ? 0.5 : efficiencies[pft][1]
                ) / 1000,
                limitation_maximum = (
                    isnothing(efficiencies) ? 2.0 : efficiencies[pft][2]
                ) / 1000,
                root_exudate_fraction = isnothing(efficiencies) ? 0.0 :
                                        efficiencies[pft][3],
                maximum_fine_litter = kinetics[pft][7] / 1000,
                maximum_cwd = kinetics[pft][8] / 1000,
                nitrogen_loss_threshold = turnover[pft][5] / 1000,
                nitrogen_loss_fraction = nutrients[pft][7],
                nitrogen_leach_rate = 10 * nutrients[pft][8] / year_seconds,
                fixation_rate = (
                    boreal_fixation && pft == 1 ? 0.21 : nutrients[pft][9]
                ) / 1000 / year_seconds,
            ),
        ) for pft in 1:18
    )
end

function build_cn_model(
    grid,
    soils,
    parameter_path,
    buffers,
    nitrogen_deposition;
    domain = native_casa().gridded_domain(length(grid)),
    passive_rate_multiplier = 1,
    boreal_fixation = false,
)
    parameters = read_cn_parameters(parameter_path; boreal_fixation)
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
            root_exudate_fraction = values.root_exudate_fraction,
            nonwoody = values.nonwoody,
        )
    end
    plant_nitrogen_points = map(grid) do point
        values = parameters[point.pft]
        PlantCASA.CASAPlantNitrogenParameters{Float64}(;
            nitrogen_ratio_minimum = values.nitrogen_ratio_minimum,
            nitrogen_ratio_maximum = values.nitrogen_ratio_maximum,
            nitrogen_fraction_to_litter = values.nitrogen_fraction_to_litter,
            lignin_fraction = (
                values.lignin_leaf,
                values.lignin_wood,
                values.lignin_root,
            ),
            wood_lignin_nitrogen_ratio = inv(values.plant_nitrogen_ratio[2]) * values.lignin_wood,
            structural_litter_nitrogen_ratio = values.structural_litter_nitrogen_ratio,
            limitation_minimum = values.limitation_minimum,
            limitation_maximum = values.limitation_maximum,
            mineral_half_saturation = values.limitation_maximum,
            active = !values.inactive,
        )
    end
    plant = PlantCASA.CASAPlantModel{Float64}(;
        configuration = PlantCASA.CarbonNitrogen(),
        parameters = native_casa().point_field(domain, plant_points),
        nitrogen_parameters = native_casa().point_field(
            domain,
            plant_nitrogen_points,
        ),
        drivers = PlantCASA.PrescribedDrivers(
            _ -> buffers.gpp,
            _ -> buffers.air_temperature,
            _ -> buffers.soil_temperature,
            _ -> buffers.water_stress,
            _ -> buffers.phase,
            _ -> 1.0,
            _ -> 0.0,
        ),
        nitrogen_drivers = PlantCASA.NitrogenPrescribedDrivers(
            _ -> 0.0,
            _ -> 0.0,
            _ -> 0.0,
        ),
        domain,
    )
    soil_points = map(grid) do point
        native_casa().soil_parameters(
            parameters[point.pft],
            soils[point.cell_id],
            point.pft;
            passive_rate_multiplier,
        )
    end
    soil_nitrogen_points = map(grid) do point
        values = parameters[point.pft]
        SoilCASA.CASANitrogenParameters{Float64}(;
            limitation_minimum = values.limitation_minimum,
            limitation_maximum = values.limitation_maximum,
            maximum_fine_litter = values.maximum_fine_litter,
            maximum_cwd = values.maximum_cwd,
            soil_nitrogen_ratio_minimum = values.soil_nitrogen_ratio_minimum,
            soil_nitrogen_ratio_maximum = values.soil_nitrogen_ratio_maximum,
            loss_threshold = values.nitrogen_loss_threshold,
            loss_fraction = values.nitrogen_loss_fraction,
            leach_rate = values.nitrogen_leach_rate,
        )
    end
    fixation = native_casa().scalar_field(
        domain,
        [parameters[point.pft].fixation_rate for point in grid],
    )
    soil = SoilCASA.CASASoilModel{Float64}(;
        configuration = SoilCASA.CarbonNitrogen(),
        parameters = native_casa().point_field(domain, soil_points),
        nitrogen_parameters = native_casa().point_field(
            domain,
            soil_nitrogen_points,
        ),
        drivers = SoilCASA.PrescribedDrivers(
            _ -> buffers.soil_temperature,
            _ -> buffers.liquid_water,
            _ -> 0.0,
            _ -> 0.0,
            _ -> 0.0,
        ),
        nitrogen_drivers = SoilCASA.NitrogenPrescribedDrivers(
            _ -> 0.0,
            _ -> 0.0,
            _ -> 0.0,
            _ -> nitrogen_deposition,
            _ -> fixation,
            _ -> 0.0,
        ),
        domain,
    )
    coupling = native_casa().point_field(
        domain,
        map(grid) do point
            values = parameters[point.pft]
            ClimaLand.LitterCouplingParameters{Float64}(;
                leaf_metabolic_fraction = native_casa().metabolic_fraction(
                    values,
                    :leaf,
                ),
                root_metabolic_fraction = native_casa().metabolic_fraction(
                    values,
                    :root,
                ),
            )
        end,
    )
    return (;
        model = ClimaLand.CASAPlantSoilModel{Float64}(plant, soil, coupling),
        parameters,
    )
end

function gridded_cn_initial_state(model, grid, parameter_path)
    point_states = map(grid) do point
        native_workflow().fortran_initial_state(
            parameter_path,
            point.pft;
            soil_model = :casa,
            nutrients = :carbon_nitrogen,
        )
    end
    components = ClimaLand.land_components(model)
    values = map(components) do component_name
        component = getproperty(model, component_name)
        variables = ClimaLand.prognostic_vars(component)
        component_values = map(variables) do variable
            native_casa().scalar_field(
                component.domain,
                [
                    getproperty(getproperty(state, component_name), variable) for state in point_states
                ],
            )
        end
        NamedTuple{variables}(component_values)
    end
    return NamedTuple{components}(values)
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

function quantize_restart_fields!(component)
    for variable in propertynames(component)
        values = parent(getproperty(component, variable))
        for index in eachindex(values)
            values[index] = round(1000 * values[index]; digits = 6) / 1000
        end
    end
    return nothing
end

"""
    quantize_fortran_restart!(state, passive_multiplier = 1)

Apply the legacy CASA `f18.6`-gram restart precision and labile-C reset.
`passive_multiplier` is applied after serialization, matching the accelerated
to normal-spin restart transform.
"""
function quantize_fortran_restart!(state, passive_multiplier = 1)
    passive_multiplier > 0 ||
        throw(ArgumentError("passive multiplier must be positive"))
    passive_carbon = parent(state.casa_soil.c_soil_passive)
    passive_nitrogen = parent(state.casa_soil.n_soil_passive)
    passive_carbon ./= passive_multiplier
    passive_nitrogen ./= passive_multiplier
    quantize_restart_fields!(state.casa_plant)
    quantize_restart_fields!(state.casa_soil)
    passive_carbon .*= passive_multiplier
    passive_nitrogen .*= passive_multiplier
    fill!(parent(state.casa_plant.c_labile), 0)
    return state
end

struct PackedForcing{P, B, F}
    gpp::Matrix{Float64}
    air_temperature::Matrix{Float64}
    soil_temperature::Matrix{Float64}
    liquid_water::Matrix{Float64}
    water_stress::Matrix{Float64}
    nitrogen_deposition::Matrix{Float64}
    active::BitVector
    phenology::P
    phase::Vector{Int}
    buffers::B
    nitrogen_deposition_buffer::F
end

function PackedForcing(
    dataset,
    cell_indices,
    grid,
    soils,
    parameters,
    phenology_path,
    buffers,
    nitrogen_deposition_buffer,
)
    day_seconds = 86400.0
    gpp = permutedims(Float64.(dataset["xcgpp"][:, cell_indices]))
    air_temperature = permutedims(Float64.(dataset["xtairk"][:, cell_indices]))
    deposition = permutedims(Float64.(dataset["ndep"][:, cell_indices]))
    layered_temperature = Float64.(dataset["xtsoil"][:, :, cell_indices])
    layered_moisture = Float64.(dataset["xmoist"][:, :, cell_indices])
    points, days = size(gpp)
    soil_temperature = zeros(points, days)
    liquid_water = zeros(points, days)
    water_stress = zeros(points, days)
    active = BitVector(!parameters[point.pft].inactive for point in grid)
    for point_index in eachindex(grid)
        point = grid[point_index]
        if active[point_index]
            soil = soils[point.cell_id]
            roots = native_casa().root_fractions(parameters[point.pft])
            for day in axes(gpp, 2)
                for layer in eachindex(roots)
                    water = min(
                        soil.field_capacity,
                        layered_moisture[layer, day, point_index],
                    )
                    soil_temperature[point_index, day] +=
                        roots[layer] *
                        layered_temperature[layer, day, point_index]
                    liquid_water[point_index, day] += roots[layer] * water
                    water_stress[point_index, day] +=
                        roots[layer] * (water - soil.wilting) /
                        (soil.field_capacity - soil.wilting)
                end
            end
            gpp[point_index, :] ./= 1000day_seconds
            deposition[point_index, :] ./= 1000day_seconds
        else
            gpp[point_index, :] .= 0
            deposition[point_index, :] .= 0
            air_temperature[point_index, :] .= 273.15
            soil_temperature[point_index, :] .= 273.15
        end
    end
    phenology = native_casa().read_phenology(phenology_path, grid)
    return PackedForcing(
        gpp,
        air_temperature,
        soil_temperature,
        liquid_water,
        water_stress,
        deposition,
        active,
        phenology,
        getproperty.(phenology, :initial),
        buffers,
        nitrogen_deposition_buffer,
    )
end

function update_forcing!(forcing::PackedForcing, _, index, _)
    vec(parent(forcing.buffers.gpp)) .= view(forcing.gpp, :, index)
    vec(parent(forcing.buffers.air_temperature)) .=
        view(forcing.air_temperature, :, index)
    vec(parent(forcing.buffers.soil_temperature)) .=
        view(forcing.soil_temperature, :, index)
    vec(parent(forcing.buffers.liquid_water)) .=
        view(forcing.liquid_water, :, index)
    vec(parent(forcing.buffers.water_stress)) .=
        view(forcing.water_stress, :, index)
    vec(parent(forcing.nitrogen_deposition_buffer)) .=
        view(forcing.nitrogen_deposition, :, index)
    native_casa().update_phenology!(forcing, mod1(index, 365))
    return nothing
end

state_snapshot(Y) = native_casa().state_snapshot(Y)

function cell_values(values, index, cell_count)
    length(values) % cell_count == 0 ||
        throw(DimensionMismatch("reference values do not align with cells"))
    return vec(values)[index:cell_count:end]
end

function comparison_group(name)
    startswith(name, "casa_soil.c_") && return "CASA soil-carbon"
    startswith(name, "casa_soil.n_") && return "CASA soil-nitrogen"
    startswith(name, "casa_plant.n_") && return "CASA plant-nitrogen"
    startswith(name, "diagnostic.") && return "CASA environmental-trajectory"
    startswith(name, "casa_plant.c_") && return "CASA plant-carbon"
    return "CASA other"
end

function failure_record(failure, comparison)
    cell = failure.cell
    return Dict(
        "cell_id" => cell.id,
        "pft" => cell.pft,
        "selection_reasons" => cell.reasons,
        "comparison" => comparison,
        "error" => sprint(showerror, failure.error),
    )
end

function aggregate_metrics(cell_metrics)
    return Dict(
        "compared_values" =>
            sum(metric["compared_values"] for metric in cell_metrics),
        "failed_values" =>
            sum(metric["failed_values"] for metric in cell_metrics),
        "maximum_absolute_error" => maximum(
            metric["maximum_absolute_error"] for metric in cell_metrics
        ),
        "maximum_relative_error" => maximum(
            metric["maximum_relative_error"] for metric in cell_metrics
        ),
        "atol" => first(cell_metrics)["atol"],
        "rtol" => first(cell_metrics)["rtol"],
        "all_match" => all(metric["all_match"] for metric in cell_metrics),
    )
end

failed_metrics() = Dict(
    "compared_values" => 0,
    "failed_values" => 1,
    "maximum_absolute_error" => Inf,
    "maximum_relative_error" => Inf,
    "all_match" => false,
)

function compare_snapshot(
    actual,
    expected,
    tolerance,
    collection,
    reference_indices,
    concurrency_budget,
)
    cells = collection.cells
    cell_count = length(cells)
    reference_cell_count = length(reference_indices.by_id)
    metrics = Dict{String, Any}()
    grouped_names = Dict{String, Vector{String}}()
    for name in sort!(collect(String.(keys(expected))))
        push!(get!(grouped_names, comparison_group(name), String[]), name)
    end

    positions = Dict(cell.id => index for (index, cell) in enumerate(cells))
    group_reports = Dict{String, Any}()
    failures = Dict{String, Any}[]
    for group in sort!(collect(keys(grouped_names)))
        names = grouped_names[group]
        comparison = reference_cells().ReferenceComparison(
            group,
            function (cell, _)
                actual_index = positions[cell.id]
                expected_index = reference_indices.by_id[cell.id]
                cell_metrics = Dict{String, Any}()
                for name in names
                    variable_tolerance =
                        haskey(tolerance, name) ? tolerance[name] : tolerance
                    cell_metrics[name] = native_casa().error_metrics(
                        cell_values(actual[name], actual_index, cell_count),
                        cell_values(
                            expected[name],
                            expected_index,
                            reference_cell_count,
                        );
                        atol = variable_tolerance["atol"],
                        rtol = variable_tolerance["rtol"],
                    )
                end
                all_match = all(
                    metric["all_match"] for metric in values(cell_metrics)
                )
                reference_cells().CellComparison(all_match, cell_metrics)
            end,
        )
        report = reference_cells().run_comparison(
            collection,
            comparison,
            concurrency_budget;
            throw_on_failure = false,
        )
        completed =
            Any[getproperty(result, :value) for result in report.results]
        append!(
            completed,
            Any[
                failure.value for
                failure in report.failures if !isnothing(failure.value)
            ],
        )
        for name in names
            cell_metrics =
                Any[value[name] for value in completed if haskey(value, name)]
            metrics[name] =
                isempty(cell_metrics) ? failed_metrics() :
                aggregate_metrics(cell_metrics)
        end
        append!(failures, failure_record.(report.failures, Ref(group)))
        group_reports[group] = Dict(
            "all_match" => isempty(report.failures),
            "cell_count" =>
                length(report.results) + length(report.failures),
            "seconds" => report.seconds,
            "workers" => report.workers,
        )
    end
    sort!(
        failures;
        by = failure -> (positions[failure["cell_id"]], failure["comparison"]),
    )
    return Dict(
        "variable" => metrics,
        "comparison" => group_reports,
        "cell_failures" => failures,
        "cell_ids" => getproperty.(cells, :id),
        "all_match" =>
            isempty(failures) &&
            all(metric["all_match"] for metric in values(metrics)),
    )
end

function workflow_reference(
    configuration,
    collection;
    path = REFERENCE_PATH,
    comparison_policy = nothing,
)
    isfile(path) ||
        error("Pinned selected-cell CASA reference is missing: $path")
    reference = TOML.parsefile(path)
    reference["schema_version"] == 1 ||
        error("Unsupported selected-cell CASA reference schema")
    configuration_reference = reference["configuration"][String(configuration)]
    if !isnothing(comparison_policy)
        configuration_reference = copy(configuration_reference)
        configuration_reference["tolerance"] = comparison_policy
        if haskey(comparison_policy, "fresh_fortran_annual")
            for source in ("fresh_fortran", "native_julia")
                annual = get(
                    configuration_reference[source],
                    "annual",
                    Dict{String, Any}(),
                )
                isempty(annual) && error(
                    "Pinned CASA-CN reference is missing $source annual reducers",
                )
                required =
                    source == "fresh_fortran" ?
                    Set(("years", "annual_mean", "annual_total")) :
                    Set(("years", "annual_mean", "end_of_year", "annual_total"))
                Set(keys(annual)) == required && all(
                    !isempty(annual[reducer]) for
                    reducer in setdiff(required, Set(("years",)))
                ) || error(
                    "Pinned CASA-CN reference has incomplete $source annual reducers",
                )
                fresh_rules = comparison_policy["fresh_fortran_annual"]
                expected_names =
                    source == "fresh_fortran" ?
                    Dict(
                        reducer => Set(keys(fresh_rules[reducer])) for
                        reducer in ("annual_mean", "annual_total")
                    ) :
                    Dict(
                        "annual_mean" => Set(keys(fresh_rules["annual_mean"])),
                        "end_of_year" => Set(keys(fresh_rules["annual_mean"])),
                        "annual_total" =>
                            Set(keys(fresh_rules["annual_total"])),
                    )
                all(
                    Set(keys(annual[reducer])) == names for
                    (reducer, names) in expected_names
                ) || error(
                    "Pinned CASA-CN reference has incompatible $source annual variables",
                )
            end
            samples = configuration_reference["native_julia"]["historical"]
            length(get(samples, "sample_days", Int[])) == 84 || error(
                "Pinned CASA-CN reference must retain 84 fixed daily samples",
            )
        end
    end
    reference_ids = Int.(reference["cell_ids"])
    by_id = Dict(id => index for (index, id) in enumerate(reference_ids))
    for cell in collection.cells
        haskey(by_id, cell.id) ||
            error("Pinned CASA reference has no cell $(cell.id)")
    end
    provenance = configuration_reference["provenance"]
    isempty(provenance) && error("Pinned CASA reference provenance is missing")
    hashes = [
        String(provenance["native_julia_report_sha256"]),
        String.(values(provenance["fresh_fortran_boundary_sha256"]))...,
    ]
    for name in
        ("fresh_fortran_annual_sha256", "fresh_fortran_calibration_sha256")
        haskey(provenance, name) && push!(hashes, String(provenance[name]))
    end
    all(hash -> length(hash) == 64 && all(isxdigit, hash), hashes) ||
        error("Pinned CASA reference integrity hash is invalid")
    return (;
        reference,
        configuration = configuration_reference,
        indices = (; by_id),
        path,
        provenance,
    )
end

function compare_boundary_reference(
    reference,
    stage,
    Y,
    collection,
    concurrency_budget,
)
    actual = state_snapshot(Y)
    reports = Dict{String, Any}()
    for source in ("fresh_fortran", "native_julia")
        expected =
            reference.configuration[source]["boundary"][String(stage.name)]
        tolerance = reference.configuration["tolerance"]["$(source)_boundary"]
        haskey(tolerance, String(stage.name)) &&
            (tolerance = tolerance[String(stage.name)])
        reports[source] = compare_snapshot(
            actual,
            expected,
            tolerance,
            collection,
            reference.indices,
            concurrency_budget,
        )
    end
    return Dict(
        "reference" => reference.path,
        "provenance" => reference.provenance,
        "source" => reports,
        "all_match" => all(report["all_match"] for report in values(reports)),
    )
end

function compare_initialization_reference(
    reference,
    initial_state,
    collection,
    concurrency_budget,
)
    expected = reference.configuration["native_julia"]["initialization"]
    tolerance =
        reference.configuration["tolerance"]["native_julia_initialization"]
    comparison = compare_snapshot(
        state_snapshot(initial_state),
        expected,
        tolerance,
        collection,
        reference.indices,
        concurrency_budget,
    )
    comparison["reference"] = reference.path
    comparison["provenance"] = reference.provenance
    return comparison
end

function compare_historical_reference(
    reference,
    path,
    collection,
    concurrency_budget,
)
    expected = reference.configuration["native_julia"]["historical"]
    sample_days = Int.(expected["sample_days"])
    tolerance = reference.configuration["tolerance"]["native_julia_historical"]
    variables = Dict(
        name => values for (name, values) in expected if name != "sample_days"
    )
    actual = NCDatasets.NCDataset(path) do output
        Dict(
            name => vec(
                Array(output[replace(name, "." => "__")][:, sample_days]),
            ) for name in keys(variables)
        )
    end
    comparison = compare_snapshot(
        actual,
        variables,
        tolerance,
        collection,
        reference.indices,
        concurrency_budget,
    )
    comparison["sample_days"] = sample_days
    comparison["pfts"] = sort!(unique(getproperty.(collection.cells, :pft)))
    comparison["forcing_regimes"] =
        sort!(unique(vcat(getproperty.(collection.cells, :reasons)...)))
    annual = compare_annual_reference(
        reference,
        path,
        collection,
        concurrency_budget,
    )
    return Dict(
        "output" => Dict("records" => output_records(path)),
        "reference" => reference.path,
        "provenance" => reference.provenance,
        "selected_dates" => comparison,
        "annual" => annual,
        "all_match" => comparison["all_match"] && annual["all_match"],
    )
end

function reduced_annual_values(output, expected)
    values = Dict{String, Any}()
    for reducer in ("annual_mean", "end_of_year", "annual_total")
        variables = get(expected, reducer, Dict{String, Any}())
        reduced = Dict{String, Any}()
        for name in keys(variables)
            native = output[replace(name, "." => "__")]
            reduced[name] = if reducer == "annual_mean"
                vec(
                    hcat(
                        [
                            sum(
                                native[:, ((year - 1) * 365 + 1):(year * 365)];
                                dims = 2,
                            ) ./ 365 for year in 1:114
                        ]...,
                    ),
                )
            elseif reducer == "end_of_year"
                vec(Array(native[:, collect(365:365:(114 * 365))]))
            else
                vec(
                    hcat(
                        [
                            sum(
                                native[:, ((year - 1) * 365 + 1):(year * 365)];
                                dims = 2,
                            ) .* native_casa().DAY_SECONDS for year in 1:114
                        ]...,
                    ),
                )
            end
        end
        isempty(reduced) || (values[reducer] = reduced)
    end
    return values
end

function compare_annual_reference(
    reference,
    path,
    collection,
    concurrency_budget,
)
    reports = Dict{String, Any}()
    NCDatasets.NCDataset(path) do output
        for source in ("fresh_fortran", "native_julia")
            expected = get(
                reference.configuration[source],
                "annual",
                Dict{String, Any}(),
            )
            isempty(expected) && continue
            actual = reduced_annual_values(output, expected)
            reducer_reports = Dict{String, Any}()
            tolerance = reference.configuration["tolerance"]["$(source)_annual"]
            for reducer in keys(actual)
                reducer_tolerance =
                    haskey(tolerance, reducer) ? tolerance[reducer] : tolerance
                reducer_reports[reducer] = compare_snapshot(
                    actual[reducer],
                    expected[reducer],
                    reducer_tolerance,
                    collection,
                    reference.indices,
                    concurrency_budget,
                )
            end
            reports[source] = Dict(
                "reducers" => reducer_reports,
                "all_match" => all(
                    report["all_match"] for report in values(reducer_reports)
                ),
            )
        end
    end
    return Dict(
        "source" => reports,
        "all_match" => all(report["all_match"] for report in values(reports)),
    )
end

function restore_passive_carbon_nitrogen!(Y, multiplier)
    before = state_snapshot(Y)
    Y.casa_soil.c_soil_passive .*= multiplier
    Y.casa_soil.n_soil_passive .*= multiplier
    after = state_snapshot(Y)
    carbon_before = before["casa_soil.c_soil_passive"]
    carbon_after = after["casa_soil.c_soil_passive"]
    nitrogen_before = before["casa_soil.n_soil_passive"]
    nitrogen_after = after["casa_soil.n_soil_passive"]
    unaffected = filter(
        name ->
            name ∉ ("casa_soil.c_soil_passive", "casa_soil.n_soil_passive"),
        collect(keys(before)),
    )
    return Dict(
        "multiplier" => multiplier,
        "verified" =>
            carbon_after == multiplier .* carbon_before &&
            nitrogen_after == multiplier .* nitrogen_before,
        "carbon" => Dict(
            "before" => carbon_before,
            "after" => carbon_after,
            "verified" => carbon_after == multiplier .* carbon_before,
        ),
        "nitrogen" => Dict(
            "before" => nitrogen_before,
            "after" => nitrogen_after,
            "verified" => nitrogen_after == multiplier .* nitrogen_before,
        ),
        "unaffected_fields" => sort!(unaffected),
        "unaffected_verified" =>
            all(name -> before[name] == after[name], unaffected),
    )
end

struct BudgetAccumulator
    area_m2::Vector{Float64}
    carbon_input::Dict{Symbol, Float64}
    carbon_output::Dict{Symbol, Float64}
    carbon_bounded_adjustment::Dict{Symbol, Float64}
    nitrogen_input::Dict{Symbol, Float64}
    nitrogen_output::Dict{Symbol, Float64}
    nitrogen_bounded_adjustment::Dict{Symbol, Float64}
end

BudgetAccumulator(grid) = BudgetAccumulator(
    getproperty.(grid, :area_m2),
    Dict{Symbol, Float64}(),
    Dict{Symbol, Float64}(),
    Dict{Symbol, Float64}(),
    Dict{Symbol, Float64}(),
    Dict{Symbol, Float64}(),
    Dict{Symbol, Float64}(),
)

function accumulate_budget!(budget, configuration, stage, p)
    day_seconds = 86400.0
    name = stage.name
    area = budget.area_m2
    plant_carbon = parent(p.casa_plant.carbon_fluxes)
    soil_carbon = parent(p.casa_soil.carbon_fluxes)
    carbon_input = 0.0
    carbon_output = 0.0
    carbon_adjustment = 0.0
    for point in eachindex(area)
        gpp = plant_carbon[1, 1, 14, point]
        output =
            plant_carbon[1, 1, 16, point] +
            plant_carbon[1, 1, 21, point] +
            soil_carbon[1, 1, 7, point]
        tendency = 0.0
        for index in 1:4
            tendency += plant_carbon[1, 1, index, point]
        end
        for index in 1:6
            tendency += soil_carbon[1, 1, index, point]
        end
        carbon_input += area[point] * gpp
        carbon_output += area[point] * output
        carbon_adjustment += area[point] * (tendency - (gpp - output))
    end
    budget.carbon_input[name] =
        get(budget.carbon_input, name, 0.0) + carbon_input * day_seconds
    budget.carbon_output[name] =
        get(budget.carbon_output, name, 0.0) + carbon_output * day_seconds
    budget.carbon_bounded_adjustment[name] =
        get(budget.carbon_bounded_adjustment, name, 0.0) +
        carbon_adjustment * day_seconds
    if configuration == :carbon_nitrogen
        plant_nitrogen = parent(p.casa_plant.nitrogen_fluxes)
        soil_nitrogen = parent(p.casa_soil.nitrogen_fluxes)
        deposition = parent(p.casa_soil.nitrogen_deposition)
        fixation = parent(p.casa_soil.nitrogen_fixation)
        nitrogen_input = 0.0
        nitrogen_output = 0.0
        nitrogen_adjustment = 0.0
        for point in eachindex(area)
            tendency = -plant_nitrogen[1, 1, 7, point]
            for index in 1:6
                tendency += plant_nitrogen[1, 1, index, point]
            end
            nitrogen_input +=
                area[point] *
                (deposition[1, 1, 1, point] + fixation[1, 1, 1, point])
            nitrogen_output +=
                area[point] * (
                    soil_nitrogen[1, 1, 12, point] +
                    soil_nitrogen[1, 1, 13, point]
                )
            nitrogen_adjustment += area[point] * tendency
        end
        budget.nitrogen_input[name] =
            get(budget.nitrogen_input, name, 0.0) + nitrogen_input * day_seconds
        budget.nitrogen_output[name] =
            get(budget.nitrogen_output, name, 0.0) +
            nitrogen_output * day_seconds
        budget.nitrogen_bounded_adjustment[name] =
            get(budget.nitrogen_bounded_adjustment, name, 0.0) +
            nitrogen_adjustment * day_seconds
    end
    return nothing
end

function area_weighted_stock(state, area, prefix)
    total = 0.0
    for component in values(state), variable in propertynames(component)
        startswith(String(variable), prefix) || continue
        total +=
            sum(area .* vec(Array(parent(getproperty(component, variable)))))
    end
    return total
end

function budget_report(
    start_stock,
    stop_stock,
    input,
    output,
    units;
    adjustment = 0.0,
    adjustment_label = "bounded_state_adjustment",
    rtol,
)
    residual = stop_stock - start_stock - (input - output + adjustment)
    scale = max(
        abs(stop_stock - start_stock),
        abs(input),
        abs(output),
        abs(adjustment),
        1.0,
    )
    return Dict(
        "start_stock_$units" => start_stock,
        "stop_stock_$units" => stop_stock,
        "external_input_$units" => input,
        "external_output_$units" => output,
        "$(adjustment_label)_$units" => adjustment,
        "residual_$units" => residual,
        "relative_residual" => abs(residual) / scale,
        "rtol" => rtol,
        "close" => abs(residual) <= rtol * scale,
    )
end

function workflow_budget_report(
    stage_budgets,
    passive_restoration,
    area,
    element;
    serialization_adjustment = 0.0,
    rtol,
)
    units = element == "carbon" ? "kg_c" : "kg_n"
    first_stage = stage_budgets["prespin"]
    last_stage = stage_budgets["historical"]
    input =
        sum(stage["external_input_$units"] for stage in values(stage_budgets))
    output =
        sum(stage["external_output_$units"] for stage in values(stage_budgets))
    bounded_key = "bounded_state_adjustment_$units"
    bounded_adjustment =
        sum(get(stage, bounded_key, 0.0) for stage in values(stage_budgets))
    restored = passive_restoration[element]
    passive_adjustment = sum(area .* (restored["after"] .- restored["before"]))
    restart_adjustment = passive_adjustment + serialization_adjustment
    report = budget_report(
        first_stage["start_stock_$units"],
        last_stage["stop_stock_$units"],
        input,
        output,
        units;
        adjustment = bounded_adjustment + restart_adjustment,
        adjustment_label = "combined_state_adjustment",
        rtol,
    )
    report["bounded_state_adjustment_$units"] = bounded_adjustment
    report["restart_adjustment_$units"] = restart_adjustment
    report["passive_restoration_adjustment_$units"] = passive_adjustment
    report["restart_serialization_adjustment_$units"] = serialization_adjustment
    return report
end

function output_records(path)
    return NCDatasets.NCDataset(path) do output
        size(output["time"], 1)
    end
end

function stage_provenance(setup, stage)
    parameter_path = if stage.name == :prespin
        setup.configuration == :carbon_nitrogen ?
        setup.files["casa_cn_parameters"] : setup.files["casa_c_parameters"]
    else
        setup.files["casa_c_parameters"]
    end
    parameter_file = Dict{String, Any}(
        "source" => abspath(parameter_path),
        "sha256" => native_workflow().sha256sum(parameter_path),
    )
    if stage.name == :accelerated_spin
        parameter_file["effective_passive_decay_rate_multiplier"] = 10.0
        parameter_file["adjustment"] = "applied during model construction; equivalent to the archived accelerated-spin parameter file"
    end
    return Dict(
        "model" => "ClimaLand integrated CASA",
        "configuration" => String(setup.configuration),
        "pft" => "selected-cell $(setup.collection.name) collection",
        "parameter_file" => parameter_file,
        "forcing" => [
            Dict(
                "stage" => String(stage.name),
                "source" => abspath(setup.files["forcing"]),
                "sha256" =>
                    native_workflow().sha256sum(setup.files["forcing"]),
            ),
        ],
    )
end

function load_setup(
    configuration;
    collection = reference_cells().ordinary_cell_collection(),
)
    configuration in supported_configurations() || throw(
        ArgumentError("configuration must be :carbon_only or :carbon_nitrogen"),
    )
    return reference_cells().with_fixture(collection) do fixture
        grid = selected_grid(fixture.files["grid"], fixture.cell_ids)
        soils = native_casa().read_soils(fixture.files["soil"])
        domain = native_casa().gridded_domain(length(grid))
        buffers = native_casa().GriddedBuffers(domain)
        nitrogen_deposition =
            native_casa().scalar_field(domain, zeros(length(grid)))
        if configuration == :carbon_only
            normal = native_casa().build_gridded_model(
                grid,
                soils,
                fixture.files["casa_c_parameters"],
                buffers;
                domain,
            )
            accelerated = native_casa().build_gridded_model(
                grid,
                soils,
                fixture.files["casa_c_parameters"],
                buffers;
                domain,
                passive_rate_multiplier = 10,
            )
            prespin = normal
            initial_state = native_casa().gridded_initial_state(
                normal.model,
                grid,
                normal.parameters,
            )
        else
            prespin = build_cn_model(
                grid,
                soils,
                fixture.files["casa_cn_parameters"],
                buffers,
                nitrogen_deposition;
                domain,
                boreal_fixation = true,
            )
            normal = build_cn_model(
                grid,
                soils,
                fixture.files["casa_c_parameters"],
                buffers,
                nitrogen_deposition;
                domain,
            )
            accelerated = build_cn_model(
                grid,
                soils,
                fixture.files["casa_c_parameters"],
                buffers,
                nitrogen_deposition;
                domain,
                passive_rate_multiplier = 10,
            )
            initial_state = gridded_cn_initial_state(
                prespin.model,
                grid,
                fixture.files["casa_cn_parameters"],
            )
        end
        forcing = PackedForcing(
            fixture.forcing,
            fixture.cell_indices,
            grid,
            soils,
            normal.parameters,
            fixture.files["phenology"],
            buffers,
            nitrogen_deposition,
        )
        return (;
            configuration,
            collection,
            cell_ids = fixture.cell_ids,
            grid,
            soils,
            buffers,
            nitrogen_deposition,
            prespin,
            normal,
            accelerated,
            initial_state,
            forcing,
            files = fixture.files,
        )
    end
end

struct StageModelSelector{S}
    setup::S
end

function (selector::StageModelSelector)(stage)
    setup = selector.setup
    stage.name == :prespin && return setup.prespin.model
    stage.name == :accelerated_spin && return setup.accelerated.model
    return setup.normal.model
end

struct SelectedForcingUpdater{F, S, M}
    forcing::F
    stoichiometry::S
    model_for_stage::M
end

function (updater::SelectedForcingUpdater)(stage, index, time)
    update_forcing!(updater.forcing, stage, index, time)
    isnothing(updater.stoichiometry) || native_casa().apply_stoichiometry!(
        updater.stoichiometry,
        updater.model_for_stage(stage),
    )
    return nothing
end

function prepare_stage!(updater::SelectedForcingUpdater, _, initial_state, _)
    isnothing(updater.stoichiometry) || native_casa().restore_stoichiometry!(
        updater.stoichiometry,
        initial_state,
    )
    return nothing
end

struct SelectedAfterStep{B, S}
    budget::B
    configuration::Symbol
    stoichiometry::S
end

struct ObservedStateVariable
    component::Symbol
    variable::Symbol
    name::String
end

mutable struct NonfiniteObserver{D}
    cell_ids::Vector{Int}
    state_variables::Vector{ObservedStateVariable}
    diagnostics::D
    seen::BitVector
    records::Vector{Dict{String, Any}}
    path::Union{Nothing, String}
    model::String
    scope::String
end

function NonfiniteObserver(
    cell_ids,
    initial_state,
    diagnostics;
    path = nothing,
    model,
    scope,
)
    variables = ObservedStateVariable[
        ObservedStateVariable(component, variable, "$component.$variable")
        for component in propertynames(initial_state) for
        variable in propertynames(getproperty(initial_state, component))
    ]
    sort!(variables; by = descriptor -> descriptor.name)
    ordered_diagnostics = sort!(collect(diagnostics); by = item -> item.name)
    return NonfiniteObserver(
        Int.(collect(cell_ids)),
        variables,
        ordered_diagnostics,
        falses(length(cell_ids)),
        Dict{String, Any}[],
        isnothing(path) ? nothing : abspath(path),
        String(model),
        String(scope),
    )
end

function write_nonfinite_evidence(observer::NonfiniteObserver)
    isnothing(observer.path) && return nothing
    mkpath(dirname(observer.path))
    temporary = observer.path * ".tmp"
    open(temporary, "w") do io
        TOML.print(
            io,
            Dict(
                "schema_version" => 1,
                "model" => observer.model,
                "scope" => observer.scope,
                "nonfinite" => observer.records,
            );
            sorted = true,
        )
    end
    mv(temporary, observer.path; force = true)
    return observer.path
end

function read_nonfinite_evidence(path; model, scope)
    isfile(path) || return Dict{String, Any}[]
    document = TOML.parsefile(path)
    get(document, "schema_version", nothing) == 1 &&
        get(document, "model", nothing) == model &&
        get(document, "scope", nothing) == scope ||
        error("Julia CASA nonfinite evidence has incompatible provenance")
    records = Dict{String, Any}.(get(document, "nonfinite", Any[]))
    required = Set((
        "cell_id",
        "evidence_side",
        "first_nonfinite_stage",
        "first_nonfinite_date",
        "first_nonfinite_step",
        "first_nonfinite_variable",
        "reason",
    ))
    all(
        Set(keys(record)) == required &&
            record["evidence_side"] == "julia" &&
            record["cell_id"] isa Integer &&
            record["first_nonfinite_step"] isa Integer &&
            record["first_nonfinite_step"] > 0 &&
            !isempty(record["first_nonfinite_variable"]) &&
            tryparse(Dates.Date, record["first_nonfinite_date"]) !== nothing for
        record in records
    ) || error("Julia CASA nonfinite evidence is malformed")
    allunique(getindex.(records, "cell_id")) ||
        error("Julia CASA nonfinite evidence repeats a cell")
    issorted(getindex.(records, "cell_id")) ||
        error("Julia CASA nonfinite evidence is unordered")
    return records
end

function observe_values!(observer, stage, step, variable, values)
    data = vec(parent(values))
    length(data) == length(observer.cell_ids) ||
        error("Julia nonfinite observer has incompatible $variable values")
    added = false
    date = nothing
    for position in eachindex(observer.cell_ids)
        observer.seen[position] && continue
        value = data[position]
        ismissing(value) &&
            error("Julia nonfinite observer found missing $variable")
        value isa Real && !isfinite(value) || continue
        if isnothing(date)
            index = native_workflow().forcing_index(stage, step)
            date = string(Dates.Date(1901, 1, 1) + Dates.Day(index - 1))
        end
        push!(
            observer.records,
            Dict(
                "cell_id" => observer.cell_ids[position],
                "evidence_side" => "julia",
                "first_nonfinite_stage" => String(stage.name),
                "first_nonfinite_date" => date,
                "first_nonfinite_step" => step,
                "first_nonfinite_variable" => variable,
                "reason" => "native Julia CASA trajectory became nonfinite",
            ),
        )
        observer.seen[position] = true
        added = true
    end
    if added
        sort!(observer.records; by = record -> record["cell_id"])
        write_nonfinite_evidence(observer)
    end
    return added
end

function (observer::NonfiniteObserver)(stage, step, Y, p, _)
    all(observer.seen) && return nothing
    for descriptor in observer.state_variables
        values = getproperty(
            getproperty(Y, descriptor.component),
            descriptor.variable,
        )
        observe_values!(observer, stage, step, descriptor.name, values)
    end
    for diagnostic in observer.diagnostics
        values = diagnostic.compute(Y, p)
        name = replace(diagnostic.name, "__" => ".")
        observe_values!(observer, stage, step, name, values)
    end
    return nothing
end

function (callback::SelectedAfterStep)(stage, _, Y, p, _)
    accumulate_budget!(callback.budget, callback.configuration, stage, p)
    isnothing(callback.stoichiometry) ||
        native_casa().update_stoichiometry!(callback.stoichiometry, Y)
    return nothing
end

function default_diagnostics(configuration, setup)
    parameters = setup.normal.model.casa_soil.parameters
    return configuration == :carbon_nitrogen ?
           native_casa_cn().casa_cn_diagnostics(parameters) :
           native_casa().casa_diagnostics(parameters)
end

function run_selected_case(
    output_root;
    configuration = :carbon_only,
    collection = reference_cells().ordinary_cell_collection(),
    concurrency_budget = reference_cells().ConcurrencyBudget(1),
    stages = COMPLETE_STAGES,
    budget_rtol = 5e-12,
    compare_references = true,
    reference_path = REFERENCE_PATH,
    comparison_policy = nothing,
    diagnostics = nothing,
    nonfinite_path = nothing,
)
    setup = load_setup(configuration; collection)
    active_diagnostics = if isnothing(diagnostics)
        default_diagnostics(configuration, setup)
    elseif diagnostics isa Function
        diagnostics(setup)
    else
        diagnostics
    end
    reference =
        canonical_schedule(stages) && compare_references ?
        workflow_reference(
            configuration,
            collection;
            path = reference_path,
            comparison_policy,
        ) : nothing
    initialization_comparison =
        isnothing(reference) ?
        Dict("skipped" => "reference comparison disabled") :
        compare_initialization_reference(
            reference,
            setup.initial_state,
            collection,
            concurrency_budget,
        )
    model_for_stage = StageModelSelector(setup)
    budget = BudgetAccumulator(setup.grid)
    stoichiometry =
        configuration == :carbon_only ?
        native_casa().CarbonOnlyPlantStoichiometry(
            setup.grid,
            setup.normal.parameters,
        ) : nothing
    update! =
        SelectedForcingUpdater(setup.forcing, stoichiometry, model_for_stage)
    selected_after_step =
        SelectedAfterStep(budget, configuration, stoichiometry)
    nonfinite_observer = NonfiniteObserver(
        setup.cell_ids,
        setup.initial_state,
        active_diagnostics;
        path = nonfinite_path,
        model = configuration == :carbon_only ? "CASA-C" : "CASA-CN",
        scope = collection.name,
    )
    fixed_plant_stoichiometry = Dict{Symbol, Vector{Float64}}()
    restart_serialization_adjustment = Dict("carbon" => 0.0, "nitrogen" => 0.0)
    function prepare_selected_stage!(stage, initial_state, model)
        prepare_stage!(update!, stage, initial_state, model)
        configuration == :carbon_nitrogen || return nothing
        if stage.name != :prespin
            carbon_before =
                area_weighted_stock(initial_state, budget.area_m2, "c_")
            nitrogen_before =
                area_weighted_stock(initial_state, budget.area_m2, "n_")
            quantize_fortran_restart!(
                initial_state,
                stage.name == :normal_spin ? 10 : 1,
            )
            restart_serialization_adjustment["carbon"] +=
                area_weighted_stock(initial_state, budget.area_m2, "c_") -
                carbon_before
            restart_serialization_adjustment["nitrogen"] +=
                area_weighted_stock(initial_state, budget.area_m2, "n_") -
                nitrogen_before
        end
        parameters =
            stage.name == :prespin ? setup.prespin.parameters :
            setup.normal.parameters
        fixed_plant_stoichiometry[stage.name] =
            use_initial_plant_stoichiometry!(
                model,
                setup.grid,
                parameters,
                initial_state,
            )
        return nothing
    end
    function after_step!(stage, step, Y, p, time)
        nonfinite_observer(stage, step, Y, p, time)
        selected_after_step(stage, step, Y, p, time)
        if configuration == :carbon_nitrogen && step == 1
            restore_plant_stoichiometry!(
                model_for_stage(stage),
                fixed_plant_stoichiometry[stage.name],
            )
        end
        return nothing
    end
    function carbon_budget(stage, result, _, _, initial_state, model)
        name = stage.name
        final_state = native_casa().state_as_initial_state(result.state, model)
        return budget_report(
            area_weighted_stock(initial_state, budget.area_m2, "c_"),
            area_weighted_stock(final_state, budget.area_m2, "c_"),
            budget.carbon_input[name],
            budget.carbon_output[name],
            "kg_c";
            adjustment = budget.carbon_bounded_adjustment[name],
            rtol = budget_rtol,
        )
    end
    function nitrogen_budget(stage, result, initial_state, model)
        name = stage.name
        final_state = native_casa().state_as_initial_state(result.state, model)
        return budget_report(
            area_weighted_stock(initial_state, budget.area_m2, "n_"),
            area_weighted_stock(final_state, budget.area_m2, "n_"),
            budget.nitrogen_input[name],
            budget.nitrogen_output[name],
            "kg_n";
            adjustment = budget.nitrogen_bounded_adjustment[name],
            rtol = budget_rtol,
        )
    end
    function workflow_budget(
        carbon_stage_budgets,
        nitrogen_stage_budgets,
        passive_restoration,
    )
        reports = Dict(
            "carbon" => workflow_budget_report(
                carbon_stage_budgets,
                passive_restoration,
                budget.area_m2,
                "carbon";
                serialization_adjustment = restart_serialization_adjustment["carbon"],
                rtol = budget_rtol,
            ),
        )
        if !isnothing(nitrogen_stage_budgets)
            reports["nitrogen"] = workflow_budget_report(
                nitrogen_stage_budgets,
                passive_restoration,
                budget.area_m2,
                "nitrogen";
                serialization_adjustment = restart_serialization_adjustment["nitrogen"],
                rtol = budget_rtol,
            )
        end
        return reports
    end
    result = native_casa().run_case(
        setup.initial_state,
        stages,
        output_root;
        model_for_stage,
        update_forcing! = update!,
        after_step!,
        diagnostics = active_diagnostics,
        provenance = stage -> stage_provenance(setup, stage),
        initialization_comparison,
        compare_boundary = (stage, result, _) ->
            isnothing(reference) ?
            Dict("skipped" => "reference comparison disabled") :
            compare_boundary_reference(
                reference,
                stage,
                result.state,
                collection,
                concurrency_budget,
            ),
        compare_historical = (path, _) ->
            isnothing(reference) ?
            Dict(
                "output" => Dict("records" => output_records(path)),
                "skipped" => "reference comparison disabled",
            ) :
            compare_historical_reference(
                reference,
                path,
                collection,
                concurrency_budget,
            ),
        carbon_budget,
        nitrogen_budget = configuration == :carbon_nitrogen ?
                          nitrogen_budget : nothing,
        workflow_budget,
        prepare_stage! = prepare_selected_stage!,
        restore_passive! = configuration == :carbon_nitrogen ?
                           restore_passive_carbon_nitrogen! :
                           native_casa().restore_passive_carbon!,
    )
    return merge(result, (; nonfinite_records = nonfinite_observer.records))
end

end
