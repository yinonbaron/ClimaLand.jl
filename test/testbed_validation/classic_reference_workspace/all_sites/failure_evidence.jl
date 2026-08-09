function replay_failed_gates(report)
    gates = String[]
    if hasproperty(report, :day_one_state_exact) &&
       hasproperty(report, :day_one_flux_within_tolerance)
        report.day_one_state_exact || push!(gates, "day_one_state_exact")
        report.day_one_flux_within_tolerance ||
            push!(gates, "day_one_flux_within_tolerance")
    elseif hasproperty(report, :day_one_exact) && !report.day_one_exact
        push!(gates, "day_one_exact")
    end
    for (property, name) in (
        :state_ok => "state",
        :flux_ok => "flux",
        :closure_ok => "daily_closure",
        :drift_ok => "drift",
    )
        hasproperty(report, property) &&
            !getproperty(report, property) &&
            push!(gates, name)
    end
    return gates
end

function numeric_error_table(report, property)
    hasproperty(report, property) || return Dict{String, Float64}()
    return Dict(
        String(name) => Float64(value) for
        (name, value) in pairs(getproperty(report, property))
    )
end

function copy_report_property!(diagnostics, report, property)
    hasproperty(report, property) ||
        throw(ArgumentError("replay failure report lacks $property"))
    diagnostics[string(property)] = getproperty(report, property)
    return diagnostics
end

function failure_diagnostics(error, archive_root, site)
    diagnostics = Dict{String, Any}(
        "cause" => Dict(
            "type" => string(typeof(error)),
            "message" => sprint(showerror, error),
        ),
    )
    hasproperty(error, :report) || return diagnostics
    report = getproperty(error, :report)
    diagnostics["failure_phase"] = "replay_acceptance"
    diagnostics["failed_gates"] = replay_failed_gates(report)
    diagnostics["max_state_errors"] =
        numeric_error_table(report, :max_state_errors)
    diagnostics["max_flux_errors"] =
        numeric_error_table(report, :max_flux_errors)
    for property in (
        :max_carbon_closure,
        :naive_accumulated_drift,
        :accumulated_drift,
        :drift_algorithm,
        :drift_algorithm_version,
        :drift_oracle_conversion,
        :drift_term_count,
        :drift_term_scale,
    )
        copy_report_property!(diagnostics, report, property)
    end
    diagnostics["compensated_accumulated_drift"] = report.accumulated_drift
    if hasproperty(error, :receipt_path)
        source = getproperty(error, :receipt_path)
        isfile(source) ||
            throw(ArgumentError("replay failure receipt does not exist"))
        destination = joinpath(archive_root, site * ".replay-failure.toml")
        ispath(destination) &&
            throw(ArgumentError("replay failure receipt already exists"))
        cp(source, destination)
        diagnostics["replay_receipt_path"] = abspath(destination)
        diagnostics["replay_receipt_sha256"] = sha256_path(destination)
    end
    return diagnostics
end
