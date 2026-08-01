if !isdefined(@__MODULE__, :TestbedNativeCORPSECReconstruction)
    include(joinpath(@__DIR__, "native_corpse_c_reconstruction.jl"))
end

module TestbedPinnedCORPSEExecutor

import ClimaLand
import TOML

native_corpse() =
    getfield(parentmodule(@__MODULE__), :TestbedNativeCORPSECReconstruction)
selected_corpse() = native_corpse().selected_corpse()
native_casa() = selected_corpse().native_casa()
native_workflow() = native_corpse().native_workflow()
reference_cells() = selected_corpse().reference_cells()

struct PackedForcingCallback{F, S, M, A}
    forcing::F
    stoichiometry::S
    model::M
    annual_npp::A
end

function (callback::PackedForcingCallback)(stage, index, time)
    selected_corpse().update_forcing!(callback.forcing, stage, index, time)
    native_casa().apply_stoichiometry!(callback.stoichiometry, callback.model)
    selected_corpse().prepare_annual_npp!(
        callback.annual_npp,
        callback.forcing,
        stage,
        index,
    )
    return nothing
end

struct PackedAfterStepCallback{S, A, R}
    stoichiometry::S
    annual_npp::A
    reduced::R
end

function (callback::PackedAfterStepCallback)(
    stage,
    step,
    state,
    parameters,
    time,
)
    native_casa().update_stoichiometry!(callback.stoichiometry, state)
    selected_corpse().accumulate_annual_npp!(callback.annual_npp, parameters)
    callback.reduced(stage, step, state, parameters, time)
    return nothing
end

function stage_provenance(setup, stage, boundary_root)
    return Dict(
        "model" => "ClimaLand integrated CASA-CORPSE LegacyDaily",
        "configuration" => "pinned Representative CORPSE comparison",
        "pft" => "immutable Representative-80 scope",
        "parameter_file" => Dict(
            "source" => abspath(setup.files["casa_c_parameters"]),
            "sha256" => native_workflow().sha256sum(
                setup.files["casa_c_parameters"],
            ),
        ),
        "forcing" => [
            Dict(
                "stage" => String(stage.name),
                "source" => abspath(setup.files["forcing"]),
                "sha256" =>
                    native_workflow().sha256sum(setup.files["forcing"]),
                "boundary_reference" => abspath(boundary_root),
            ),
        ],
    )
end

function stage_passed(comparison)
    return all(record["all_match"] for record in values(comparison))
end

function reduced_passed(comparison)
    return all(
        record["all_match"] for records in values(comparison) for
        record in values(records)
    )
end

"""
    execute(output_root; bundle, boundary_root, fixture_manifest,
            scope_manifest, workers)

Run the calibrated four-stage Representative CORPSE comparison from the
verified packed forcing, exact boundary archive, and reduced historical oracle.
"""
function execute(
    output_root;
    bundle,
    boundary_root,
    fixture_manifest,
    scope_manifest,
    workers,
)
    workers isa Integer && workers > 0 ||
        throw(ArgumentError("workers must be positive"))
    native_corpse().assert_single_threaded()
    scope = native_corpse().representative_scope(scope_manifest)
    calibration_path = joinpath(
        @__DIR__,
        "validation",
        "corpse_c_representative_calibration.toml",
    )
    calibration = native_corpse().calibration_policy(calibration_path)
    native_corpse().verify_boundary_reference(calibration, boundary_root)
    calibration_provenance = calibration["provenance"]
    calibration_provenance["fortran_reduced_historical"]["sha256"] ==
    native_workflow().sha256sum(bundle.reduced_history) ||
        error("Fortran reduced historical reference hash differs")
    calibration_provenance["fortran_reduced_historical_manifest"]["sha256"] ==
    native_workflow().sha256sum(bundle.reduced_history_manifest) ||
        error("Fortran reduced historical reference manifest hash differs")

    collection = reference_cells().selected_cell_collection(
        "representative",
        scope.cell_ids;
        manifest_path = fixture_manifest,
    )
    setup = selected_corpse().load_complete_setup(collection)
    eligible = native_corpse().eligible_cell.(setup.grid)
    count(eligible) == 78 ||
        error("Representative CORPSE must have 78 eligible cells")
    Dict(
        point.cell_id => point.pft for
        point in setup.grid if !native_corpse().eligible_cell(point)
    ) == scope.gaps ||
        error("Representative CORPSE gaps differ from reviewed gaps")

    stoichiometry =
        native_casa().CarbonOnlyPlantStoichiometry(setup.grid, setup.parameters)
    annual_npp = selected_corpse().AnnualNPPTracker(setup.buffers)
    reduced = native_corpse().ReducedCORPSEHistorical(length(setup.grid))
    forcing_callback = PackedForcingCallback(
        setup.forcing,
        stoichiometry,
        setup.model,
        annual_npp,
    )
    after_step_callback =
        PackedAfterStepCallback(stoichiometry, annual_npp, reduced)
    current_state = setup.initial_state
    initial_totals = selected_corpse().corpse_carbon_totals(current_state)
    workflow_inputs = zero(initial_totals.active)
    workflow_respiration = zero(initial_totals.active)
    stage_reports = Dict{String, Any}()
    started = time()

    for stage in native_corpse().canonical_stages()
        restart_transform = if stage.name == :prespin
            (; maximum_residual = 0.0, tolerance = 2e-12, verified = true)
        else
            before_rebase =
                selected_corpse().corpse_carbon_totals(current_state)
            selected_corpse().rebase_corpse_stage!(current_state)
            native_casa().restore_stoichiometry!(stoichiometry, current_state)
            selected_corpse().rebase_conservation(
                before_rebase,
                selected_corpse().corpse_carbon_totals(current_state),
            )
        end
        restart_transform.verified ||
            error("CORPSE $(stage.name) restart transform is not conservative")
        stage_start_totals =
            selected_corpse().corpse_carbon_totals(current_state)
        result = native_workflow().run_workflow(
            setup.model,
            current_state,
            [stage],
            joinpath(output_root, "stages", String(stage.name));
            update_forcing! = forcing_callback,
            after_step! = after_step_callback,
            diagnostics = (),
            provenance = stage_provenance(setup, stage, boundary_root),
        )
        isfile(result.output) && rm(result.output)
        stage_end_totals = selected_corpse().corpse_carbon_totals(result.state)
        workflow_inputs .+=
            stage_end_totals.original .- stage_start_totals.original
        workflow_respiration .+=
            stage_end_totals.cumulative .- stage_start_totals.cumulative
        checkpoint = only(result.checkpoints)
        checkpoint_state, _ =
            ClimaLand.read_checkpoint(checkpoint; model = setup.model)
        current_state =
            native_casa().state_as_initial_state(checkpoint_state, setup.model)
        handoff = selected_corpse().carbon_handoff(
            stage_end_totals,
            selected_corpse().corpse_carbon_totals(current_state),
        )
        conservation = selected_corpse().corpse_conservation(current_state)
        handoff.verified ||
            error("CORPSE $(stage.name) checkpoint handoff is not conservative")
        conservation.verified ||
            error("CORPSE $(stage.name) state violates conservation")
        comparison = native_corpse().calibrated_boundary_summary(
            native_corpse().boundary_pairs(
                current_state,
                stage,
                setup.grid,
                boundary_root,
            ),
            calibration,
            stage,
        )
        stage_reports[String(stage.name)] = Dict(
            "comparison" => comparison,
            "checkpoint_sha256" => native_workflow().sha256sum(checkpoint),
            "restart_transform_verified" => restart_transform.verified,
            "checkpoint_handoff_verified" => handoff.verified,
            "conservation_verified" => conservation.verified,
        )
    end

    final_totals = selected_corpse().corpse_carbon_totals(current_state)
    workflow_residual =
        initial_totals.active .+ workflow_inputs .- workflow_respiration .-
        final_totals.active
    maximum_residual = maximum(abs, workflow_residual)
    maximum_residual <= 2e-11 ||
        error("CORPSE full-workflow conservation tolerance exceeded")
    reduced_path = native_corpse().write_reduced_historical(
        joinpath(output_root, "reduced_historical.nc"),
        reduced,
        setup.grid,
        eligible,
    )
    reduced_comparison = native_corpse().compare_reduced_historical(
        reduced_path,
        bundle.reduced_history,
        calibration,
    )
    passed =
        all(
            stage_passed(report["comparison"]) for
            report in values(stage_reports)
        ) && reduced_passed(reduced_comparison)
    seconds = time() - started
    coverage = Dict(
        "scope_cells" => 80,
        "eligible_cells" => 78,
        "compared_cells" => 78,
        "eligibility_gaps" => scope.gap_entries,
    )
    report = Dict(
        "schema_version" => 1,
        "model" => "CORPSE",
        "scope" => "representative",
        "outcome" => passed ? "passed" : "failed",
        "seconds" => seconds,
        "coverage" => coverage,
        "budget" => Dict(
            "maximum_absolute_residual_kg_c_m2" => maximum_residual,
            "tolerance_kg_c_m2" => 2e-11,
            "verified" => true,
        ),
        "stage" => stage_reports,
        "reduced_historical" => Dict(
            "annual_summaries" => reduced_comparison["annual_mean"],
            "end_of_year" => reduced_comparison["end_of_year"],
            "annual_budgets" => reduced_comparison["annual_total"],
            "fixed_daily_samples" =>
                reduced_comparison["fixed_daily_sample"],
        ),
        "calibration" => Dict(
            "id" => calibration["calibration_id"],
            "sha256" => native_workflow().sha256sum(calibration_path),
        ),
    )
    mkpath(output_root)
    report_path = joinpath(output_root, "corpse_comparison_report.toml")
    open(report_path, "w") do io
        TOML.print(io, report; sorted = true)
    end
    return (; passed, report = report_path, seconds, coverage)
end

end
