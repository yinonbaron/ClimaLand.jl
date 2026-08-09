function evaluate_day_one_gate(step, flux_tolerances, tolerance_contract_sha256)
    expected_fluxes = Set(keys(step.flux_errors))
    tolerances = if isnothing(flux_tolerances)
        isempty(tolerance_contract_sha256) || throw(
            ArgumentError(
                "day-one flux tolerance hash was provided without tolerances",
            ),
        )
        Dict(name => 0.0 for name in expected_fluxes)
    else
        ClassicTrajectoryBundle.valid_sha256(tolerance_contract_sha256) ||
            throw(
                ArgumentError(
                    "day-one flux tolerance contract SHA-256 is invalid",
                ),
            )
        Set(keys(flux_tolerances)) == expected_fluxes ||
            throw(ArgumentError("day-one flux tolerance inventory differs"))
        tolerance_table = Dict(
            String(name) => Float64(value) for
            (name, value) in pairs(flux_tolerances)
        )
        all(
            isfinite(value) && value >= 0.0 for
            value in values(tolerance_table)
        ) || throw(ArgumentError("day-one flux tolerance is invalid"))
        tolerance_table
    end
    state_exact = step.state_error == 0.0
    flux_exact = step.flux_error == 0.0
    flux_within_tolerance =
        all(error <= tolerances[name] for (name, error) in step.flux_errors)
    return (;
        state_exact,
        flux_exact,
        flux_within_tolerance,
        flux_tolerances = tolerances,
        tolerance_contract_sha256,
    )
end
