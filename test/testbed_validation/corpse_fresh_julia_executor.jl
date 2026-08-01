if !isdefined(@__MODULE__, :TestbedPinnedCORPSEExecutor)
    include(joinpath(@__DIR__, "pinned_corpse_executor.jl"))
end

module TestbedCORPSEFreshJuliaExecutor

import ClimaLand
import TOML

const Pinned = getfield(parentmodule(@__MODULE__), :TestbedPinnedCORPSEExecutor)
native_corpse() = Pinned.native_corpse()
selected_corpse() = Pinned.selected_corpse()
native_casa() = Pinned.native_casa()
native_workflow() = Pinned.native_workflow()
reference_cells() = Pinned.reference_cells()

function noleap_date(stage, step)
    forcing_days = stage.forcing_days
    index = mod1(step, forcing_days)
    year = 1901 + div(index - 1, 365)
    day = mod1(index, 365)
    lengths = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
    month = 1
    while day > lengths[month]
        day -= lengths[month]
        month += 1
    end
    return "$(lpad(year, 4, '0'))-$(lpad(month, 2, '0'))-$(lpad(day, 2, '0'))"
end

const FINITE_OBSERVATION = Dict{String, Vector{Float64}}()

function nonfinite_values(state, parameters)
    values = Dict{String, Any}()
    for component in propertynames(state)
        component_state = getproperty(state, component)
        for variable in propertynames(component_state)
            data = getproperty(component_state, variable)
            vector = try
                vec(parent(data))
            catch
                continue
            end
            all(isfinite, vector) || (values["$component.$variable"] = vector)
        end
    end
    for description in native_corpse().REDUCED_VARIABLES
        parts = native_corpse().reduced_field(description, state, parameters)
        bad = any(eachindex(first(parts))) do index
            value = description.scale * sum(part[index] for part in parts)
            !isfinite(value)
        end
        if bad
            combined = description.scale .* copy(first(parts))
            for part in parts[2:end]
                combined .+= description.scale .* part
            end
            values["diagnostic.$(description.name)"] = combined
        end
    end
    return values
end

struct ObservedAfterStep{S, A, R, O}
    stoichiometry::S
    annual_npp::A
    reduced::R
    observer::O
end

function (callback::ObservedAfterStep)(stage, step, state, parameters, time)
    native_casa().update_stoichiometry!(callback.stoichiometry, state)
    selected_corpse().accumulate_annual_npp!(callback.annual_npp, parameters)
    callback.reduced(stage, step, state, parameters, time)
    nonfinite = nonfinite_values(state, parameters)
    callback.observer(
        String(stage.name),
        step,
        noleap_date(stage, step),
        isempty(nonfinite) ? FINITE_OBSERVATION : nonfinite,
    )
    return nothing
end

function execute(
    output_root;
    boundary_root,
    reduced_reference,
    fixture_manifest,
    scope_manifest,
    calibration_manifest,
    observer,
)
    native_corpse().assert_single_threaded()
    scope = native_corpse().representative_scope(scope_manifest)
    calibration = native_corpse().calibration_policy(calibration_manifest)
    collection = reference_cells().selected_cell_collection(
        "representative",
        scope.cell_ids;
        manifest_path = fixture_manifest,
    )
    setup = selected_corpse().load_complete_setup(collection)
    eligible = native_corpse().eligible_cell.(setup.grid)
    count(eligible) == 78 || error("Representative CORPSE must have 78 eligible cells")

    stoichiometry =
        native_casa().CarbonOnlyPlantStoichiometry(setup.grid, setup.parameters)
    annual_npp = selected_corpse().AnnualNPPTracker(setup.buffers)
    reduced = native_corpse().ReducedCORPSEHistorical(length(setup.grid))
    forcing_callback = Pinned.PackedForcingCallback(
        setup.forcing,
        stoichiometry,
        setup.model,
        annual_npp,
    )
    after_step_callback =
        ObservedAfterStep(stoichiometry, annual_npp, reduced, observer)
    current_state = setup.initial_state
    initial_totals = selected_corpse().corpse_carbon_totals(current_state)
    workflow_inputs = zero(initial_totals.active)
    workflow_respiration = zero(initial_totals.active)
    stage_reports = Dict{String, Any}()
    started = time()

    for stage in native_corpse().canonical_stages()
        restart_transform = if stage.name == :prespin
            (; verified = true)
        else
            before = selected_corpse().corpse_carbon_totals(current_state)
            selected_corpse().rebase_corpse_stage!(current_state)
            native_casa().restore_stoichiometry!(stoichiometry, current_state)
            selected_corpse().rebase_conservation(
                before,
                selected_corpse().corpse_carbon_totals(current_state),
            )
        end
        restart_transform.verified ||
            error("CORPSE $(stage.name) restart transform is not conservative")
        start_totals = selected_corpse().corpse_carbon_totals(current_state)
        result = native_workflow().run_workflow(
            setup.model,
            current_state,
            [stage],
            joinpath(output_root, "stages", String(stage.name));
            update_forcing! = forcing_callback,
            after_step! = after_step_callback,
            diagnostics = (),
            provenance = Pinned.stage_provenance(setup, stage, boundary_root),
        )
        isfile(result.output) && rm(result.output)
        end_totals = selected_corpse().corpse_carbon_totals(result.state)
        workflow_inputs .+= end_totals.original .- start_totals.original
        workflow_respiration .+= end_totals.cumulative .- start_totals.cumulative
        checkpoint = only(result.checkpoints)
        checkpoint_state, _ =
            ClimaLand.read_checkpoint(checkpoint; model = setup.model)
        current_state =
            native_casa().state_as_initial_state(checkpoint_state, setup.model)
        handoff = selected_corpse().carbon_handoff(
            end_totals,
            selected_corpse().corpse_carbon_totals(current_state),
        )
        conservation = selected_corpse().corpse_conservation(current_state)
        handoff.verified || error("CORPSE $(stage.name) checkpoint handoff failed")
        conservation.verified || error("CORPSE $(stage.name) conservation failed")
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
            "restart_transform_verified" => true,
            "checkpoint_handoff_verified" => true,
            "conservation_verified" => true,
        )
    end

    final_totals = selected_corpse().corpse_carbon_totals(current_state)
    residual = initial_totals.active .+ workflow_inputs .-
               workflow_respiration .- final_totals.active
    maximum_residual = maximum(abs, residual)
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
        reduced_reference,
        calibration,
    )
    passed = all(
        Pinned.stage_passed(report["comparison"]) for report in values(stage_reports)
    ) && Pinned.reduced_passed(reduced_comparison)
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
        "seconds" => time() - started,
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
            "fixed_daily_samples" => reduced_comparison["fixed_daily_sample"],
        ),
        "calibration" => Dict(
            "id" => calibration["calibration_id"],
            "sha256" => native_workflow().sha256sum(calibration_manifest),
        ),
    )
    mkpath(output_root)
    report_path = joinpath(output_root, "corpse_comparison_report.toml")
    open(report_path, "w") do io
        TOML.print(io, report; sorted = true)
    end
    return (; passed, report = report_path, seconds = report["seconds"], coverage)
end

end
