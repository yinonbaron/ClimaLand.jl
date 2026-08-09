module ClassicToleranceContract

import SHA
import TOML

export evidence_root_from_env, evaluate_replay_report, load_tolerance_contract

const SHA256_PATTERN = r"^[0-9a-f]{64}$"
const REQUIRED_ORACLE_CONTRACT = "stage_b_v5"
const BUDGET_FIELDS = Set(("carbon_closure",))
const DRIFT_FIELDS = Set(("accumulated_drift",))
const REQUIRED_MEASUREMENT_SITES = Set(("DE-Hai", "GF-Guy", "BR-Sa1"))
const BR_GATE_RESULT = "accepted_split_day_one_gate"
const EVIDENCE_ROOT_ENV = "CLASSIC_TOLERANCE_EVIDENCE_ROOT"


valid_sha256(value) =
    value isa AbstractString && occursin(SHA256_PATTERN, value)
sha256_file(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

function required_regular_file(path, label)
    isfile(path) || throw(ArgumentError("missing $label: $path"))
    islink(path) && throw(ArgumentError("$label must not be a symlink: $path"))
    filesize(path) > 0 || throw(ArgumentError("empty $label: $path"))
    return abspath(path)
end

function canonical_evidence_root(root)
    root isa AbstractString && !isempty(root) ||
        throw(ArgumentError("tolerance evidence root is required"))
    isabspath(root) ||
        throw(ArgumentError("tolerance evidence root must be absolute"))
    isdir(root) && !islink(root) || throw(
        ArgumentError(
            "tolerance evidence root must be an existing regular directory",
        ),
    )
    return realpath(root)
end

function evidence_root_from_env(environment = ENV)
    root = get(environment, EVIDENCE_ROOT_ENV, nothing)
    return canonical_evidence_root(root)
end

function resolve_evidence(root, identifier, label)
    identifier isa AbstractString && !isempty(identifier) ||
        throw(ArgumentError("$label evidence identifier is missing"))
    isabspath(identifier) &&
        throw(ArgumentError("$label evidence identifier must be relative"))
    normalized = normpath(identifier)
    normalized == identifier && normalized != "." ||
        throw(ArgumentError("$label evidence identifier is not canonical"))
    candidate = joinpath(root, normalized)
    required_regular_file(candidate, label)
    canonical = realpath(candidate)
    relative = relpath(canonical, root)
    outside =
        relative == ".." ||
        startswith(relative, ".." * Base.Filesystem.path_separator)
    outside && throw(ArgumentError("$label escapes the evidence root"))
    return abspath(candidate)
end

function validate_br_gate_refinement(
    path,
    expected_sha,
    evidence_id,
    replay_sha,
)
    path = required_regular_file(path, "BR gate-refinement receipt")
    valid_sha256(expected_sha) ||
        throw(ArgumentError("BR gate-refinement SHA-256 is invalid"))
    sha256_file(path) == expected_sha ||
        throw(ArgumentError("BR gate-refinement SHA-256 differs"))
    receipt = TOML.parsefile(path)
    get(receipt, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported BR gate-refinement receipt"))
    get(receipt, "site", nothing) == "BR-Sa1" ||
        throw(ArgumentError("BR gate-refinement site differs"))
    get(receipt, "status", nothing) == "pass" ||
        throw(ArgumentError("BR gate refinement did not pass"))
    get(receipt, "result", nothing) == BR_GATE_RESULT ||
        throw(ArgumentError("BR gate-refinement result differs"))
    get(receipt, "source_formula_order_match", nothing) === true ||
        throw(ArgumentError("BR source formula/order was not proven"))
    get(receipt, "model_source_changed", nothing) === false ||
        throw(ArgumentError("BR gate refinement changed model source"))
    accepted = get(receipt, "accepted_replay", nothing)
    accepted isa AbstractDict ||
        throw(ArgumentError("BR gate refinement lacks accepted replay"))
    get(accepted, "sha256", nothing) == replay_sha ||
        throw(ArgumentError("BR accepted replay SHA-256 differs"))
    probe = get(receipt, "gfortran_probe", nothing)
    probe isa AbstractDict ||
        throw(ArgumentError("BR gate refinement lacks compiler/libm probe"))
    all(
        key -> valid_sha256(get(probe, key, "")),
        ("libm_sha256", "libgfortran_sha256"),
    ) || throw(ArgumentError("BR compiler/libm probe hashes are invalid"))
    source = get(receipt, "pinned_fortran_source", nothing)
    source isa AbstractDict ||
        throw(ArgumentError("BR gate refinement lacks pinned source"))
    valid_sha256(get(source, "sha256", "")) ||
        throw(ArgumentError("BR pinned source hash is invalid"))
    isempty(get(source, "source_commit", "")) &&
        throw(ArgumentError("BR pinned source commit is missing"))
    return (; path, evidence_id, sha256 = expected_sha)
end

function validate_error_map(receipt, key, expected, label)
    error_values = get(receipt, key, nothing)
    error_values isa AbstractDict ||
        throw(ArgumentError("measurement receipt lacks $key"))
    Set(keys(error_values)) == expected ||
        throw(ArgumentError("measurement receipt $label inventory differs"))
    all(
        value -> value isa Real && isfinite(value) && value >= 0,
        values(error_values),
    ) || throw(ArgumentError("measurement receipt $label errors are invalid"))
    return Dict(
        String(name) => Float64(value) for (name, value) in error_values
    )
end

function validate_measurement_receipt(
    path,
    expected_sha,
    expected_state,
    expected_flux,
)
    path = required_regular_file(path, "measurement receipt")
    valid_sha256(expected_sha) ||
        throw(ArgumentError("measurement receipt SHA-256 is invalid"))
    sha256_file(path) == expected_sha ||
        throw(ArgumentError("measurement receipt SHA-256 differs"))
    receipt = TOML.parsefile(path)
    get(receipt, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported measurement receipt"))
    get(receipt, "status", nothing) == "pass" ||
        throw(ArgumentError("measurement receipt did not pass"))
    get(receipt, "initialization_count", nothing) == 1 ||
        throw(ArgumentError("measurement replay was not initialized once"))
    get(receipt, "recurrent_state_replacements", nothing) == 0 ||
        throw(ArgumentError("measurement replay replaced recurrent state"))
    state =
        validate_error_map(receipt, "max_state_errors", expected_state, "state")
    flux = validate_error_map(receipt, "max_flux_errors", expected_flux, "flux")
    maximum(values(state); init = 0.0) ==
    get(receipt, "max_state_error", nothing) ||
        throw(ArgumentError("measurement maximum state error differs"))
    maximum(values(flux); init = 0.0) ==
    get(receipt, "max_flux_error", nothing) ||
        throw(ArgumentError("measurement maximum flux error differs"))
    carbon_closure = get(receipt, "max_carbon_closure", nothing)
    carbon_closure isa Real &&
    isfinite(carbon_closure) &&
    carbon_closure >= 0 ||
        throw(ArgumentError("measurement carbon closure is invalid"))
    accumulated_drift = get(receipt, "accumulated_drift", nothing)
    accumulated_drift isa Real && isfinite(accumulated_drift) ||
        throw(ArgumentError("measurement accumulated drift is invalid"))
    return (;
        path,
        sha256 = expected_sha,
        state,
        flux,
        carbon_closure = Float64(carbon_closure),
        accumulated_drift = abs(Float64(accumulated_drift)),
    )
end

function measured_maxima(receipts, expected_state, expected_flux)
    state = Dict(
        name => maximum(receipt.state[name] for receipt in receipts) for
        name in expected_state
    )
    flux = Dict(
        name => maximum(receipt.flux[name] for receipt in receipts) for
        name in expected_flux
    )
    return Dict(
        "state" => state,
        "flux" => flux,
        "budget" => Dict(
            "carbon_closure" =>
                maximum(receipt.carbon_closure for receipt in receipts),
        ),
        "drift" => Dict(
            "accumulated_drift" =>
                maximum(receipt.accumulated_drift for receipt in receipts),
        ),
    )
end

function load_tolerance_contract(path, schema; evidence_root = nothing)
    path = required_regular_file(path, "tolerance contract")
    evidence_root = canonical_evidence_root(evidence_root)
    contract = TOML.parsefile(path)
    get(contract, "schema_version", nothing) == 1 ||
        throw(ArgumentError("unsupported tolerance contract"))
    get(contract, "oracle_contract", nothing) == REQUIRED_ORACLE_CONTRACT ||
        throw(ArgumentError("tolerances are not bound to Stage B v5"))
    isempty(get(contract, "rationale", "")) &&
        throw(ArgumentError("tolerance contract lacks a rationale"))
    expected_state = Set(
        field["name"] for
        field in schema["field"] if field["section"] == "reference_state"
    )
    expected_flux = Set(
        field["name"] for
        field in schema["field"] if field["section"] == "audit_diagnostics"
    )
    measurements = get(contract, "measurement_receipt", Any[])
    sites = get.(measurements, "site", nothing)
    length(sites) == length(unique(sites)) ||
        throw(ArgumentError("tolerance contract contains duplicate sites"))
    Set(sites) == REQUIRED_MEASUREMENT_SITES ||
        throw(ArgumentError("tolerance calibration site inventory differs"))
    receipts = map(measurements) do measurement
        site = measurement["site"]
        evidence_id = get(measurement, "evidence_id", "")
        receipt_path = resolve_evidence(
            evidence_root,
            evidence_id,
            "measurement receipt",
        )
        replay = validate_measurement_receipt(
            receipt_path,
            get(measurement, "sha256", ""),
            expected_state,
            expected_flux,
        )
        gate_refinement = if site == "BR-Sa1"
            gate_id = get(measurement, "gate_refinement_evidence_id", "")
            gate_path = resolve_evidence(
                evidence_root,
                gate_id,
                "BR gate-refinement receipt",
            )
            validate_br_gate_refinement(
                gate_path,
                get(measurement, "gate_refinement_sha256", ""),
                evidence_id,
                replay.sha256,
            )
        else
            nothing
        end
        merge(replay, (; site, evidence_id, gate_refinement))
    end
    measured = measured_maxima(receipts, expected_state, expected_flux)
    records = get(contract, "field", Any[])
    names = getindex.(records, "name")
    length(names) == length(unique(names)) ||
        throw(ArgumentError("tolerance contract contains duplicates"))
    actual = Set(names)
    actual ==
    union(expected_state, expected_flux, BUDGET_FIELDS, DRIFT_FIELDS) ||
        throw(ArgumentError("tolerance field inventory differs"))
    grouped = Dict(
        "state" => Dict{String, Float64}(),
        "flux" => Dict{String, Float64}(),
        "budget" => Dict{String, Float64}(),
        "drift" => Dict{String, Float64}(),
    )
    for record in records
        name = record["name"]
        family = record["family"]
        value = record["absolute_tolerance"]
        observed = get(record, "observed_maximum_absolute_error", nothing)
        safety_factor = get(record, "safety_factor", nothing)
        family in keys(grouped) ||
            throw(ArgumentError("$name tolerance family is invalid"))
        value isa Real && isfinite(value) && value >= 0 ||
            throw(ArgumentError("$name tolerance is invalid"))
        observed isa Real && isfinite(observed) && observed >= 0 ||
            throw(ArgumentError("$name observed error is invalid"))
        safety_factor isa Real &&
        isfinite(safety_factor) &&
        safety_factor > 1 ||
            throw(ArgumentError("$name safety factor is invalid"))
        expected_family =
            name in expected_state ? "state" :
            name in expected_flux ? "flux" :
            name in BUDGET_FIELDS ? "budget" : "drift"
        family == expected_family ||
            throw(ArgumentError("$name tolerance family differs"))
        observed == measured[family][name] ||
            throw(ArgumentError("$name observed error differs from receipts"))
        value == observed * safety_factor ||
            throw(ArgumentError("$name tolerance is not measurement-derived"))
        grouped[family][name] = Float64(value)
    end
    return (;
        state = grouped["state"],
        flux = grouped["flux"],
        budget = grouped["budget"],
        drift = grouped["drift"],
        measurement_receipts = receipts,
        sha256 = sha256_file(path),
        rationale = contract["rationale"],
    )
end

function first_field_failure(steps, collection, field, threshold)
    for step in steps
        error = collection(step)[field]
        error > threshold && return step, error
    end
    return nothing, 0.0
end

function schema_phases(schema)
    return Dict(
        field["name"] => field["application_phase"] for field in schema["field"]
    )
end

function evaluate_replay_report(report, tolerances, schema)
    Set(keys(report.max_state_errors)) == Set(keys(tolerances.state)) ||
        throw(ArgumentError("state error inventory differs from tolerances"))
    Set(keys(report.max_flux_errors)) == Set(keys(tolerances.flux)) ||
        throw(ArgumentError("flux error inventory differs from tolerances"))
    phases = schema_phases(schema)
    localization = Dict{String, Any}[]
    state_ok = true
    for (field, threshold) in tolerances.state
        if report.max_state_errors[field] > threshold
            state_ok = false
            step, error = first_field_failure(
                report.steps,
                value -> value.state_errors,
                field,
                threshold,
            )
            push!(
                localization,
                Dict(
                    "family" => "state",
                    "field" => field,
                    "step_index" => step.index,
                    "time_start" => string(step.time_start),
                    "time_end" => string(step.time_end),
                    "error" => error,
                    "tolerance" => threshold,
                    "call_snapshot" => phases[field],
                    "call_snapshot_payload" => "payloads/step_$(lpad(string(step.index), 8, '0'))",
                ),
            )
        end
    end
    flux_ok = true
    for (field, threshold) in tolerances.flux
        if report.max_flux_errors[field] > threshold
            flux_ok = false
            step, error = first_field_failure(
                report.steps,
                value -> value.flux_errors,
                field,
                threshold,
            )
            push!(
                localization,
                Dict(
                    "family" => "flux",
                    "field" => field,
                    "step_index" => step.index,
                    "time_start" => string(step.time_start),
                    "time_end" => string(step.time_end),
                    "error" => error,
                    "tolerance" => threshold,
                    "call_snapshot" => phases[field],
                    "call_snapshot_payload" => "payloads/step_$(lpad(string(step.index), 8, '0'))",
                ),
            )
        end
    end
    budget_floor = tolerances.budget["carbon_closure"]
    budget_errors = Dict("carbon_closure" => report.max_carbon_closure)
    budget_failure_index = findfirst(
        step ->
            !step.roundoff_ok ||
            abs(step.roundoff_residual) >
            max(budget_floor, step.roundoff_bound),
        report.steps,
    )
    budget_ok = report.closure_ok && isnothing(budget_failure_index)
    if !budget_ok
        step_index =
            isnothing(budget_failure_index) ? lastindex(report.steps) :
            budget_failure_index
        step = report.steps[step_index]
        threshold = max(budget_floor, step.roundoff_bound)
        push!(
            localization,
            Dict(
                "family" => "budget",
                "field" => "carbon_closure",
                "step_index" => step.index,
                "time_start" => string(step.time_start),
                "time_end" => string(step.time_end),
                "error" => abs(step.roundoff_residual),
                "tolerance" => threshold,
                "contract_floor" => budget_floor,
                "analytic_bound" => step.roundoff_bound,
                "roundoff_term_count" => step.roundoff_term_count,
                "roundoff_term_scale" => step.roundoff_term_scale,
                "roundoff_term_scale_upper" => step.roundoff_term_scale_upper,
                "roundoff_ratio" => step.roundoff_ratio,
                "naive_carbon_closure_audit" => step.carbon_closure,
                "call_snapshot" => "daily_carbon_budget",
                "call_snapshot_payload" => "payloads/step_$(lpad(string(step.index), 8, '0'))",
            ),
        )
    end
    drift_errors = Dict("accumulated_drift" => abs(report.accumulated_drift))
    drift_floor = tolerances.drift["accumulated_drift"]
    drift_threshold = max(drift_floor, report.drift_roundoff_bound)
    drift_ok =
        report.drift_ok &&
        abs(report.drift_roundoff_residual) <= drift_threshold
    if !drift_ok
        step_index = something(
            findfirst(
                step -> abs(step.accumulated_drift) > drift_threshold,
                report.steps,
            ),
            lastindex(report.steps),
        )
        step = report.steps[step_index]
        push!(
            localization,
            Dict(
                "family" => "drift",
                "field" => "accumulated_drift",
                "step_index" => step.index,
                "time_start" => string(step.time_start),
                "time_end" => string(step.time_end),
                "error" => abs(report.drift_roundoff_residual),
                "tolerance" => drift_threshold,
                "contract_floor" => drift_floor,
                "analytic_bound" => report.drift_roundoff_bound,
                "roundoff_term_count" => report.drift_roundoff_term_count,
                "roundoff_term_scale" => report.drift_roundoff_term_scale,
                "roundoff_term_scale_upper" =>
                    report.drift_roundoff_term_scale_upper,
                "roundoff_ratio" => report.drift_roundoff_ratio,
                "naive_accumulated_drift_audit" =>
                    report.naive_accumulated_drift,
                "call_snapshot" => "seasonal_carbon_budget",
                "call_snapshot_payload" => "payloads/step_$(lpad(string(step.index), 8, '0'))",
            ),
        )
    end
    lifecycle_ok =
        report.initialization_count == 1 &&
        report.recurrent_state_replacements == 0
    return (;
        ok = lifecycle_ok && state_ok && flux_ok && budget_ok && drift_ok,
        state_ok,
        flux_ok,
        budget_ok,
        drift_ok,
        lifecycle_ok,
        max_state_errors = report.max_state_errors,
        max_flux_errors = report.max_flux_errors,
        max_budget_errors = budget_errors,
        max_drift_errors = drift_errors,
        failure_localization = localization,
    )
end


end
