module TestbedMIMICSCNCalibration

import Statistics
import TOML

const SAFETY_FACTOR = 1.05

function right_derivative(relative, errors, references, absolute_floor)
    maximum_residual =
        maximum(errors[index] - relative * references[index] for index in eachindex(errors))
    maximum_value = max(absolute_floor, maximum_residual)
    derivative =
        maximum_value == absolute_floor ? Statistics.mean(references) : -Inf
    mean_reference = Statistics.mean(references)
    for index in eachindex(errors)
        errors[index] - relative * references[index] == maximum_value ||
            continue
        derivative = max(derivative, mean_reference - references[index])
    end
    return derivative
end

"""
    calibrated_envelope(actual, expected)

Fit the mixed absolute-relative envelope used by the MIMICS-CN policy. The raw
envelope minimizes `atol + rtol * mean(abs(expected))`; a 5% safety factor is
then applied without admitting nonfinite pairs.
"""
function calibrated_envelope(actual, expected)
    length(actual) == length(expected) && !isempty(actual) ||
        error("MIMICS-CN calibration requires nonempty aligned pairs")
    all(isfinite, actual) ||
        error("eligible Julia MIMICS-CN values contain a nonfinite value")
    all(isfinite, expected) ||
        error("eligible Fortran MIMICS-CN values contain a nonfinite value")
    references = abs.(Float64.(expected))
    actual_values = Float64.(actual)
    expected_values = Float64.(expected)
    errors = abs.(actual_values .- expected_values)
    float_padding =
        64eps(Float64) * max(
            maximum(abs, actual_values),
            maximum(abs, expected_values),
            floatmin(Float64),
        )
    relative = 0.0
    if right_derivative(relative, errors, references, 0.0) < 0
        upper = eps(Float64)
        while right_derivative(
            upper,
            errors,
            references,
            0.0,
        ) < 0
            upper *= 2
            isfinite(upper) ||
                error("unable to bracket MIMICS-CN relative tolerance")
        end
        lower = 0.0
        for _ in 1:256
            middle = (lower + upper) / 2
            if right_derivative(
                middle,
                errors,
                references,
                0.0,
            ) < 0
                lower = middle
            else
                upper = middle
            end
        end
        relative = upper
    end
    absolute = max(0.0, maximum(errors .- relative .* references))
    atol = SAFETY_FACTOR * absolute + float_padding
    rtol = SAFETY_FACTOR * relative
    failed = count(errors .> atol .+ rtol .* references)
    iszero(failed) ||
        error("derived MIMICS-CN tolerance does not enclose every pair")
    return (;
        atol,
        rtol,
        raw_atol = absolute,
        raw_rtol = relative,
        float_padding,
        errors,
        references,
        failed,
    )
end

function distribution(values)
    return Dict(
        "minimum" => minimum(values),
        "median" => Statistics.median(values),
        "p90" => Statistics.quantile(values, 0.90),
        "p95" => Statistics.quantile(values, 0.95),
        "p99" => Statistics.quantile(values, 0.99),
        "p999" => Statistics.quantile(values, 0.999),
        "maximum" => maximum(values),
        "mean" => Statistics.mean(values),
    )
end

function observation_record(observations, index)
    isnothing(observations) &&
        return Dict("observation_index" => index)
    value = observations[index]
    return Dict(String(name) => field for (name, field) in pairs(value))
end

function calibration_record(actual, expected; units, observations = nothing)
    isnothing(observations) ||
        length(observations) == length(actual) ||
        error("MIMICS-CN calibration observation metadata is not aligned")
    envelope = calibrated_envelope(actual, expected)
    nonzero = findall(value -> !iszero(value), envelope.references)
    relative_errors =
        envelope.errors[nonzero] ./ envelope.references[nonzero]
    residuals =
        envelope.errors .- envelope.raw_rtol .* envelope.references
    maximum_residual = maximum(residuals)
    active_tolerance =
        256eps(Float64) * max(abs(maximum_residual), floatmin(Float64))
    active = findall(
        residual -> isapprox(
            residual,
            maximum_residual;
            atol = active_tolerance,
            rtol = 0,
        ),
        residuals,
    )
    order = sortperm(envelope.errors; rev = true)
    top = [
        merge(
            Dict(
                "rank" => rank,
                "julia" => Float64(actual[index]),
                "fortran" => Float64(expected[index]),
                "absolute_error" => envelope.errors[index],
                "relative_error" =>
                    iszero(envelope.references[index]) ?
                    "undefined_zero_reference" :
                    envelope.errors[index] / envelope.references[index],
            ),
            observation_record(observations, index),
        ) for (rank, index) in
        enumerate(order[1:min(6, length(order))])
    ]
    return Dict(
        "finite_pair_count" => length(actual),
        "units" => units,
        "absolute_error" => distribution(envelope.errors),
        "absolute_reference" => distribution(envelope.references),
        "relative_error" => Dict(
            "zero_reference_count" =>
                length(envelope.references) - length(nonzero),
            "nonzero_reference_count" => length(nonzero),
            "distribution" =>
                isempty(relative_errors) ? Dict{String, Any}() :
                distribution(relative_errors),
        ),
        "active_constraint" => Dict(
            "count" => length(active),
            "observation" => [
                observation_record(observations, index) for
                index in active[1:min(6, length(active))]
            ],
        ),
        "top_outlier" => top,
        "derived_policy" => Dict(
            "atol" => envelope.atol,
            "rtol" => envelope.rtol,
            "raw_atol" => envelope.raw_atol,
            "raw_rtol" => envelope.raw_rtol,
            "float_padding" => envelope.float_padding,
            "raw_objective" =>
                envelope.raw_atol +
                envelope.raw_rtol * Statistics.mean(envelope.references),
            "validation_failed_pairs" => envelope.failed,
        ),
    )
end

function policy_record(record, location)
    get(record, "finite_pair_count", 0) > 0 ||
        error("$location has no finite calibration pairs")
    policy = get(record, "derived_policy", Dict{String, Any}())
    atol = get(policy, "atol", nothing)
    rtol = get(policy, "rtol", nothing)
    all(value -> value isa Real && isfinite(value) && value >= 0, (atol, rtol)) ||
        error("$location has an invalid derived policy")
    get(policy, "validation_failed_pairs", 1) == 0 ||
        error("$location does not enclose its calibration population")
    return Dict("atol" => atol, "rtol" => rtol)
end

"""
    comparison_policy(boundary_path, historical_path)

Consume the two immutable MIMICS-CN calibration manifests into the policy shape
used by the selected-cell workflow.
"""
function comparison_policy(boundary_path, historical_path)
    boundary = TOML.parsefile(boundary_path)
    historical = TOML.parsefile(historical_path)
    get(boundary, "model", "MIMICS-CN") == "MIMICS-CN" ||
        error("boundary calibration is not for MIMICS-CN")
    get(historical, "model", nothing) == "MIMICS-CN" ||
        error("historical calibration is not for MIMICS-CN")
    boundary_values = get(boundary, "variable", Dict{String, Any}())
    annual_values = get(historical, "annual", Dict{String, Any}())
    daily_values = get(historical, "daily", Dict{String, Any}())
    budget_value = get(historical, "budget", Dict{String, Any}())
    return Dict(
        "fresh_fortran_boundary" => Dict(
            stage => Dict(
                name => policy_record(
                    record,
                    "boundary.$stage.$name",
                ) for (name, record) in variables
            ) for (stage, variables) in boundary_values
        ),
        "fresh_fortran_annual" => Dict(
            reducer => Dict(
                name => policy_record(
                    record,
                    "annual.$reducer.$name",
                ) for (name, record) in variables
            ) for (reducer, variables) in annual_values
        ),
        "fresh_fortran_daily" => Dict(
            name => policy_record(record, "daily.$name") for
            (name, record) in daily_values
        ),
        "fresh_fortran_budget" => Dict(
            name => policy_record(record, "budget.$name") for
            (name, record) in budget_value
        ),
    )
end

end
