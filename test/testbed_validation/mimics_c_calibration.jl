module TestbedMIMICSCCalibration

import Statistics
import TOML
import SHA

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
    calibrated_envelope(actual, expected; relative = true)

Fit the mixed absolute-relative envelope used by the MIMICS-C policy. The raw
envelope minimizes `atol + rtol * mean(abs(expected))`; a 5% safety factor is
then applied without admitting nonfinite pairs. Set `relative = false` for
zero-centered diagnostics whose reference value is not a meaningful scale.
"""
function calibrated_envelope(actual, expected; relative = true)
    length(actual) == length(expected) && !isempty(actual) ||
        error("MIMICS-C calibration requires nonempty aligned pairs")
    all(isfinite, actual) ||
        error("eligible Julia MIMICS-C values contain a nonfinite value")
    all(isfinite, expected) ||
        error("eligible Fortran MIMICS-C values contain a nonfinite value")
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
    relative_value = 0.0
    if relative &&
       right_derivative(relative_value, errors, references, 0.0) < 0
        upper = eps(Float64)
        while right_derivative(
            upper,
            errors,
            references,
            0.0,
        ) < 0
            upper *= 2
            isfinite(upper) ||
                error("unable to bracket MIMICS-C relative tolerance")
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
        relative_value = upper
    end
    absolute =
        max(0.0, maximum(errors .- relative_value .* references))
    atol = SAFETY_FACTOR * absolute + float_padding
    rtol = SAFETY_FACTOR * relative_value
    failed = count(errors .> atol .+ rtol .* references)
    iszero(failed) ||
        error("derived MIMICS-C tolerance does not enclose every pair")
    return (;
        atol,
        rtol,
        raw_atol = absolute,
        raw_rtol = relative_value,
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

function calibration_record(
    actual,
    expected;
    units,
    observations = nothing,
    relative = true,
)
    isnothing(observations) ||
        length(observations) == length(actual) ||
        error("MIMICS-C calibration observation metadata is not aligned")
    envelope = calibrated_envelope(actual, expected; relative)
    nonzero = findall(value -> !iszero(value), envelope.references)
    relative_errors =
        envelope.errors[nonzero] ./ envelope.references[nonzero]
    all(isfinite, relative_errors) ||
        error("MIMICS-C calibration relative errors are nonfinite")
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

const DISTRIBUTION_KEYS =
    Set(("minimum", "median", "p90", "p95", "p99", "p999", "maximum", "mean"))

function validate_distribution(values, location; allow_empty = false)
    allow_empty && isempty(values) && return nothing
    Set(String.(keys(values))) == DISTRIBUTION_KEYS &&
        all(
            value -> value isa Real && isfinite(value) && value >= 0,
            Base.values(values),
        ) ||
        error("$location has an invalid distribution")
    return nothing
end

function validate_record(record, location, pair_count, observation_fields)
    get(record, "finite_pair_count", nothing) == pair_count ||
        error("$location has the wrong calibration population")
    !isempty(String(get(record, "units", ""))) ||
        error("$location has no units")
    validate_distribution(record["absolute_error"], "$location.absolute_error")
    validate_distribution(
        record["absolute_reference"],
        "$location.absolute_reference",
    )
    relative = record["relative_error"]
    get(relative, "zero_reference_count", -1) +
        get(relative, "nonzero_reference_count", -1) == pair_count ||
        error("$location has inconsistent zero-reference counts")
    validate_distribution(
        relative["distribution"],
        "$location.relative_error";
        allow_empty = get(relative, "nonzero_reference_count", 0) == 0,
    )
    active = record["active_constraint"]
    0 < get(active, "count", 0) <= pair_count ||
        error("$location has no active constraint")
    observations = get(active, "observation", Dict{String, Any}[])
    length(observations) == min(6, active["count"]) ||
        error("$location has incomplete active-constraint evidence")
    top = get(record, "top_outlier", Dict{String, Any}[])
    length(top) == min(6, pair_count) ||
        error("$location has incomplete outlier evidence")
    for observation in [observations; top]
        all(field -> haskey(observation, field), observation_fields) ||
            error("$location lacks observation coordinates")
    end
    for outlier in top
        all(
            field -> haskey(outlier, field),
            ("rank", "julia", "fortran", "absolute_error", "relative_error"),
        ) || error("$location has an incomplete outlier")
        all(
            isfinite,
            (outlier["julia"], outlier["fortran"], outlier["absolute_error"]),
        ) || error("$location has a nonfinite outlier")
    end
    getindex.(top, "rank") == collect(1:length(top)) ||
        error("$location has invalid outlier ranks")
    policy = get(record, "derived_policy", Dict{String, Any}())
    Set(String.(keys(policy))) == Set((
        "atol",
        "rtol",
        "raw_atol",
        "raw_rtol",
        "float_padding",
        "raw_objective",
        "validation_failed_pairs",
    )) || error("$location has incomplete fitted-policy diagnostics")
    all(
        value -> value isa Real && isfinite(value) && value >= 0,
        (
            policy["atol"],
            policy["rtol"],
            policy["raw_atol"],
            policy["raw_rtol"],
            policy["float_padding"],
            policy["raw_objective"],
        ),
    ) || error("$location has invalid fitted-policy diagnostics")
    policy_record(record, location)
    return nothing
end

function validate_digest(record, location)
    digest = get(record, "sha256", "")
    length(digest) == 64 && all(isxdigit, digest) ||
        error("$location has an invalid SHA-256")
    return nothing
end

function validate_provenance(document, required, generator)
    provenance = get(document, "source_provenance", Dict{String, Any}())
    revision = get(provenance, "git_revision_basis", "")
    length(revision) == 40 && all(isxdigit, revision) ||
        error("MIMICS-C calibration has an invalid Git revision")
    !isempty(String(get(provenance, "julia_version", ""))) ||
        error("MIMICS-C calibration has no Julia version")
    for name in required
        validate_digest(
            get(provenance, name, Dict{String, Any}()),
            "source_provenance.$name",
        )
    end
    validate_digest(provenance["generator"], "source_provenance.generator")
    validate_digest(
        provenance["calibration"],
        "source_provenance.calibration",
    )
    for name in ("generator", "calibration")
        !isempty(String(get(provenance[name], "id", ""))) ||
            error("source_provenance.$name has no logical ID")
    end
    provenance["generator"]["sha256"] ==
        open(
            joinpath(@__DIR__, generator),
        ) do io
            bytes2hex(SHA.sha256(io))
        end ||
        error("MIMICS-C calibration generator hash is stale")
    provenance["calibration"]["sha256"] ==
        open(joinpath(@__DIR__, "mimics_c_calibration.jl")) do io
            bytes2hex(SHA.sha256(io))
        end ||
        error("MIMICS-C calibration helper hash is stale")
    return nothing
end

function validate_method(document)
    method = get(document, "method", Dict{String, Any}())
    all(
        name -> !isempty(String(get(method, name, ""))),
        (
            "error",
            "reference_magnitude",
            "raw_absolute",
            "selection",
            "safety_margin",
            "nonfinite",
        ),
    ) || error("MIMICS-C calibration method is incomplete")
    occursin("max(0", method["raw_absolute"]) &&
        !occursin("absolute_floor", method["raw_absolute"]) ||
        error("MIMICS-C calibration method contains a scientific floor")
    return nothing
end

"""
    comparison_policy(boundary_path, historical_path)

Consume the two immutable MIMICS-C calibration manifests into the policy shape
used by the selected-cell workflow.
"""
function comparison_policy(boundary_path, historical_path)
    boundary = TOML.parsefile(boundary_path)
    historical = TOML.parsefile(historical_path)
    get(boundary, "model", "MIMICS-C") == "MIMICS-C" ||
        error("boundary calibration is not for MIMICS-C")
    get(historical, "model", nothing) == "MIMICS-C" ||
        error("historical calibration is not for MIMICS-C")
    get(boundary, "schema_version", nothing) == 1 &&
        get(historical, "schema_version", nothing) == 1 ||
        error("MIMICS-C calibration schema is unsupported")
    validate_method(boundary)
    validate_method(historical)
    validate_provenance(
        boundary,
        (
            "generator",
            "calibration",
            "population_manifest",
            "grid",
            "casa_parameters",
            "mimics_parameters",
            "fresh_fortran_build",
            "fresh_fortran_workflow",
        ),
        "generate_mimics_c_boundary_calibration.jl",
    )
    validate_provenance(
        historical,
        (
            "generator",
            "calibration",
            "scope_manifest",
            "current_julia_output",
            "current_julia_report",
            "fresh_fortran_oracle",
        ),
        "generate_mimics_c_historical_calibration.jl",
    )
    boundary_values = get(boundary, "variable", Dict{String, Any}())
    annual_values = get(historical, "annual", Dict{String, Any}())
    daily_values = get(historical, "daily", Dict{String, Any}())
    budget_value = get(historical, "budget", Dict{String, Any}())
    boundary_pairs = Int(get(boundary, "eligible_cell_count", 0))
    boundary_pairs > 0 ||
        error("MIMICS-C boundary calibration has no eligible population")
    for (stage, variables) in boundary_values
        for (name, record) in variables
            validate_record(
                record,
                "boundary.$stage.$name",
                boundary_pairs,
                ("cell_id", "pft", "latitude", "longitude"),
            )
        end
    end
    historical_pairs = Int(get(historical, "eligible_cell_count", 0))
    historical_pairs > 0 ||
        error("MIMICS-C historical calibration has no eligible population")
    for (reducer, variables) in annual_values
        for (name, record) in variables
            validate_record(
                record,
                "annual.$reducer.$name",
                historical_pairs * 114,
                ("cell_id", "year", "latitude", "longitude"),
            )
        end
    end
    for (name, record) in daily_values
        validate_record(
            record,
            "daily.$name",
            historical_pairs * 84,
            (
                "cell_id",
                "year",
                "day_of_year",
                "sample_day",
                "latitude",
                "longitude",
            ),
        )
    end
    validate_record(
        budget_value,
        "budget.historical_residual_kg_c",
        historical_pairs,
        ("cell_id", "latitude", "longitude"),
    )
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
            "historical_residual_kg_c" =>
                policy_record(budget_value, "budget.historical_residual_kg_c"),
        ),
    )
end

end
