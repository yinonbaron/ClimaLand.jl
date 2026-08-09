module TestbedMIMICSCNCalibration

import Statistics
import TOML
import SHA

const SAFETY_FACTOR = 1.05
const BOUNDARY_CALIBRATION_ID = "mimics-cn-current-julia-fresh-fortran-800-representative-union-boundary-v1"
const HISTORICAL_CALIBRATION_ID = "mimics-cn-current-julia-fresh-fortran-representative-history-v1"
const METHOD_FIELDS = Set((
    "error",
    "nonfinite",
    "raw_absolute",
    "reference_magnitude",
    "safety_margin",
    "selection",
))
const POPULATION_SIZES =
    Dict("random_pft_800" => (800, 790), "representative" => (80, 80))
const STAGES = Set(("prespin", "spin", "spin_continuation", "historical"))

sha256sum(path) = bytes2hex(SHA.sha256(read(path)))
is_sha256(value) =
    value isa AbstractString && occursin(r"^[0-9a-f]{64}$", value)
is_git_revision(value) =
    value isa AbstractString && occursin(r"^[0-9a-f]{40}$", value)

function validate_method(document, location)
    method = get(document, "method", nothing)
    method isa AbstractDict || error("$location calibration method is missing")
    Set(keys(method)) == METHOD_FIELDS ||
        error("$location calibration method fields are invalid")
    all(value -> value isa AbstractString && !isempty(value), values(method)) ||
        error("$location calibration method is incomplete")
    occursin("max(0", method["raw_absolute"]) ||
        error("$location raw absolute method is invalid")
    !occursin("absolute_floor", method["raw_absolute"]) ||
        error("$location raw absolute method contains a scientific floor")
end

function validate_local_source(record, location, id, path)
    record isa AbstractDict || error("$location provenance is missing")
    get(record, "id", nothing) == id ||
        error("$location provenance id is invalid")
    get(record, "sha256", nothing) == sha256sum(path) ||
        error("$location provenance hash is stale")
end

function validate_digest(value, location)
    is_sha256(value) || error("$location is not a SHA-256 digest")
end

function validate_common(document, location, calibration_id, generator)
    get(document, "model", nothing) == "MIMICS-CN" ||
        error("$location calibration is not for MIMICS-CN")
    get(document, "schema_version", nothing) == 1 ||
        error("$location calibration schema is invalid")
    get(document, "calibration_id", nothing) == calibration_id ||
        error("$location calibration id is invalid")
    validate_method(document, location)

    provenance = get(document, "source_provenance", nothing)
    provenance isa AbstractDict ||
        error("$location source provenance is missing")
    get(provenance, "julia_version", "") isa AbstractString &&
        !isempty(provenance["julia_version"]) ||
        error("$location Julia version provenance is missing")
    is_git_revision(get(provenance, "git_revision_basis", nothing)) ||
        error("$location git revision provenance is invalid")
    validate_local_source(
        get(provenance, "generator", nothing),
        "$location generator",
        "test/testbed_validation/$generator",
        joinpath(@__DIR__, generator),
    )
    validate_local_source(
        get(provenance, "calibration", nothing),
        "$location calibration helper",
        "test/testbed_validation/mimics_cn_calibration.jl",
        @__FILE__,
    )
    return provenance
end

function validate_boundary(document)
    provenance = validate_common(
        document,
        "boundary",
        BOUNDARY_CALIBRATION_ID,
        "generate_mimics_cn_boundary_calibration.jl",
    )
    get(document, "union_cell_count", nothing) == 852 ||
        error("boundary union population is invalid")

    populations = get(provenance, "population", nothing)
    populations isa AbstractDict &&
        Set(keys(populations)) == Set(keys(POPULATION_SIZES)) ||
        error("boundary population provenance is invalid")
    validation = get(document, "population_validation", nothing)
    validation isa AbstractDict &&
        Set(keys(validation)) == Set(keys(POPULATION_SIZES)) ||
        error("boundary population validation is invalid")
    for (name, (cell_count, eligible_count)) in POPULATION_SIZES
        population = populations[name]
        get(population, "cell_count", nothing) == cell_count &&
            get(population, "eligible_cell_count", nothing) == eligible_count ||
            error("boundary $name population count is invalid")
        is_git_revision(get(population, "fortran_source_revision", nothing)) ||
            error("boundary $name Fortran revision is invalid")
        for key in ("cell_ids_sha256",)
            validate_digest(
                get(population, key, nothing),
                "boundary $name $key",
            )
        end
        for key in ("fortran_build", "fortran_workflow")
            record = get(population, key, nothing)
            record isa AbstractDict ||
                error("boundary $name $key provenance is missing")
            validate_digest(
                get(record, "sha256", nothing),
                "boundary $name $key",
            )
        end
        sources = get(population, "sources", nothing)
        sources isa AbstractDict && Set(keys(sources)) == STAGES ||
            error("boundary $name source stages are invalid")
        for (stage, records) in sources
            records isa AbstractDict ||
                error("boundary $name $stage source provenance is invalid")
            for (source, record) in records
                record isa AbstractDict ||
                    error("boundary $name $stage $source provenance is invalid")
                validate_digest(
                    get(record, "sha256", nothing),
                    "boundary $name $stage $source",
                )
            end
        end

        stages = validation[name]
        stages isa AbstractDict && Set(keys(stages)) == STAGES ||
            error("boundary $name validation stages are invalid")
        for (stage, records) in stages
            records isa AbstractDict && !isempty(records) ||
                error("boundary $name $stage validation is empty")
            all(
                record ->
                    get(record, "finite_pair_count", nothing) ==
                    eligible_count && get(record, "failed_pairs", nothing) == 0,
                values(records),
            ) || error("boundary $name $stage validation is invalid")
        end
    end

    population_path =
        joinpath(@__DIR__, "validation", "mimics_cn_boundary_populations.toml")
    scope_path =
        joinpath(@__DIR__, "validation", "scopes", "representative.toml")
    validate_local_source(
        get(provenance, "population_manifest", nothing),
        "boundary population manifest",
        "test/testbed_validation/validation/mimics_cn_boundary_populations.toml",
        population_path,
    )
    validate_local_source(
        get(provenance, "scope_manifest", nothing),
        "boundary scope manifest",
        "test/testbed_validation/validation/scopes/representative.toml",
        scope_path,
    )
    for key in ("normal_casa_parameters", "mimics_parameters")
        record = get(provenance, key, nothing)
        record isa AbstractDict || error("boundary $key provenance is missing")
        validate_digest(
            get(record, "sha256", nothing),
            "boundary $key provenance",
        )
    end
end

function validate_historical(document)
    provenance = validate_common(
        document,
        "historical",
        HISTORICAL_CALIBRATION_ID,
        "generate_mimics_cn_historical_calibration.jl",
    )
    get(document, "scope", nothing) == "representative" ||
        error("historical scope is invalid")
    get(document, "cell_count", nothing) == 80 ||
        error("historical population count is invalid")
    scope_path =
        joinpath(@__DIR__, "validation", "scopes", "representative.toml")
    scope = TOML.parsefile(scope_path)
    get(document, "cell_ids", nothing) == scope["cell_ids"] ||
        error("historical population ids do not match the scope manifest")

    oracle = get(provenance, "fresh_fortran_oracle", nothing)
    oracle isa AbstractDict ||
        error("historical Fortran oracle provenance is missing")
    get(oracle, "id", nothing) == "pinned_mimics_cn_representative_oracle" ||
        error("historical Fortran oracle id is invalid")
    validate_digest(get(oracle, "sha256", nothing), "historical Fortran oracle")
    get(oracle, "scope_manifest_sha256", nothing) == sha256sum(scope_path) ||
        error("historical Fortran oracle scope hash is stale")
    is_git_revision(get(oracle, "fortran_source_revision", nothing)) ||
        error("historical Fortran source revision is invalid")
    source_hashes = get(oracle, "fresh_historical_source_sha256", nothing)
    source_hashes isa AbstractDict && !isempty(source_hashes) ||
        error("historical Fortran source hashes are missing")
    for (name, digest) in source_hashes
        validate_digest(digest, "historical Fortran source $name")
    end
    for key in ("current_julia_output", "current_julia_report")
        record = get(provenance, key, nothing)
        record isa AbstractDict ||
            error("historical $key provenance is missing")
        validate_digest(
            get(record, "sha256", nothing),
            "historical $key provenance",
        )
    end
end

function right_derivative(relative, errors, references, absolute_floor)
    maximum_residual = maximum(
        errors[index] - relative * references[index] for
        index in eachindex(errors)
    )
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
        while right_derivative(upper, errors, references, 0.0) < 0
            upper *= 2
            isfinite(upper) ||
                error("unable to bracket MIMICS-CN relative tolerance")
        end
        lower = 0.0
        for _ in 1:256
            middle = (lower + upper) / 2
            if right_derivative(middle, errors, references, 0.0) < 0
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
    isnothing(observations) && return Dict("observation_index" => index)
    value = observations[index]
    return Dict(String(name) => field for (name, field) in pairs(value))
end

function calibration_record(actual, expected; units, observations = nothing)
    isnothing(observations) ||
        length(observations) == length(actual) ||
        error("MIMICS-CN calibration observation metadata is not aligned")
    envelope = calibrated_envelope(actual, expected)
    nonzero = findall(value -> !iszero(value), envelope.references)
    relative_errors = envelope.errors[nonzero] ./ envelope.references[nonzero]
    residuals = envelope.errors .- envelope.raw_rtol .* envelope.references
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
        ) for (rank, index) in enumerate(order[1:min(6, length(order))])
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
    all(
        value -> value isa Real && isfinite(value) && value >= 0,
        (atol, rtol),
    ) || error("$location has an invalid derived policy")
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
    validate_boundary(boundary)
    validate_historical(historical)
    boundary_values = get(boundary, "variable", Dict{String, Any}())
    annual_values = get(historical, "annual", Dict{String, Any}())
    daily_values = get(historical, "daily", Dict{String, Any}())
    budget_value = get(historical, "budget", Dict{String, Any}())
    return Dict(
        "fresh_fortran_boundary" => Dict(
            stage => Dict(
                name => policy_record(record, "boundary.$stage.$name")
                for (name, record) in variables
            ) for (stage, variables) in boundary_values
        ),
        "fresh_fortran_annual" => Dict(
            reducer => Dict(
                name => policy_record(record, "annual.$reducer.$name")
                for (name, record) in variables
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
