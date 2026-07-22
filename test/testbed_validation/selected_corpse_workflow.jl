if !isdefined(@__MODULE__, :TestbedSelectedCellFixtures)
    include(joinpath(@__DIR__, "selected_cell_fixtures.jl"))
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

using ..TestCORPSEParameters: corpse_carbon_parameters

const CORPSE = ClimaLand.Soil.Biogeochemistry.CORPSE
const REFERENCE_MANIFEST =
    joinpath(@__DIR__, "fixtures", "selected_corpse", "fixture.toml")
const WORKFLOW_REFERENCE_MANIFEST =
    joinpath(@__DIR__, "fixtures", "selected_corpse", "complete_workflow.toml")

reference_cells() =
    getfield(parentmodule(@__MODULE__), :TestbedReferenceCellComparisons)

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
