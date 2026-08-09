const DRIFT_ALGORITHM = "neumaier_signed_primitive_ledger"
const DRIFT_ALGORITHM_VERSION = 1
const DRIFT_ORACLE_CONVERSION = "Float64 primitive terms; BigFloat summation oracle"
const FLOAT64_UNIT_ROUNDOFF = 2.0^-53
const COMPENSATED_ROUNDOFF_BOUND_FORMULA = "up((2u + gamma_(4n+1)^2) * S_upper)"
const COMPENSATED_ROUNDOFF_BOUND_VERSION = 1
const COMPENSATED_ROUNDOFF_BOUND_ASSUMPTIONS =
    "IEEE binary64 round-to-nearest; finite normal intermediates; no overflow; " *
    "(n-1)u < 1; compensated diagnostic over already-rounded primitive terms " *
    "only, not a forward-error proof of primitive generation"

function gamma_upper(operation_count::Integer)
    operation_count >= 0 ||
        throw(ArgumentError("operation count must be nonnegative"))
    exact = setprecision(BigFloat, 256) do
        ku = BigFloat(operation_count) * BigFloat(FLOAT64_UNIT_ROUNDOFF)
        ku < 1 || throw(ArgumentError("roundoff bound requires ku < 1"))
        ku / (1 - ku)
    end
    return Float64(exact, RoundUp)
end

function compensated_roundoff_evidence(term_count::Integer, term_scale::Real)
    term_count >= 0 || throw(ArgumentError("term count must be nonnegative"))
    raw_scale = Float64(term_scale)
    isfinite(raw_scale) && raw_scale >= 0.0 ||
        throw(ArgumentError("term scale must be finite and nonnegative"))
    scale_operation_count = max(term_count - 1, 0)
    scale_gamma = gamma_upper(scale_operation_count)
    upper_scale =
        raw_scale == 0.0 ? 0.0 : nextfloat(raw_scale / (1.0 - scale_gamma))
    isfinite(upper_scale) || throw(ArgumentError("upper term scale overflowed"))
    neumaier_operation_count = 4 * term_count + 1
    neumaier_gamma = gamma_upper(neumaier_operation_count)
    exact_bound = setprecision(BigFloat, 256) do
        (2 * BigFloat(FLOAT64_UNIT_ROUNDOFF) + BigFloat(neumaier_gamma)^2) *
        BigFloat(upper_scale)
    end
    bound = exact_bound == 0 ? 0.0 : nextfloat(Float64(exact_bound, RoundUp))
    isfinite(bound) || throw(ArgumentError("roundoff bound overflowed"))
    return (;
        term_count,
        raw_scale,
        upper_scale,
        scale_operation_count,
        scale_gamma,
        neumaier_operation_count,
        neumaier_gamma,
        bound,
    )
end

compensated_roundoff_bound(term_count::Integer, term_scale::Real) =
    compensated_roundoff_evidence(term_count, term_scale).bound

function within_compensated_roundoff_bound(
    residual::Real,
    term_count::Integer,
    term_scale::Real,
    user_atol::Real,
)
    value = Float64(residual)
    atol = Float64(user_atol)
    isfinite(value) || return false
    isfinite(atol) && atol >= 0.0 ||
        throw(ArgumentError("user atol must be finite and nonnegative"))
    bound = compensated_roundoff_bound(term_count, term_scale)
    return abs(value) <= max(atol, bound)
end

function roundoff_ratio(residual, bound)
    bound == 0.0 && return residual == 0.0 ? 0.0 : Inf
    return abs(residual) / bound
end

mutable struct NeumaierAccumulator
    total::Float64
    correction::Float64
    term_count::Int
    term_scale::Float64
end

NeumaierAccumulator() = NeumaierAccumulator(0.0, 0.0, 0, 0.0)

function add_term!(accumulator::NeumaierAccumulator, value)
    term = Float64(value)
    total = accumulator.total + term
    if abs(accumulator.total) >= abs(term)
        accumulator.correction += (accumulator.total - total) + term
    else
        accumulator.correction += (term - total) + accumulator.total
    end
    accumulator.total = total
    accumulator.term_count += 1
    accumulator.term_scale += abs(term)
    return accumulator
end

neumaier_value(accumulator::NeumaierAccumulator) =
    accumulator.total + accumulator.correction

function neumaier_sum(values)
    accumulator = NeumaierAccumulator()
    for value in values
        add_term!(accumulator, value)
    end
    return neumaier_value(accumulator)
end

function add_to_ledgers!(daily, seasonal, value)
    add_term!(daily, value)
    add_term!(seasonal, value)
    return nothing
end

function add_signed_primitive_ledger!(
    seasonal,
    state,
    result,
    drivers,
    static_data,
)
    daily = NeumaierAccumulator()
    for pool in (result.state["litrmass"], result.state["soilcmas"])
        for value in pool
            add_to_ledgers!(daily, seasonal, value)
        end
    end
    for pool in (state["litrmass"], state["soilcmas"])
        for value in pool
            add_to_ledgers!(daily, seasonal, -value)
        end
    end
    for (name, values) in drivers
        if occursin("_delta_litter", name) || occursin("_delta_soil", name)
            for value in values
                add_to_ledgers!(daily, seasonal, -value)
            end
        end
    end
    deltat = Float64(only(static_data["parameter.deltat_days"]))
    spinfast = Float64(only(static_data["parameter.spinfast"]))
    factor = deltat / 963.62
    for (litter, humification, soil) in zip(
        result.audits["audit.ltresveg"],
        result.audits["audit.humtrsvg"],
        result.audits["audit.scresveg"],
    )
        process_loss =
            (litter + humification - spinfast * (humification - soil)) * factor
        add_to_ledgers!(daily, seasonal, process_loss)
    end
    for correction in (
        result.audits["audit.litter_clamp_correction"],
        result.audits["audit.soil_clamp_correction"],
    )
        for value in correction
            add_to_ledgers!(daily, seasonal, -value)
        end
    end
    return (;
        residual = neumaier_value(daily),
        term_count = daily.term_count,
        term_scale = daily.term_scale,
    )
end
