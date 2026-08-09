if !isdefined(@__MODULE__, :TestbedNativeCORPSECReconstruction)
    include(joinpath(@__DIR__, "native_corpse_c_reconstruction.jl"))
end

module TestbedPinnedCORPSEExecutor

import ClimaLand
import NCDatasets
import TOML

native_corpse() =
    getfield(parentmodule(@__MODULE__), :TestbedNativeCORPSECReconstruction)
selected_corpse() = native_corpse().selected_corpse()
native_casa() = selected_corpse().native_casa()
native_workflow() = native_corpse().native_workflow()
reference_cells() = selected_corpse().reference_cells()
pinned_adapter() =
    getfield(parentmodule(@__MODULE__), :TestbedPinnedCORPSEAdapter)

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

function compare_boundary_summary(pairs, calibration, stage, full_population)
    full_population && return native_corpse().calibrated_boundary_summary(
        pairs,
        calibration,
        stage,
    )
    rules = calibration["stage"][String(stage.name)]
    padded = Dict(
        name => begin
            local_count = length(pair.actual)
            full_count = Int(rules[name]["finite_pair_count"])
            local_count <= full_count || error(
                "CORPSE shard exceeds its calibration population",
            )
            neutral = isempty(pair.expected) ? 0.0 : first(pair.expected)
            (
                actual = vcat(
                    pair.actual,
                    fill(neutral, full_count - local_count),
                ),
                expected = vcat(
                    pair.expected,
                    fill(neutral, full_count - local_count),
                ),
            )
        end for (name, pair) in pairs
    )
    report =
        native_corpse().calibrated_boundary_summary(padded, calibration, stage)
    for (name, record) in report
        record["values"] = length(pairs[name].actual)
    end
    return report
end

function compare_reduced_historical(
    candidate_path,
    reference_path,
    calibration;
    require_full_population = true,
)
    require_full_population &&
        return native_corpse().compare_reduced_historical(
            candidate_path,
            reference_path,
            calibration,
        )
    native = native_corpse()
    return NCDatasets.NCDataset(candidate_path) do candidate
        NCDatasets.NCDataset(reference_path) do reference
            candidate_ids = Int.(candidate["cell_id"][:])
            candidate_ids == sort(unique(candidate_ids)) ||
                error("reduced historical candidate cell order differs")
            reference_ids = Int.(reference["cell_id"][:])
            by_id =
                Dict(id => index for (index, id) in enumerate(reference_ids))
            all(id -> haskey(by_id, id), candidate_ids) ||
                error("reduced historical candidate has an unknown cell")
            positions = [by_id[id] for id in candidate_ids]
            candidate_mask = Bool.(candidate["eligible"][:])
            candidate_mask == Bool.(reference["eligible"][positions]) ||
                error("reduced historical eligibility masks differ")
            Int.(candidate["year"][:]) == Int.(reference["year"][:]) ||
                error("reduced historical year coordinates differ")
            Int.(candidate["sample_day"][:]) ==
            Int.(reference["sample_day"][:]) ||
                error("reduced historical sample coordinates differ")

            eligible = findall(candidate_mask)
            reference_rows = positions[eligible]
            rules = get(calibration, "reducer", Dict{String, Any}())
            result = Dict{String, Any}()
            for (reducer, variables) in (
                "annual_mean" => native.REDUCED_STATE_VARIABLES,
                "end_of_year" => native.REDUCED_STATE_VARIABLES,
                "annual_total" => native.REDUCED_FLUX_VARIABLES,
                "fixed_daily_sample" => native.REDUCED_VARIABLES,
            )
                names = getproperty.(variables, :name)
                reducer_rules = get(rules, reducer, nothing)
                reducer_rules isa AbstractDict ||
                    error("calibration is missing $reducer")
                Set(keys(reducer_rules)) == Set(names) ||
                    error("$reducer calibrated variables differ")
                result[reducer] = Dict(
                    name => begin
                        variable = "$(reducer)__$(name)"
                        description = only(
                            filter(item -> item.name == name, variables),
                        )
                        rule = reducer_rules[name]
                        get(rule, "units", nothing) ==
                        native.reduced_units(description, reducer) ||
                            error("$variable calibrated units differ")
                        actual = vec(
                            Float64.(candidate[variable][eligible, :]),
                        )
                        expected = vec(
                            Float64.(reference[variable][reference_rows, :]),
                        )
                        full_count = Int(rule["finite_pair_count"])
                        length(actual) <= full_count || error(
                            "CORPSE shard exceeds its calibration population",
                        )
                        neutral = isempty(expected) ? 0.0 : first(expected)
                        padding = full_count - length(actual)
                        record = native.calibrated_metrics(
                            vcat(actual, fill(neutral, padding)),
                            vcat(expected, fill(neutral, padding)),
                            rule,
                        )
                        record["values"] = length(actual)
                        record
                    end for name in names
                )
            end
            reduced_passed(result) ||
                error("CORPSE reduced history exceeds calibrated tolerance")
            return result
        end
    end
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
    cell_ids = nothing,
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
    pinned_adapter().verify_calibrated_boundaries(calibration, boundary_root)
    calibration_provenance = calibration["provenance"]
    calibration_provenance["fortran_reduced_historical"]["sha256"] ==
    native_workflow().sha256sum(bundle.reduced_history) ||
        error("Fortran reduced historical reference hash differs")
    calibration_provenance["fortran_reduced_historical_manifest"]["sha256"] ==
    native_workflow().sha256sum(bundle.reduced_history_manifest) ||
        error("Fortran reduced historical reference manifest hash differs")

    assigned_cell_ids = if isnothing(cell_ids)
        scope.cell_ids
    else
        assigned = Int.(cell_ids)
        !isempty(assigned) &&
        assigned == sort(unique(assigned)) &&
        all(id -> id in scope.cell_ids, assigned) || throw(
            ArgumentError("cell_ids must be a sorted nonempty scope subset"),
        )
        assigned
    end
    assigned_set = Set(assigned_cell_ids)
    assigned_gaps =
        Dict(id => pft for (id, pft) in scope.gaps if id in assigned_set)
    assigned_gap_entries =
        filter(gap -> Int(gap["cell_id"]) in assigned_set, scope.gap_entries)
    full_population = assigned_cell_ids == scope.cell_ids
    collection = reference_cells().selected_cell_collection(
        "representative",
        assigned_cell_ids;
        manifest_path = fixture_manifest,
    )
    setup = selected_corpse().load_complete_setup(collection)
    eligible = native_corpse().eligible_cell.(setup.grid)
    expected_eligible = length(assigned_cell_ids) - length(assigned_gaps)
    count(eligible) == expected_eligible ||
        error("Assigned CORPSE cells differ from reviewed eligibility")
    Dict(
        point.cell_id => point.pft for
        point in setup.grid if !native_corpse().eligible_cell(point)
    ) == assigned_gaps ||
        error("Assigned CORPSE gaps differ from reviewed gaps")

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
        comparison = compare_boundary_summary(
            native_corpse().boundary_pairs(
                current_state,
                stage,
                setup.grid,
                boundary_root,
            ),
            calibration,
            stage,
            full_population,
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
    reduced_comparison = compare_reduced_historical(
        reduced_path,
        bundle.reduced_history,
        calibration,
        require_full_population = full_population,
    )
    passed =
        all(
            stage_passed(report["comparison"]) for
            report in values(stage_reports)
        ) && reduced_passed(reduced_comparison)
    seconds = time() - started
    coverage = Dict(
        "scope_cells" => length(assigned_cell_ids),
        "eligible_cells" => expected_eligible,
        "compared_cells" => expected_eligible,
        "eligibility_gaps" => assigned_gap_entries,
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
