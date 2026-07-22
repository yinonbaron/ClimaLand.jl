if !isdefined(@__MODULE__, :TestbedSelectedCellFixtures)
    include(joinpath(@__DIR__, "selected_cell_fixtures.jl"))
end
if !isdefined(@__MODULE__, :TestbedNativeWorkflow)
    include(joinpath(@__DIR__, "native_workflow.jl"))
end
if !isdefined(@__MODULE__, :TestbedSelectedCASAWorkflow)
    include(joinpath(@__DIR__, "selected_casa_workflow.jl"))
end
if !isdefined(@__MODULE__, :TestbedReferenceCellComparisons)
    include(joinpath(@__DIR__, "reference_cell_comparisons.jl"))
end
if !isdefined(@__MODULE__, :TestCORPSEParameters)
    include(
        joinpath(
            @__DIR__,
            "..",
            "shared_utilities",
            "corpse_test_parameters.jl",
        ),
    )
end

module TestbedSelectedCORPSEWorkflow

import SHA
import TOML

import ClimaLand
import NCDatasets
import StaticArrays
import Statistics

using ..TestCORPSEParameters: corpse_carbon_parameters

const CORPSE = ClimaLand.Soil.Biogeochemistry.CORPSE
const REFERENCE_MANIFEST =
    joinpath(@__DIR__, "fixtures", "selected_corpse", "fixture.toml")
const WORKFLOW_REFERENCE_MANIFEST =
    joinpath(@__DIR__, "fixtures", "selected_corpse", "complete_workflow.toml")

reference_cells() =
    getfield(parentmodule(@__MODULE__), :TestbedReferenceCellComparisons)
native_workflow() = getfield(parentmodule(@__MODULE__), :TestbedNativeWorkflow)
selected_casa() =
    getfield(parentmodule(@__MODULE__), :TestbedSelectedCASAWorkflow)
native_casa() = selected_casa().native_casa()

const COMPLETE_STAGES = (
    native_workflow().NativeStage(:prespin, 365, 100; write_output = false),
    native_workflow().NativeStage(:spin, 20 * 365, 499; write_output = false),
    native_workflow().NativeStage(
        :restart,
        20 * 365,
        499;
        write_output = false,
    ),
    native_workflow().NativeStage(:historical, 114 * 365, 1),
)

canonical_schedule(stages) = Tuple(stages) == COMPLETE_STAGES

const PlantCASA = ClimaLand.Vegetation.CASA
# Tolerances are measured maxima (rounded up) after the complete repeated spin
# schedule. The CORPSE absolute tolerance covers redistribution among the small
# PFT 7 microbial pools while keeping the aggregate historical comparison tight.
const BOUNDARY_CASA_ATOL = 5.1e-10
const BOUNDARY_CASA_RTOL = 3.0e-3
const BOUNDARY_CORPSE_ATOL = 2.6e-3
const BOUNDARY_CORPSE_RTOL = 4.0e-2
const HISTORICAL_CARBON_ATOL = 1.0e-3
const HISTORICAL_DRIVER_ATOL = 5.0e-8
const HISTORICAL_DRIVER_RTOL = 5.0e-10

"""
    CORPSEBuffers{B, F}

Hold the mutable fields updated by the packed CASA--CORPSE forcing.

# Fields
- `base`: CASA forcing buffers.
- `liquid_saturation`: Root-weighted liquid saturation [-].
- `frozen_saturation`: Root-weighted frozen saturation [-].
- `exudate_labile`: Annual-NPP-derived labile exudation [kg C m⁻² s⁻¹].
"""
mutable struct CORPSEBuffers{B, F}
    base::B
    liquid_saturation::F
    frozen_saturation::F
    exudate_labile::F
end

function CORPSEBuffers(domain)
    base = native_casa().GriddedBuffers(domain)
    field() =
        native_casa().scalar_field(domain, zeros(length(parent(base.gpp))))
    return CORPSEBuffers(base, field(), field(), field())
end

"""
    PackedCORPSEForcing{B, M, C}

Store the selected-cell daily forcing and its destination buffers.

# Fields
- `base`: Packed CASA forcing.
- `liquid_saturation`: Root-weighted liquid saturation by point and day [-].
- `frozen_saturation`: Root-weighted frozen saturation by point and day [-].
- `exudate_labile`: First-year labile exudation seed by point and day [kg C m⁻² s⁻¹].
- `buffers`: Mutable buffers consumed by the integrated model.
"""
struct PackedCORPSEForcing{B, M, C}
    base::B
    liquid_saturation::M
    frozen_saturation::M
    exudate_labile::M
    buffers::C
end

function PackedCORPSEForcing(
    dataset,
    cell_indices,
    grid,
    soils,
    parameters,
    phenology_path,
    buffers,
)
    placeholder = zero(buffers.base.gpp)
    base = selected_casa().PackedForcing(
        dataset,
        cell_indices,
        grid,
        soils,
        parameters,
        phenology_path,
        buffers.base,
        placeholder,
    )
    points, days = size(base.gpp)
    liquid_saturation = zeros(points, days)
    frozen_saturation = zeros(points, days)
    exudate_labile = zeros(points, days)
    layered_temperature = Float64.(dataset["xtsoil"][:, :, cell_indices])
    layered_moisture = Float64.(dataset["xmoist"][:, :, cell_indices])
    layered_frozen = Float64.(dataset["xfrznmoist"][:, :, cell_indices])
    for point_index in eachindex(grid)
        point = grid[point_index]
        soil = soils[point.cell_id]
        porosity = soil.porosity
        roots = native_casa().root_fractions(parameters[point.pft])
        for day in 1:days
            temperature = 0.0
            liquid_water = 0.0
            frozen_water = 0.0
            for layer in eachindex(roots)
                root = roots[layer]
                temperature +=
                    root * layered_temperature[layer, day, point_index]
                liquid_water +=
                    root * min(
                        soil.field_capacity,
                        layered_moisture[layer, day, point_index],
                    )
                frozen_water += root * layered_frozen[layer, day, point_index]
            end
            base.soil_temperature[point_index, day] = temperature
            base.liquid_water[point_index, day] = liquid_water
            if base.active[point_index]
                liquid_saturation[point_index, day] =
                    min(1.0, liquid_water / porosity)
                frozen_saturation[point_index, day] =
                    min(1.0, frozen_water / porosity)
            end
        end
        base.active[point_index] || continue
        for year_start in 1:365:days
            year_stop = min(year_start + 364, days)
            requested =
                0.02 * sum(view(base.gpp, point_index, year_start:year_stop)) /
                (2 * (year_stop - year_start + 1))
            exudate_labile[point_index, year_start:year_stop] .= requested
        end
    end
    return PackedCORPSEForcing(
        base,
        liquid_saturation,
        frozen_saturation,
        exudate_labile,
        buffers,
    )
end

function update_forcing!(forcing::PackedCORPSEForcing, stage, index, time)
    selected_casa().update_forcing!(forcing.base, stage, index, time)
    vec(parent(forcing.buffers.liquid_saturation)) .=
        view(forcing.liquid_saturation, :, index)
    vec(parent(forcing.buffers.frozen_saturation)) .=
        view(forcing.frozen_saturation, :, index)
    return nothing
end

mutable struct AnnualNPPTracker{F}
    active_stage::Union{Nothing, Symbol}
    accumulated::F
end

function AnnualNPPTracker(buffers::CORPSEBuffers)
    return AnnualNPPTracker(nothing, zero(buffers.exudate_labile))
end

function prepare_annual_npp!(tracker, forcing, stage, index)
    mod1(index, 365) == 1 || return nothing
    exudate = vec(parent(forcing.buffers.exudate_labile))
    if tracker.active_stage != stage.name
        tracker.active_stage = stage.name
        exudate .= view(forcing.exudate_labile, :, index)
    else
        exudate .= 0.02 .* vec(parent(tracker.accumulated)) ./ (365 * 86400)
    end
    tracker.accumulated .= 0
    return nothing
end

function accumulate_annual_npp!(tracker, p)
    @. tracker.accumulated += 86400 * getindex(p.casa_plant.carbon_fluxes, 15)
    return nothing
end

function inactive_carbon_parameters(carbon)
    names = fieldnames(typeof(carbon))
    values = NamedTuple{names}(getproperty.(Ref(carbon), names))
    inactive = merge(
        values,
        (;
            vmax_reference = map(zero, carbon.vmax_reference),
            microbe_turnover_time = Inf,
            protection_rate = 0.0,
            protected_turnover_time = Inf,
        ),
    )
    return CORPSE.CarbonParameters{Float64}(; inactive...)
end

function corpse_parameters(plant, soil)
    base_carbon = corpse_carbon_parameters(Float64)
    carbon =
        plant.inactive ? inactive_carbon_parameters(base_carbon) : base_carbon
    cwd_to_soil =
        plant.cues[4] * (1 - plant.lignin_wood) +
        plant.cues[5] * plant.lignin_wood
    parameter_type = CORPSE.CORPSESoilModelParameters{Float64, typeof(carbon)}
    return parameter_type(;
        carbon,
        mineral_protection_capacity = CORPSE.mineral_protection_capacity(
            soil.clay,
            soil.porosity,
        ),
        layer_thickness = 0.15,
        rhizosphere_fraction = 0.3,
        litter_option = 1,
        freezing_temperature = 273.15,
        cwd_q10 = plant.q10,
        cwd_litter_optimum = plant.litter_optimum,
        cwd_base_rate = plant.litter_rates[3],
        cwd_respiration_fraction = 1 - cwd_to_soil,
    )
end

function build_model(grid, soils, parameter_path, buffers; domain)
    plant_build = native_casa().build_gridded_model(
        grid,
        soils,
        parameter_path,
        buffers.base;
        domain,
    )
    soil_points = map(grid) do point
        corpse_parameters(plant_build.parameters[point.pft], soils[point.cell_id])
    end
    zero_driver = _ -> zero(buffers.exudate_labile)
    drivers = CORPSE.PrescribedDrivers(
        _ -> buffers.base.soil_temperature,
        _ -> buffers.liquid_saturation,
        _ -> buffers.frozen_saturation,
        zero_driver,
        zero_driver,
        zero_driver,
        zero_driver,
        _ -> buffers.exudate_labile,
        zero_driver,
    )
    soil = CORPSE.CORPSESoilModel{Float64}(;
        parameters = native_casa().point_field(domain, soil_points),
        drivers,
        domain,
        temporal_mode = CORPSE.LegacyDaily(),
    )
    model = ClimaLand.CASAPlantSoilModel{Float64}(
        plant_build.model.casa_plant,
        soil,
        plant_build.model.coupling,
    )
    return (; model, parameters = plant_build.parameters)
end

function gridded_initial_state(model, grid, parameters)
    plant =
        native_casa().gridded_initial_state(model, grid, parameters).casa_plant
    function values(variable)
        return map(grid) do point
            plant_values = parameters[point.pft]
            variable == :c_litter_cwd &&
                return plant_values.inactive || plant_values.nonwoody ? 0.0 :
                       plant_values.initial_carbon[6]
            variable == :soil_rhiz_unprotected_recalcitrant && return 1.998
            variable == :soil_rhiz_live_microbe && return 0.002
            variable == :soil_rhiz_original_carbon && return 2.0
            return 0.0
        end
    end
    field(variable) =
        native_casa().scalar_field(model.casa_plant.domain, values(variable))
    corpse = NamedTuple{ClimaLand.prognostic_vars(model.corpse_soil)}(
        map(field, ClimaLand.prognostic_vars(model.corpse_soil)),
    )
    return (; casa_plant = plant, corpse_soil = corpse)
end

function load_complete_setup(
    collection = reference_cells().ordinary_cell_collection(),
)
    return reference_cells().with_fixture(collection) do fixture
        grid = selected_casa().selected_grid(
            fixture.files["grid"],
            fixture.cell_ids,
        )
        soils = native_casa().read_soils(fixture.files["soil"])
        domain = native_casa().gridded_domain(length(grid))
        buffers = CORPSEBuffers(domain)
        build = build_model(
            grid,
            soils,
            fixture.files["casa_c_parameters"],
            buffers;
            domain,
        )
        forcing = PackedCORPSEForcing(
            fixture.forcing,
            fixture.cell_indices,
            grid,
            soils,
            build.parameters,
            fixture.files["phenology"],
            buffers,
        )
        return (;
            collection,
            cell_ids = fixture.cell_ids,
            grid,
            soils,
            buffers,
            model = build.model,
            parameters = build.parameters,
            forcing,
            initial_state = gridded_initial_state(
                build.model,
                grid,
                build.parameters,
            ),
            files = fixture.files,
        )
    end
end

const COHORT_PREFIXES = ("soil_rhiz", "soil_bulk", "litter_rhiz", "litter_bulk")

function corpse_carbon_totals(Y)
    soil = Y.corpse_soil
    points = length(parent(soil.soil_rhiz_live_microbe))
    active = zeros(points)
    cumulative = zeros(points)
    original = zeros(points)
    for prefix in COHORT_PREFIXES
        for suffix in (
            "unprotected_labile",
            "unprotected_recalcitrant",
            "unprotected_dead_microbe",
            "protected_labile",
            "protected_recalcitrant",
            "protected_dead_microbe",
            "live_microbe",
        )
            active .+=
                vec(parent(getproperty(soil, Symbol(prefix, '_', suffix))))
        end
        cumulative .+=
            vec(parent(getproperty(soil, Symbol(prefix, "_cumulative_co2"))))
        original .+=
            vec(parent(getproperty(soil, Symbol(prefix, "_original_carbon"))))
    end
    return (; active, cumulative, original)
end

function corpse_conservation(Y; atol = 2e-12)
    soil = Y.corpse_soil
    maximum_residual = 0.0
    for prefix in COHORT_PREFIXES
        active = zeros(length(parent(soil.soil_rhiz_live_microbe)))
        for suffix in (
            "unprotected_labile",
            "unprotected_recalcitrant",
            "unprotected_dead_microbe",
            "protected_labile",
            "protected_recalcitrant",
            "protected_dead_microbe",
            "live_microbe",
        )
            active .+=
                vec(parent(getproperty(soil, Symbol(prefix, '_', suffix))))
        end
        cumulative =
            vec(parent(getproperty(soil, Symbol(prefix, "_cumulative_co2"))))
        original =
            vec(parent(getproperty(soil, Symbol(prefix, "_original_carbon"))))
        maximum_residual = max(
            maximum_residual,
            maximum(abs.(active .+ cumulative .- original)),
        )
    end
    return (;
        maximum_residual,
        tolerance = atol,
        verified = maximum_residual <= atol,
    )
end

function carbon_handoff(left, right; atol = 2e-12)
    maximum_residual = maximum((
        maximum(abs.(left.active .- right.active)),
        maximum(abs.(left.cumulative .- right.cumulative)),
        maximum(abs.(left.original .- right.original)),
    ))
    return (;
        maximum_residual,
        tolerance = atol,
        verified = maximum_residual <= atol,
    )
end

function rebase_conservation(before, after; atol = 2e-12)
    maximum_residual = maximum((
        maximum(abs.(before.active .- after.active)),
        maximum(abs, after.cumulative),
        maximum(abs.(after.active .- after.original)),
    ))
    return (;
        maximum_residual,
        tolerance = atol,
        verified = maximum_residual <= atol,
    )
end

function rebase_corpse_stage!(state)
    soil = state.corpse_soil
    for prefix in COHORT_PREFIXES
        active = zeros(
            length(parent(getproperty(soil, Symbol(prefix, "_live_microbe")))),
        )
        for suffix in (
            "unprotected_labile",
            "unprotected_recalcitrant",
            "unprotected_dead_microbe",
            "protected_labile",
            "protected_recalcitrant",
            "protected_dead_microbe",
            "live_microbe",
        )
            active .+=
                vec(parent(getproperty(soil, Symbol(prefix, '_', suffix))))
        end
        getproperty(soil, Symbol(prefix, "_cumulative_co2")) .= 0
        vec(parent(getproperty(soil, Symbol(prefix, "_original_carbon")))) .=
            active
    end
    return state
end

function workflow_provenance(setup, stage)
    parameter_path = setup.files["casa_c_parameters"]
    forcing_path = setup.files["forcing"]
    return Dict(
        "model" => "ClimaLand integrated CASA-CORPSE LegacyDaily",
        "configuration" => "selected-cell complete CORPSE workflow",
        "pft" => "selected-cell $(setup.collection.name) collection",
        "parameter_file" => Dict(
            "source" => abspath(parameter_path),
            "sha256" => native_workflow().sha256sum(parameter_path),
        ),
        "forcing" => [
            Dict(
                "stage" => String(stage.name),
                "source" => abspath(forcing_path),
                "sha256" => native_workflow().sha256sum(forcing_path),
            ),
        ],
    )
end

function complete_state_verified(model, state)
    expected = Set(ClimaLand.prognostic_vars(model.corpse_soil))
    actual = Set(propertynames(state.corpse_soil))
    required = Set((
        :soil_rhiz_original_carbon,
        :soil_rhiz_cumulative_co2,
        :soil_bulk_original_carbon,
        :soil_bulk_cumulative_co2,
        :litter_rhiz_original_carbon,
        :litter_rhiz_cumulative_co2,
        :litter_bulk_original_carbon,
        :litter_bulk_cumulative_co2,
    ))
    return actual == expected && required ⊆ actual
end

function comparison_metrics(actual, expected; atol, rtol = 0.0)
    difference = actual .- expected
    scale = max(maximum(abs, expected), eps(Float64))
    failures = count(zip(actual, expected)) do (value, reference)
        !isapprox(value, reference; atol, rtol)
    end
    return Dict(
        "maximum_absolute_error" => maximum(abs, difference),
        "root_mean_square_error" => sqrt(Statistics.mean(abs2, difference)),
        "maximum_scaled_error" => maximum(abs, difference) / scale,
        "reference_scale" => scale,
        "atol" => atol,
        "rtol" => rtol,
        "failures" => failures,
        "compared_values" => length(actual),
        "all_match" => failures == 0,
    )
end

function boundary_reference_comparison(reference, state, stage, cell_ids)
    stage_names = String.(reference.dataset["stage_name"][:])
    stage_index = only(findall(==(String(stage.name)), stage_names))
    reference_ids = Int.(reference.dataset["cellid"][:])
    cell_indices = [only(findall(==(id), reference_ids)) for id in cell_ids]
    casa_fields = String.(reference.dataset["casa_state_field"][:])
    casa_mapping = Dict(
        "casapool%clabile" => (:casa_plant, :c_labile),
        "casapool%cplant(LEAF)" => (:casa_plant, :c_leaf),
        "casapool%cplant(WOOD)" => (:casa_plant, :c_wood),
        "casapool%cplant(FROOT)" => (:casa_plant, :c_fine_root),
        "casapool%clitter(CWD)" => (:corpse_soil, :c_litter_cwd),
    )
    metrics = Dict{String, Any}()
    for (source, (component, variable)) in casa_mapping
        field_index = only(findall(==(source), casa_fields))
        expected =
            vec(
                reference.dataset["casa_state"][
                    field_index,
                    stage_index,
                    cell_indices,
                ],
            ) / 1000
        actual =
            vec(parent(getproperty(getproperty(state, component), variable)))
        metrics["$component.$variable"] = comparison_metrics(
            actual,
            expected;
            atol = BOUNDARY_CASA_ATOL,
            rtol = BOUNDARY_CASA_RTOL,
        )
    end
    components = String.(reference.dataset["corpse_state_field"][:])
    suffixes = Dict(
        "unprotected_labile" => "unprotected_labile",
        "unprotected_recalcitrant" => "unprotected_recalcitrant",
        "unprotected_dead_microbe" => "unprotected_dead_microbe",
        "protected_labile" => "protected_labile",
        "protected_recalcitrant" => "protected_recalcitrant",
        "protected_dead_microbe" => "protected_dead_microbe",
        "living_microbe" => "live_microbe",
        "cumulative_respiration" => "cumulative_co2",
        "original_carbon" => "original_carbon",
    )
    layers = String.(reference.dataset["layer_name"][:])
    cohorts = String.(reference.dataset["cohort_name"][:])
    for (source, suffix) in suffixes,
        (layer_index, layer) in enumerate(layers),
        (cohort_index, cohort) in enumerate(cohorts)

        component_index = only(findall(==(source), components))
        expected = vec(
            reference.dataset["corpse_state"][
                component_index,
                stage_index,
                cell_indices,
                layer_index,
                cohort_index,
            ],
        )
        short_cohort = cohort == "rhizosphere" ? "rhiz" : "bulk"
        variable = Symbol(layer, '_', short_cohort, '_', suffix)
        actual = vec(parent(getproperty(state.corpse_soil, variable)))
        metrics["corpse_soil.$variable"] = comparison_metrics(
            actual,
            expected;
            atol = BOUNDARY_CORPSE_ATOL,
            rtol = BOUNDARY_CORPSE_RTOL,
        )
    end
    return Dict(
        "variable" => metrics,
        "all_match" => all(metric["all_match"] for metric in values(metrics)),
    )
end

function corpse_diagnostics()
    return (
        (
            name = "diagnostic__soil_temperature",
            long_name = "root-weighted soil temperature",
            units = "K",
            compute = (_, p) -> p.corpse_soil.soil_temperature,
        ),
        (
            name = "diagnostic__liquid_saturation",
            long_name = "root-weighted liquid saturation",
            units = "1",
            compute = (_, p) -> p.corpse_soil.liquid_saturation,
        ),
        (
            name = "diagnostic__frozen_saturation",
            long_name = "root-weighted frozen saturation",
            units = "1",
            compute = (_, p) -> p.corpse_soil.frozen_saturation,
        ),
    )
end

function annual_mean(output, variable, year)
    first_record = (year - 1901) * 365 + 1
    records = first_record:(first_record + 364)
    return vec(Statistics.mean(output[variable][:, records]; dims = 2))
end

function historical_reference_comparison(reference, output_path, cell_ids)
    reference_ids = Int.(reference.dataset["cellid"][:])
    cell_indices = [only(findall(==(id), reference_ids)) for id in cell_ids]
    years = Int.(reference.dataset["historical_year"][:])
    casa_fields = String.(reference.dataset["historical_casa_field"][:])
    corpse_fields = String.(reference.dataset["historical_corpse_field"][:])
    casa_mapping = Dict(
        "cleaf" => "casa_plant__c_leaf",
        "cwood" => "casa_plant__c_wood",
        "cfroot" => "casa_plant__c_fine_root",
        "clitcwd" => "corpse_soil__c_litter_cwd",
    )
    corpse_mapping = Dict(
        "Soil_C1" => ("soil", "unprotected_labile"),
        "Soil_C2" => ("soil", "unprotected_recalcitrant"),
        "Soil_C3" => ("soil", "unprotected_dead_microbe"),
        "SoilProtected_C1" => ("soil", "protected_labile"),
        "SoilProtected_C2" => ("soil", "protected_recalcitrant"),
        "SoilProtected_C3" => ("soil", "protected_dead_microbe"),
        "Soil_LiveMicrobeC" => ("soil", "live_microbe"),
        "LitterLayer_C1" => ("litter", "unprotected_labile"),
        "LitterLayer_C2" => ("litter", "unprotected_recalcitrant"),
        "LitterLayer_C3" => ("litter", "unprotected_dead_microbe"),
        "LitterLayer_LiveMicrobeC" => ("litter", "live_microbe"),
    )
    driver_mapping = Dict(
        "Ts" => "diagnostic__soil_temperature",
        "thetaLiq" => "diagnostic__liquid_saturation",
        "thetaFrzn" => "diagnostic__frozen_saturation",
    )
    metrics = Dict{String, Any}()
    NCDatasets.NCDataset(output_path) do output
        for (year_index, year) in enumerate(years)
            for (source, variable) in casa_mapping
                field_index = only(findall(==(source), casa_fields))
                expected = vec(
                    reference.dataset["historical_casa"][
                        field_index,
                        year_index,
                        cell_indices,
                    ],
                )
                actual = 1000 .* annual_mean(output, variable, year)
                metrics["$year.$source"] = comparison_metrics(
                    actual,
                    expected;
                    atol = HISTORICAL_CARBON_ATOL,
                    rtol = BOUNDARY_CASA_RTOL,
                )
            end
            for (source, (layer, suffix)) in corpse_mapping
                field_index = only(findall(==(source), corpse_fields))
                expected = vec(
                    reference.dataset["historical_corpse"][
                        field_index,
                        year_index,
                        cell_indices,
                    ],
                )
                rhiz = annual_mean(
                    output,
                    "corpse_soil__$(layer)_rhiz_$suffix",
                    year,
                )
                bulk = annual_mean(
                    output,
                    "corpse_soil__$(layer)_bulk_$suffix",
                    year,
                )
                metrics["$year.$source"] = comparison_metrics(
                    1000 .* (rhiz .+ bulk),
                    expected;
                    atol = HISTORICAL_CARBON_ATOL,
                    rtol = BOUNDARY_CORPSE_RTOL,
                )
            end
            for (source, variable) in driver_mapping
                field_index = only(findall(==(source), corpse_fields))
                expected = vec(
                    reference.dataset["historical_corpse"][
                        field_index,
                        year_index,
                        cell_indices,
                    ],
                )
                actual = annual_mean(output, variable, year)
                metrics["$year.$source"] = comparison_metrics(
                    actual,
                    expected;
                    atol = HISTORICAL_DRIVER_ATOL,
                    rtol = HISTORICAL_DRIVER_RTOL,
                )
            end
        end
    end
    return Dict(
        "variable" => metrics,
        "years" => years,
        "all_match" => all(metric["all_match"] for metric in values(metrics)),
    )
end

"""
    run_selected_case(
        output_root;
        collection = ordinary_cell_collection(),
        stages = COMPLETE_STAGES,
        compare_references = true,
    )

Run the selected-cell CASA--CORPSE workflow through its ordered native stages.

# Arguments
- `output_root`: Directory receiving checkpoints, historical output, and the report.

# Keyword Arguments
- `collection`: Selected reference cells; defaults to the ordinary collection.
- `stages`: Ordered stage definitions; defaults to `COMPLETE_STAGES`.
- `compare_references`: Compare canonical runs with the pinned Fortran artifact;
  defaults to `true`.

# Returns
A named tuple containing stage checkpoint results, the historical NetCDF path,
the report path, the age representation, full-workflow conservation status, and
boundary/historical comparisons.
"""
function run_selected_case(
    output_root;
    collection = reference_cells().ordinary_cell_collection(),
    stages = COMPLETE_STAGES,
    compare_references = true,
)
    expected_names = (:prespin, :spin, :restart, :historical)
    getproperty.(stages, :name) == expected_names || throw(
        ArgumentError(
            "CORPSE stages must be ordered $(join(expected_names, ", "))",
        ),
    )
    setup = load_complete_setup(collection)
    reference =
        compare_references && canonical_schedule(stages) ?
        verified_workflow_reference() : nothing
    stoichiometry =
        native_casa().CarbonOnlyPlantStoichiometry(setup.grid, setup.parameters)
    annual_npp = AnnualNPPTracker(setup.buffers)
    current_state = setup.initial_state
    initial_totals = corpse_carbon_totals(current_state)
    workflow_inputs = zero(initial_totals.active)
    workflow_respiration = zero(initial_totals.active)
    stage_results = NamedTuple[]
    stage_reports = Dict{String, Any}()
    historical_output = ""

    for stage in stages
        restart_transform = if stage.name == :prespin
            (; maximum_residual = 0.0, tolerance = 2e-12, verified = true)
        else
            before_rebase = corpse_carbon_totals(current_state)
            rebase_corpse_stage!(current_state)
            native_casa().restore_stoichiometry!(stoichiometry, current_state)
            rebase_conservation(
                before_rebase,
                corpse_carbon_totals(current_state),
            )
        end
        stage_start_totals = corpse_carbon_totals(current_state)
        after_step! =
            (_, _, Y, _, _) ->
                native_casa().update_stoichiometry!(stoichiometry, Y)
        stage_root = joinpath(output_root, "stages", String(stage.name))
        result = native_workflow().run_workflow(
            setup.model,
            current_state,
            [stage],
            stage_root;
            update_forcing! = (stage, index, time) -> begin
                update_forcing!(setup.forcing, stage, index, time)
                native_casa().apply_stoichiometry!(stoichiometry, setup.model)
                prepare_annual_npp!(annual_npp, setup.forcing, stage, index)
            end,
            after_step! = (stage, step, Y, p, time) -> begin
                after_step!(stage, step, Y, p, time)
                accumulate_annual_npp!(annual_npp, p)
            end,
            diagnostics = corpse_diagnostics(),
            provenance = workflow_provenance(setup, stage),
        )
        stage_end_totals = corpse_carbon_totals(result.state)
        workflow_inputs .+=
            stage_end_totals.original .- stage_start_totals.original
        workflow_respiration .+=
            stage_end_totals.cumulative .- stage_start_totals.cumulative
        checkpoint = only(result.checkpoints)
        expected_checkpoint_state =
            native_casa().state_as_initial_state(result.state, setup.model)
        checkpoint_state, _ =
            ClimaLand.read_checkpoint(checkpoint; model = setup.model)
        current_state =
            native_casa().state_as_initial_state(checkpoint_state, setup.model)
        checkpoint_handoff = carbon_handoff(
            stage_end_totals,
            corpse_carbon_totals(current_state),
        )
        checkpoint_roundtrip_verified =
            native_casa().states_match(
                expected_checkpoint_state,
                current_state,
            ) && checkpoint_handoff.verified
        complete_corpse_state_verified =
            complete_state_verified(setup.model, current_state)
        conservation = corpse_conservation(current_state)
        boundary_reference = if isnothing(reference)
            Dict("status" => "not compared")
        else
            NCDatasets.NCDataset(reference.path) do dataset
                boundary_reference_comparison(
                    (; dataset),
                    current_state,
                    stage,
                    setup.cell_ids,
                )
            end
        end
        stage_reports[String(stage.name)] = Dict(
            "checkpoint_roundtrip_verified" =>
                checkpoint_roundtrip_verified,
            "checkpoint_handoff" => Dict(
                "maximum_residual_kg_c_m2" =>
                    checkpoint_handoff.maximum_residual,
                "tolerance_kg_c_m2" => checkpoint_handoff.tolerance,
                "verified" => checkpoint_handoff.verified,
            ),
            "restart_transform" => Dict(
                "maximum_residual_kg_c_m2" =>
                    restart_transform.maximum_residual,
                "tolerance_kg_c_m2" => restart_transform.tolerance,
                "verified" => restart_transform.verified,
            ),
            "complete_corpse_state_verified" =>
                complete_corpse_state_verified,
            "conservation" => Dict(
                "maximum_residual_kg_c_m2" => conservation.maximum_residual,
                "tolerance_kg_c_m2" => conservation.tolerance,
                "verified" => conservation.verified,
            ),
            "reference" => boundary_reference,
        )
        push!(
            stage_results,
            (;
                name = stage.name,
                checkpoint,
                checkpoint_roundtrip_verified,
                checkpoint_handoff_verified = checkpoint_handoff.verified,
                restart_transform_verified = restart_transform.verified,
                complete_corpse_state_verified,
                conservation_verified = conservation.verified,
                manifest = result.manifest,
            ),
        )
        stage.name == :historical && (historical_output = result.output)
    end

    final_totals = corpse_carbon_totals(current_state)
    workflow_residual =
        initial_totals.active .+ workflow_inputs .- workflow_respiration .-
        final_totals.active
    workflow_tolerance = 2e-11
    full_workflow_conservation = (;
        maximum_residual = maximum(abs, workflow_residual),
        tolerance = workflow_tolerance,
        verified = maximum(abs, workflow_residual) <= workflow_tolerance,
    )

    historical_reference = if isnothing(reference)
        Dict("status" => "not compared")
    else
        NCDatasets.NCDataset(reference.path) do dataset
            historical_reference_comparison(
                (; dataset),
                historical_output,
                setup.cell_ids,
            )
        end
    end

    comparison_passed =
        !isnothing(reference) &&
        all(
            stage_reports[name]["reference"]["all_match"] for
            name in String.(expected_names)
        ) &&
        historical_reference["all_match"]
    report_path = joinpath(output_root, "corpse_workflow_report.toml")
    report = Dict(
        "schema_version" => 1,
        "temporal_mode" => "LegacyDaily",
        "age_representation" => "fixed cohort identity",
        "volume_representation" => "derived from checkpointed original carbon and litter density",
        "reference_comparison" =>
            isnothing(reference) ? "disabled" :
            comparison_passed ? "passed" : "failed",
        "selection" => Dict(
            "cell_ids" => setup.cell_ids,
            "pfts" => sort!(unique(getproperty.(collection.cells, :pft))),
            "forcing_regimes" => sort!(
                unique(vcat(getproperty.(collection.cells, :reasons)...)),
            ),
        ),
        "full_workflow_conservation" => Dict(
            "maximum_residual_kg_c_m2" =>
                full_workflow_conservation.maximum_residual,
            "tolerance_kg_c_m2" => full_workflow_conservation.tolerance,
            "verified" => full_workflow_conservation.verified,
        ),
        "stage" => stage_reports,
        "historical_reference" => historical_reference,
    )
    open(report_path, "w") do io
        TOML.print(io, report; sorted = true)
    end
    return (;
        stages = Tuple(stage_results),
        output = historical_output,
        report = report_path,
        age_representation = "fixed cohort identity",
        full_workflow_conservation_verified = full_workflow_conservation.verified,
        reference = (;
            boundary = Dict(
                name => stage_reports[name]["reference"] for
                name in String.(expected_names)
            ),
            historical = historical_reference,
            all_match = comparison_passed,
        ),
    )
end

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

function verified_reference()
    manifest = TOML.parsefile(REFERENCE_MANIFEST)
    manifest["schema_version"] == 1 ||
        error("Unsupported selected-cell CORPSE reference schema")
    description = manifest["reference"]
    path = joinpath(dirname(REFERENCE_MANIFEST), description["filename"])
    isfile(path) || error("CORPSE reference is missing: $path")
    filesize(path) == description["bytes"] ||
        error("CORPSE reference size mismatch: $path")
    sha256sum(path) == description["sha256"] ||
        error("CORPSE reference checksum mismatch: $path")
    return (; manifest, path)
end

"""
    verified_workflow_reference()

Return the verified, package-test-ready complete CORPSE workflow reference.
"""
function verified_workflow_reference()
    isfile(WORKFLOW_REFERENCE_MANIFEST) || error(
        "Complete CORPSE workflow manifest is missing: " *
        WORKFLOW_REFERENCE_MANIFEST,
    )
    manifest = TOML.parsefile(WORKFLOW_REFERENCE_MANIFEST)
    manifest["schema_version"] == 1 ||
        error("Unsupported complete CORPSE workflow reference schema")
    artifact = manifest["artifact"]
    path = joinpath(dirname(WORKFLOW_REFERENCE_MANIFEST), artifact["filename"])
    isfile(path) || error("Complete CORPSE workflow artifact is missing: $path")
    filesize(path) == artifact["bytes"] ||
        error("Complete CORPSE workflow artifact size mismatch: $path")
    sha256sum(path) == artifact["sha256"] ||
        error("Complete CORPSE workflow artifact checksum mismatch: $path")
    return (; manifest, path)
end

function reference_provenance()
    reference = verified_reference()
    source = reference.manifest["source"]
    generation = reference.manifest["generation"]
    return Dict(
        "source_commit" => source["commit"],
        "reference_sha256" => reference.manifest["reference"]["sha256"],
        "configuration" => generation["configuration"],
        "transformations" => generation["transformations"],
        "input_sha256" => reference.manifest["input_sha256"],
        "build" => reference.manifest["build"],
        "historical_limitation" =>
            reference.manifest["legacy_mean_audit"]["status"],
    )
end

"Return whether the pinned CORPSE driver advances this cell's PFT."
corpse_active(cell) = cell.pft ∉ (11, 13, 15, 17)

function verify_collection_provenance(collection, manifest)
    source = manifest["source"]
    source["selected_fixture_sha256"] ==
    sha256sum(reference_cells().SELECTED_CELL_MANIFEST) ||
        error("Selected-cell manifest differs from the CORPSE reference source")
    fixture = collection.manifest["fixture"]
    for (source_key, fixture_key) in (
        ("forcing_sha256", "forcing"),
        ("grid_sha256", "grid"),
        ("soil_sha256", "soil"),
        ("casa_parameters_sha256", "casa_c_parameters"),
        ("corpse_parameters_sha256", "corpse_parameters"),
    )
        source[source_key] == fixture[fixture_key]["sha256"] || error(
            "Selected-cell $fixture_key differs from the CORPSE reference source",
        )
    end
    return nothing
end

function initial_state()
    rhizosphere =
        StaticArrays.SVector(0.0, 1.998, 0.0, 0.0, 0.0, 0.0, 0.002, 0.0, 2.0)
    empty = zero(rhizosphere)
    return (rhizosphere, empty, empty, empty)
end

function cell_metadata(collection, cell)
    metadata = only(
        filter(
            description -> Int(description["id"]) == cell.id,
            collection.manifest["cell"],
        ),
    )
    return (;
        qmax = CORPSE.mineral_protection_capacity(
            Float64(metadata["clay_fraction"]),
            Float64(metadata["porosity"]),
        ),
    )
end

function with_cell_reference(callback, reference, collection, cell)
    return NCDatasets.NCDataset(reference.path) do dataset
        cell_ids = Int.(dataset["cellid"][:])
        index = findfirst(==(cell.id), cell_ids)
        isnothing(index) &&
            error("Cell $(cell.id) is absent from CORPSE reference")
        Int(dataset["pft"][index]) == cell.pft ||
            error("CORPSE reference PFT mismatch for cell $(cell.id)")
        callback((; dataset, index, cell_metadata(collection, cell)...))
    end
end

function expected_pools(resource, day)
    dataset = resource.dataset
    index = resource.index
    pool_variables = (
        "soil_unprotected_labile",
        "soil_unprotected_recalcitrant",
        "soil_unprotected_dead_microbe",
        "soil_protected_labile",
        "soil_protected_recalcitrant",
        "soil_protected_dead_microbe",
    )
    pools = map(pool_variables) do name
        Float64(dataset[name][day, index])
    end
    microbe = Float64(dataset["soil_live_microbe"][day, index])
    return (pools..., microbe)
end

function actual_pools(state)
    pools = ntuple(6) do index
        1000 * (state[1][index] + state[2][index])
    end
    microbe = 1000 * (state[1][7] + state[2][7])
    return (pools..., microbe)
end

function compare_cell(resource)
    parameters = corpse_carbon_parameters(Float64)
    state = initial_state()
    continuous_state = state
    dataset = resource.dataset
    index = resource.index
    requested_exudate =
        0.02 * Float64(dataset["annual_npp"][index]) / 365 / 1000
    maximum_pool_error = 0.0
    maximum_respiration_error = 0.0
    maximum_moisture_error = 0.0
    maximum_continuous_pool_error = 0.0
    maximum_continuous_respiration_error = 0.0
    maximum_reference_pool = 0.0
    maximum_reference_respiration = 0.0
    final_state_error = 0.0

    for day in 1:365
        metabolic = Float64(dataset["metabolic_litter"][day, index]) / 1000
        recalcitrant =
            Float64(dataset["recalcitrant_litter"][day, index]) / 1000
        exudate = min(requested_exudate, metabolic)
        inputs = (;
            root_litter = StaticArrays.SVector(
                metabolic - exudate,
                recalcitrant,
                0.0,
            ),
            leaf_litter = StaticArrays.SVector(0.0, 0.0, 0.0),
            exudate = StaticArrays.SVector(exudate, 0.0, 0.0),
        )
        liquid = Float64(dataset["liquid_saturation"][day, index])
        frozen = Float64(dataset["frozen_saturation"][day, index])
        environment = (;
            rhizosphere_fraction = 0.3,
            temperature = Float64(dataset["soil_temperature"][day, index]),
            liquid_saturation = liquid,
            air_filled_porosity = max(0.0, 1 - liquid - frozen),
            qmax = resource.qmax,
            layer_thickness = 0.15,
        )
        mapped = CORPSE.daily_carbon_map(parameters, state, inputs, environment)
        state = mapped.state

        continuous_root_litter = inputs.root_litter / 86400
        continuous_exudate = inputs.exudate / 86400
        no_input = zero(continuous_exudate)
        continuous_co2_before = sum(cohort[8] for cohort in continuous_state)
        for _ in 1:96
            soil_rhiz_tendency = CORPSE.continuous_cohort_tendencies(
                parameters,
                continuous_state[1],
                continuous_root_litter,
                continuous_exudate,
                0.3,
                environment.temperature,
                environment.liquid_saturation,
                environment.air_filled_porosity,
                resource.qmax,
                environment.layer_thickness,
            )
            soil_bulk_tendency = CORPSE.continuous_cohort_tendencies(
                parameters,
                continuous_state[2],
                continuous_root_litter,
                no_input,
                0.7,
                environment.temperature,
                environment.liquid_saturation,
                environment.air_filled_porosity,
                resource.qmax,
                environment.layer_thickness,
            )
            continuous_state = (
                continuous_state[1] + 900 * soil_rhiz_tendency.state,
                continuous_state[2] + 900 * soil_bulk_tendency.state,
                continuous_state[3],
                continuous_state[4],
            )
        end

        expected = expected_pools(resource, day)
        expected_respiration = Float64(dataset["soil_respiration"][day, index])
        maximum_reference_pool =
            max(maximum_reference_pool, maximum(abs, expected))
        maximum_reference_respiration =
            max(maximum_reference_respiration, abs(expected_respiration))
        pool_error = maximum(abs.(actual_pools(state) .- expected))
        continuous_pool_error =
            maximum(abs.(actual_pools(continuous_state) .- expected))
        maximum_pool_error = max(maximum_pool_error, pool_error)
        maximum_continuous_pool_error =
            max(maximum_continuous_pool_error, continuous_pool_error)
        day == 365 && (final_state_error = pool_error)
        maximum_respiration_error = max(
            maximum_respiration_error,
            abs(1000 * mapped.respiration - expected_respiration),
        )
        continuous_respiration =
            1000 * (
                sum(cohort[8] for cohort in continuous_state) -
                continuous_co2_before
            )
        maximum_continuous_respiration_error = max(
            maximum_continuous_respiration_error,
            abs(continuous_respiration - expected_respiration),
        )
        maximum_moisture_error = max(
            maximum_moisture_error,
            abs(
                mapped.moisture -
                Float64(dataset["moisture_factor"][day, index]),
            ),
        )
    end

    legacy_daily = (;
        maximum_pool_error,
        maximum_respiration_error,
        maximum_moisture_error,
        final_state_error,
        all_match = maximum_pool_error < 2e-6 &&
                    maximum_respiration_error < 2e-8 &&
                    maximum_moisture_error < eps(Float64) &&
                    final_state_error < 2e-6,
    )
    maximum_relative_pool_error =
        maximum_continuous_pool_error / maximum_reference_pool
    maximum_relative_respiration_error =
        maximum_continuous_respiration_error / maximum_reference_respiration
    continuous_rate = (;
        maximum_pool_error = maximum_continuous_pool_error,
        maximum_respiration_error = maximum_continuous_respiration_error,
        maximum_relative_pool_error,
        maximum_relative_respiration_error,
        all_match = maximum_relative_pool_error < 1e-3 &&
                    maximum_relative_respiration_error < 1e-2,
    )
    value = (; legacy_daily, continuous_rate)
    return reference_cells().CellComparison(
        legacy_daily.all_match && continuous_rate.all_match,
        value,
    )
end

"Run the fresh-Fortran, LegacyDaily, and ContinuousRate CORPSE comparison."
function run_corpse_comparison(collection, budget; throw_on_failure = true)
    reference = verified_reference()
    verify_collection_provenance(collection, reference.manifest)
    comparison = reference_cells().ReferenceComparison(
        "CORPSE fresh-Fortran trajectory",
        (_, resource) -> compare_cell(resource);
        eligible = corpse_active,
        with_resource = (callback, cell) ->
            with_cell_reference(callback, reference, collection, cell),
    )
    return reference_cells().run_comparison(
        collection,
        comparison,
        budget;
        throw_on_failure,
    )
end

end
