module ClassicFreeReplay

using ..ClassicTrajectoryBundle
import TOML

include("compensated_drift.jl")
include("day_one_gate.jl")
export FREE_REPLAY_AUDIT_SHAPES,
    FREE_REPLAY_UNITS, free_replay, write_replay_receipt

const FREE_REPLAY_AUDIT_SHAPES = (
    "audit.ltresveg" => zeros(1, 13, 20),
    "audit.scresveg" => zeros(1, 13, 20),
    "audit.humtrsvg" => zeros(1, 13, 20),
    "audit.hetrsveg" => zeros(1, 13),
    "audit.litres" => zeros(1),
    "audit.socres" => zeros(1),
    "audit.hetrores" => zeros(1),
    "audit.soilresp" => zeros(1),
    "audit.humiftrs" => zeros(1),
    "audit.litter_clamp_correction" => zeros(1, 13, 20),
    "audit.soil_clamp_correction" => zeros(1, 13, 20),
    "audit.turbation_delta_litter" => zeros(1, 13, 20),
    "audit.turbation_delta_soil" => zeros(1, 13, 20),
    "audit.turbation_litter_column_residual" => zeros(1, 13),
    "audit.turbation_soil_column_residual" => zeros(1, 13),
)

const FREE_REPLAY_UNITS = Dict(
    "reference.after_pool_update_litrmass" => "kg C m-2",
    "reference.after_pool_update_soilcmas" => "kg C m-2",
    "reference.before_turbation_litrmass" => "kg C m-2",
    "reference.before_turbation_soilcmas" => "kg C m-2",
    "reference.post_litrmass" => "kg C m-2",
    "reference.post_soilcmas" => "kg C m-2",
    "audit.ltresveg" => "umol CO2 m-2 s-1",
    "audit.scresveg" => "umol CO2 m-2 s-1",
    "audit.humtrsvg" => "umol CO2 m-2 s-1",
    "audit.hetrsveg" => "umol CO2 m-2 s-1",
    "audit.litres" => "umol CO2 m-2 s-1",
    "audit.socres" => "umol CO2 m-2 s-1",
    "audit.hetrores" => "umol CO2 m-2 s-1",
    "audit.soilresp" => "kg C m-2 step-1",
    "audit.humiftrs" => "umol CO2 m-2 s-1",
    "audit.litter_clamp_correction" => "kg C m-2",
    "audit.soil_clamp_correction" => "kg C m-2",
    "audit.turbation_delta_litter" => "kg C m-2 step-1",
    "audit.turbation_delta_soil" => "kg C m-2 step-1",
    "audit.turbation_litter_column_residual" => "kg C m-2",
    "audit.turbation_soil_column_residual" => "kg C m-2",
    "carbon_closure" => "kg C m-2 step-1",
    "accumulated_drift" => "kg C m-2",
)

const CHECKPOINT_NAMES = Set((
    "reference.after_pool_update_litrmass",
    "reference.after_pool_update_soilcmas",
    "reference.before_turbation_litrmass",
    "reference.before_turbation_soilcmas",
))

array_error(actual, expected) = maximum(abs.(actual .- expected); init = 0.0)

function validate_result(result, step)
    hasproperty(result, :state) ||
        throw(ArgumentError("transition result has no owned state"))
    hasproperty(result, :checkpoints) ||
        throw(ArgumentError("transition result has no state checkpoints"))
    hasproperty(result, :audits) ||
        throw(ArgumentError("transition result has no audit diagnostics"))
    Set(keys(result.state)) == Set(("litrmass", "soilcmas")) ||
        throw(ArgumentError("transition result has incomplete owned state"))
    Set(keys(result.checkpoints)) == CHECKPOINT_NAMES || throw(
        ArgumentError("transition result has incomplete state checkpoints"),
    )
    Set(keys(result.audits)) == Set(keys(step.audit_diagnostics)) || throw(
        ArgumentError("transition result has incomplete meaningful fluxes"),
    )
    size(result.state["litrmass"]) == (1, 13, 20) || throw(
        ArgumentError("transition litter state has incompatible dimensions"),
    )
    size(result.state["soilcmas"]) == (1, 13, 20) || throw(
        ArgumentError("transition soil state has incompatible dimensions"),
    )
    for (name, expected) in step.reference_state
        actual = if name == "reference.post_litrmass"
            result.state["litrmass"]
        elseif name == "reference.post_soilcmas"
            result.state["soilcmas"]
        else
            result.checkpoints[name]
        end
        size(actual) == size(expected) ||
            throw(ArgumentError("transition checkpoint dimensions differ"))
    end
    for (name, expected) in step.audit_diagnostics
        size(result.audits[name]) == size(expected) ||
            throw(ArgumentError("transition audit dimensions differ"))
    end
    return nothing
end

function forcing_carbon(drivers)
    return sum(
        sum(values) for (name, values) in drivers if
        occursin("_delta_litter", name) || occursin("_delta_soil", name);
        init = 0.0,
    )
end

function process_carbon_loss(audits, static_data)
    deltat = only(static_data["parameter.deltat_days"])
    spinfast = only(static_data["parameter.spinfast"])
    litter = audits["audit.ltresveg"]
    soil = audits["audit.scresveg"]
    humification = audits["audit.humtrsvg"]
    return sum(litter .+ humification .- spinfast .* (humification .- soil)) *
           deltat / 963.62
end

function clamp_carbon_correction(audits)
    return sum(audits["audit.litter_clamp_correction"]) +
           sum(audits["audit.soil_clamp_correction"])
end

function step_state_errors(result, reference)
    errors = Dict{String, Float64}()
    for (name, expected) in reference
        actual = if name == "reference.post_litrmass"
            result.state["litrmass"]
        elseif name == "reference.post_soilcmas"
            result.state["soilcmas"]
        else
            result.checkpoints[name]
        end
        errors[name] = array_error(actual, expected)
    end
    return errors
end

function step_flux_errors(result, reference)
    return Dict(
        name => array_error(result.audits[name], expected) for
        (name, expected) in reference
    )
end

function free_replay(
    replay::TrajectoryReplay,
    transition;
    atol = 0.0,
    rtol = 0.0,
    day_one_flux_tolerances = nothing,
    day_one_flux_tolerance_contract_sha256 = "",
)
    state = Dict(
        "litrmass" => copy(replay.initial_state["initial.litrmass"]),
        "soilcmas" => copy(replay.initial_state["initial.soilcmas"]),
    )
    step_reports = NamedTuple[]
    naive_accumulated_drift = 0.0
    accumulated_drift = 0.0
    drift_ledger = NeumaierAccumulator()
    max_state_error = 0.0
    max_flux_error = 0.0
    max_state_errors = Dict{String, Float64}()
    max_flux_errors = Dict{String, Float64}()
    for step in replay.steps
        pre_state = Dict(
            "litrmass" => copy(state["litrmass"]),
            "soilcmas" => copy(state["soilcmas"]),
        )
        stock_before = sum(pre_state["litrmass"]) + sum(pre_state["soilcmas"])
        result = transition(
            state,
            replay.static_data,
            step.drivers,
            step.time_start,
            step.time_end,
        )
        validate_result(result, step)
        state_errors = step_state_errors(result, step.reference_state)
        flux_errors = step_flux_errors(result, step.audit_diagnostics)
        state_error = maximum(values(state_errors); init = 0.0)
        flux_error = maximum(values(flux_errors); init = 0.0)
        stock_after =
            sum(result.state["litrmass"]) + sum(result.state["soilcmas"])
        carbon_closure =
            stock_after - stock_before - forcing_carbon(step.drivers) +
            process_carbon_loss(result.audits, replay.static_data) -
            clamp_carbon_correction(result.audits)
        naive_accumulated_drift += carbon_closure
        daily_roundoff = add_signed_primitive_ledger!(
            drift_ledger,
            pre_state,
            result,
            step.drivers,
            replay.static_data,
        )
        accumulated_drift = neumaier_value(drift_ledger)
        daily_roundoff_evidence = compensated_roundoff_evidence(
            daily_roundoff.term_count,
            daily_roundoff.term_scale,
        )
        daily_roundoff_threshold =
            max(Float64(atol), daily_roundoff_evidence.bound)
        daily_roundoff_ok = within_compensated_roundoff_bound(
            daily_roundoff.residual,
            daily_roundoff.term_count,
            daily_roundoff.term_scale,
            atol,
        )
        max_state_error = max(max_state_error, state_error)
        max_flux_error = max(max_flux_error, flux_error)
        for (name, error) in state_errors
            max_state_errors[name] =
                max(get(max_state_errors, name, 0.0), error)
        end
        for (name, error) in flux_errors
            max_flux_errors[name] = max(get(max_flux_errors, name, 0.0), error)
        end
        push!(
            step_reports,
            (;
                index = step.index,
                time_start = step.time_start,
                time_end = step.time_end,
                state_error,
                flux_error,
                state_errors,
                flux_errors,
                carbon_closure,
                compensated_carbon_closure = daily_roundoff.residual,
                naive_accumulated_drift,
                accumulated_drift,
                roundoff_term_count = daily_roundoff.term_count,
                roundoff_term_scale = daily_roundoff_evidence.raw_scale,
                roundoff_term_scale_upper = daily_roundoff_evidence.upper_scale,
                roundoff_scale_operation_count = daily_roundoff_evidence.scale_operation_count,
                roundoff_scale_gamma = daily_roundoff_evidence.scale_gamma,
                roundoff_operation_count = daily_roundoff_evidence.neumaier_operation_count,
                roundoff_gamma = daily_roundoff_evidence.neumaier_gamma,
                roundoff_bound = daily_roundoff_evidence.bound,
                roundoff_threshold = daily_roundoff_threshold,
                roundoff_residual = daily_roundoff.residual,
                roundoff_ratio = roundoff_ratio(
                    daily_roundoff.residual,
                    daily_roundoff_evidence.bound,
                ),
                roundoff_ok = daily_roundoff_ok,
            ),
        )
        state = Dict(
            "litrmass" => result.state["litrmass"],
            "soilcmas" => result.state["soilcmas"],
        )
    end
    scale = max(
        sum(abs, replay.initial_state["initial.litrmass"]) +
        sum(abs, replay.initial_state["initial.soilcmas"]),
        1.0,
    )
    threshold = atol + rtol * scale
    max_naive_carbon_closure =
        maximum((abs(step.carbon_closure) for step in step_reports); init = 0.0)
    max_carbon_closure = maximum(
        (abs(step.compensated_carbon_closure) for step in step_reports);
        init = 0.0,
    )
    drift_roundoff_evidence = compensated_roundoff_evidence(
        drift_ledger.term_count,
        drift_ledger.term_scale,
    )
    drift_roundoff_threshold = max(Float64(atol), drift_roundoff_evidence.bound)
    drift_roundoff_ratio =
        roundoff_ratio(accumulated_drift, drift_roundoff_evidence.bound)
    day_one = evaluate_day_one_gate(
        first(step_reports),
        day_one_flux_tolerances,
        day_one_flux_tolerance_contract_sha256,
    )
    day_one_exact = day_one.state_exact && day_one.flux_exact
    state_ok = max_state_error <= threshold
    flux_ok = max_flux_error <= threshold
    closure_ok = all(step.roundoff_ok for step in step_reports)
    drift_ok = within_compensated_roundoff_bound(
        accumulated_drift,
        drift_ledger.term_count,
        drift_ledger.term_scale,
        atol,
    )
    first_closure_exceedance =
        findfirst(!step.roundoff_ok for step in step_reports)
    max_closure_roundoff_ratio =
        maximum((step.roundoff_ratio for step in step_reports); init = 0.0)
    return (;
        ok = day_one.state_exact &&
             day_one.flux_within_tolerance &&
             state_ok &&
             flux_ok &&
             closure_ok &&
             drift_ok,
        initialization_count = 1,
        recurrent_state_replacements = 0,
        steps = step_reports,
        max_state_error,
        max_flux_error,
        max_state_errors,
        max_flux_errors,
        max_carbon_closure,
        max_naive_carbon_closure,
        naive_accumulated_drift,
        accumulated_drift,
        drift_algorithm = DRIFT_ALGORITHM,
        drift_algorithm_version = DRIFT_ALGORITHM_VERSION,
        drift_oracle_conversion = DRIFT_ORACLE_CONVERSION,
        drift_term_count = drift_ledger.term_count,
        drift_term_scale = drift_ledger.term_scale,
        roundoff_bound_formula = COMPENSATED_ROUNDOFF_BOUND_FORMULA,
        roundoff_bound_version = COMPENSATED_ROUNDOFF_BOUND_VERSION,
        roundoff_unit_roundoff = FLOAT64_UNIT_ROUNDOFF,
        roundoff_oracle_conversion = DRIFT_ORACLE_CONVERSION,
        roundoff_bound_assumptions = COMPENSATED_ROUNDOFF_BOUND_ASSUMPTIONS,
        closure_first_exceedance_index = isnothing(first_closure_exceedance) ?
                                         0 :
                                         step_reports[first_closure_exceedance].index,
        max_closure_roundoff_ratio,
        drift_roundoff_term_count = drift_ledger.term_count,
        drift_roundoff_term_scale = drift_roundoff_evidence.raw_scale,
        drift_roundoff_term_scale_upper = drift_roundoff_evidence.upper_scale,
        drift_roundoff_scale_operation_count = drift_roundoff_evidence.scale_operation_count,
        drift_roundoff_scale_gamma = drift_roundoff_evidence.scale_gamma,
        drift_roundoff_operation_count = drift_roundoff_evidence.neumaier_operation_count,
        drift_roundoff_gamma = drift_roundoff_evidence.neumaier_gamma,
        drift_roundoff_bound = drift_roundoff_evidence.bound,
        drift_roundoff_threshold,
        drift_roundoff_residual = accumulated_drift,
        drift_roundoff_ratio,
        day_one_exact,
        day_one_state_exact = day_one.state_exact,
        day_one_flux_within_tolerance = day_one.flux_within_tolerance,
        day_one_flux_tolerances = day_one.flux_tolerances,
        day_one_flux_tolerance_contract_sha256 = day_one.tolerance_contract_sha256,
        state_ok,
        flux_ok,
        closure_ok,
        drift_ok,
        tolerances = (; atol, rtol),
    )
end

function write_replay_receipt(
    path,
    report,
    bundle_manifest_sha256;
    tolerance_rationale = "",
)
    ispath(path) && throw(ArgumentError("replay receipt already exists"))
    ClassicTrajectoryBundle.valid_sha256(bundle_manifest_sha256) ||
        throw(ArgumentError("bundle manifest SHA-256 is invalid"))
    steps = [
        Dict(
            "index" => step.index,
            "time_start" => string(step.time_start),
            "time_end" => string(step.time_end),
            "state_error" => step.state_error,
            "flux_error" => step.flux_error,
            "carbon_closure" => step.carbon_closure,
            "compensated_carbon_closure" => step.compensated_carbon_closure,
            "naive_accumulated_drift" => step.naive_accumulated_drift,
            "accumulated_drift" => step.accumulated_drift,
            "roundoff_term_count" => step.roundoff_term_count,
            "roundoff_term_scale" => step.roundoff_term_scale,
            "roundoff_bound" => step.roundoff_bound,
            "roundoff_threshold" => step.roundoff_threshold,
            "roundoff_residual" => step.roundoff_residual,
            "roundoff_ratio" => step.roundoff_ratio,
            "roundoff_term_scale_upper" => step.roundoff_term_scale_upper,
            "roundoff_scale_operation_count" =>
                step.roundoff_scale_operation_count,
            "roundoff_scale_gamma" => step.roundoff_scale_gamma,
            "roundoff_operation_count" => step.roundoff_operation_count,
            "roundoff_gamma" => step.roundoff_gamma,
            "roundoff_ok" => step.roundoff_ok,
            "state_errors" => step.state_errors,
            "flux_errors" => step.flux_errors,
        ) for step in report.steps
    ]
    receipt = Dict(
        "schema_version" => 1,
        "status" => report.ok ? "pass" : "fail",
        "bundle_manifest_sha256" => bundle_manifest_sha256,
        "initialization_count" => report.initialization_count,
        "recurrent_state_replacements" =>
            report.recurrent_state_replacements,
        "max_state_error" => report.max_state_error,
        "max_flux_error" => report.max_flux_error,
        "max_state_errors" => report.max_state_errors,
        "max_flux_errors" => report.max_flux_errors,
        "max_carbon_closure" => report.max_carbon_closure,
        "max_naive_carbon_closure" => report.max_naive_carbon_closure,
        "naive_accumulated_drift" => report.naive_accumulated_drift,
        "accumulated_drift" => report.accumulated_drift,
        "drift_algorithm" => report.drift_algorithm,
        "drift_algorithm_version" => report.drift_algorithm_version,
        "drift_oracle_conversion" => report.drift_oracle_conversion,
        "drift_term_count" => report.drift_term_count,
        "drift_term_scale" => report.drift_term_scale,
        "roundoff_bound_formula" => report.roundoff_bound_formula,
        "roundoff_bound_version" => report.roundoff_bound_version,
        "roundoff_unit_roundoff" => report.roundoff_unit_roundoff,
        "roundoff_oracle_conversion" => report.roundoff_oracle_conversion,
        "closure_first_exceedance_index" =>
            report.closure_first_exceedance_index,
        "max_closure_roundoff_ratio" => report.max_closure_roundoff_ratio,
        "roundoff_bound_assumptions" => report.roundoff_bound_assumptions,
        "drift_roundoff_term_count" => report.drift_roundoff_term_count,
        "drift_roundoff_term_scale" => report.drift_roundoff_term_scale,
        "drift_roundoff_bound" => report.drift_roundoff_bound,
        "drift_roundoff_threshold" => report.drift_roundoff_threshold,
        "drift_roundoff_residual" => report.drift_roundoff_residual,
        "drift_roundoff_ratio" => report.drift_roundoff_ratio,
        "atol" => report.tolerances.atol,
        "rtol" => report.tolerances.rtol,
        "drift_roundoff_term_scale_upper" =>
            report.drift_roundoff_term_scale_upper,
        "drift_roundoff_scale_operation_count" =>
            report.drift_roundoff_scale_operation_count,
        "drift_roundoff_scale_gamma" => report.drift_roundoff_scale_gamma,
        "drift_roundoff_operation_count" =>
            report.drift_roundoff_operation_count,
        "drift_roundoff_gamma" => report.drift_roundoff_gamma,
        "tolerance_rationale" => tolerance_rationale,
        "day_one_exact" => report.day_one_exact,
        "day_one_state_exact" => report.day_one_state_exact,
        "day_one_flux_within_tolerance" =>
            report.day_one_flux_within_tolerance,
        "day_one_flux_tolerances" => report.day_one_flux_tolerances,
        "day_one_flux_tolerance_contract_sha256" =>
            report.day_one_flux_tolerance_contract_sha256,
        "state_ok" => report.state_ok,
        "flux_ok" => report.flux_ok,
        "closure_ok" => report.closure_ok,
        "drift_ok" => report.drift_ok,
        "units" => FREE_REPLAY_UNITS,
        "step" => steps,
    )
    open(path, "w") do io
        TOML.print(io, receipt; sorted = true)
    end
    return path
end

end
