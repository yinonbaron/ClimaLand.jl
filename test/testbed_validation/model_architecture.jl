function test_checkpoint_roundtrip(model, Y, t)
    mktempdir() do output_dir
        ClimaLand.save_checkpoint(Y, t, output_dir; model)
        checkpoint_file = only(
            filter(
                path -> endswith(path, ".hdf5"),
                readdir(output_dir; join = true),
            ),
        )
        Y_restart, _, _ = ClimaLand.initialize(model)
        ClimaLand.set_initial_conditions_from_checkpoint!(
            Y_restart,
            checkpoint_file;
            model,
        )

        @test ClimaLand.initial_time_from_checkpoint(checkpoint_file; model) ==
              t
        component_name = ClimaLand.name(model)
        state = getproperty(Y, component_name)
        restart_state = getproperty(Y_restart, component_name)
        for variable in ClimaLand.prognostic_vars(model)
            @test Array(parent(getproperty(restart_state, variable))) ==
                  Array(parent(getproperty(state, variable)))
        end
    end
    return nothing
end

function test_gridded_tendency(model, initial, expected, t, rtol)
    Y, p, _ = ClimaLand.initialize(model)
    component_name = ClimaLand.name(model)
    state = getproperty(Y, component_name)
    for (variable, value) in zip(ClimaLand.prognostic_vars(model), initial)
        getproperty(state, variable) .= value
    end

    ClimaLand.make_set_initial_cache(model)(p, Y, t)
    dY = similar(Y)
    ClimaLand.make_exp_tendency(model)(dY, Y, p, t)
    tendency = getproperty(dY, component_name)
    for (variable, expected_value) in
        zip(ClimaLand.prognostic_vars(model), expected)
        values = vec(Array(parent(getproperty(tendency, variable))))
        @test length(values) > 1
        @test all(isfinite, values)
        @test all(isapprox.(values, expected_value; rtol, atol = zero(rtol)))
    end
    return nothing
end

function test_model_diagnostics(model, Y, p, t)
    diagnostics = ClimaLand.Diagnostics
    possible = diagnostics.get_possible_diagnostics(model)
    highlighted = diagnostics.get_short_diagnostics(model)
    @test !isempty(possible)
    @test all(name -> name in possible, highlighted)
    diagnostics.define_diagnostics!(model, possible)
    for short_name in possible
        diagnostic = diagnostics.get_diagnostic_variable(short_name)
        values = diagnostic.compute!(nothing, Y, p, t)
        @test all(isfinite, vec(Array(parent(values))))
    end
    return nothing
end

function trajectory_entry(values::NamedTuple, variable)
    hasproperty(values, variable) ||
        throw(ArgumentError("trajectory data are missing `$variable`"))
    return getproperty(values, variable)
end

function trajectory_entry(values::AbstractDict, variable)
    haskey(values, variable) ||
        throw(ArgumentError("trajectory data are missing `$variable`"))
    return values[variable]
end

trajectory_values(value::Number) = (value,)
trajectory_values(value) = vec(collect(value))

function trajectory_tolerance(tolerances, variable)
    tolerance = trajectory_entry(tolerances, variable)
    hasproperty(tolerance, :atol) ||
        throw(ArgumentError("the tolerance for `$variable` must define `atol`"))
    hasproperty(tolerance, :rtol) ||
        throw(ArgumentError("the tolerance for `$variable` must define `rtol`"))
    tolerance.atol >= 0 || throw(
        ArgumentError("the absolute tolerance for `$variable` is negative"),
    )
    tolerance.rtol >= 0 || throw(
        ArgumentError("the relative tolerance for `$variable` is negative"),
    )
    return tolerance
end

function validate_trajectory_exceptions(
    reference,
    exception_steps,
    nsteps,
    variables,
)
    skipped_comparisons = Set{Tuple{Symbol, Int}}()
    for (name, exception) in pairs(exception_steps)
        name isa Union{Symbol, AbstractString} || throw(
            ArgumentError("trajectory exceptions must be explicitly named"),
        )
        for property in (:step, :variable, :minimum_increment_change)
            hasproperty(exception, property) || throw(
                ArgumentError(
                    "trajectory exception `$name` must define `$property`",
                ),
            )
        end
        step = exception.step
        3 <= step <= nsteps || throw(
            ArgumentError(
                "trajectory exception `$name` has step $step; exception steps must lie between 3 and $nsteps",
            ),
        )
        exception.minimum_increment_change > 0 || throw(
            ArgumentError(
                "trajectory exception `$name` must have a positive `minimum_increment_change`",
            ),
        )
        exception.variable in variables || throw(
            ArgumentError(
                "trajectory exception `$name` names non-prognostic variable `$(exception.variable)`",
            ),
        )
        snapshots = trajectory_entry(reference, exception.variable)
        length(snapshots) == nsteps || throw(
            ArgumentError(
                "reference variable `$(exception.variable)` has $(length(snapshots)) snapshots; expected $nsteps",
            ),
        )
        before_previous = trajectory_values(snapshots[step - 2])
        previous = trajectory_values(snapshots[step - 1])
        current = trajectory_values(snapshots[step])
        length(before_previous) == length(previous) == length(current) || throw(
            ArgumentError(
                "reference variable `$(exception.variable)` changes shape around exception `$name`",
            ),
        )
        increment_change =
            maximum(abs.(current .- previous .- (previous .- before_previous)))
        increment_change >= exception.minimum_increment_change || throw(
            ArgumentError(
                "trajectory exception `$name` is not discontinuous: achieved increment change $increment_change is below $(exception.minimum_increment_change)",
            ),
        )
        push!(skipped_comparisons, (exception.variable, step))
    end
    return skipped_comparisons
end

"""
    test_driven_trajectory(
        model,
        drivers,
        reference,
        tolerances;
        exception_steps = NamedTuple(),
    )

Run `model` from one initial state and compare its public prognostic state at
every requested time. `drivers` supplies `times`, `initial_state`, and an
`advance!` callable with signature `(Y, p, t, dt)`. `reference` supplies one
snapshot per time for every variable returned by
`ClimaLand.prognostic_vars(model)`, and `tolerances` supplies an `atol` and
`rtol` for each variable.

Named variable-step comparisons may be omitted when the reference has a known
discontinuity. Each exception specifies `step`, `variable`, and a positive
`minimum_increment_change`. The helper verifies that the reference
trajectory's increment actually changes by at least that amount before
skipping that variable at the specified step.

The return value reports the achieved maximum absolute and relative errors,
the step of the maximum absolute error, and the number of compared steps for
every prognostic variable. No auxiliary state or model-internal kernel is
inspected.
"""
function test_driven_trajectory(
    model,
    drivers,
    reference,
    tolerances;
    exception_steps = NamedTuple(),
)
    for property in (:times, :initial_state, :advance!)
        hasproperty(drivers, property) ||
            throw(ArgumentError("trajectory drivers must define `$property`"))
    end
    times = drivers.times
    isempty(times) && throw(
        ArgumentError("trajectory drivers must contain at least one time"),
    )
    all(times[index] > times[index - 1] for index in 2:length(times)) || throw(
        ArgumentError("trajectory driver times must be strictly increasing"),
    )

    variables = ClimaLand.prognostic_vars(model)
    isempty(variables) &&
        throw(ArgumentError("the model has no prognostic variables"))
    nsteps = length(times)
    skipped_comparisons = validate_trajectory_exceptions(
        reference,
        exception_steps,
        nsteps,
        variables,
    )
    metrics = Dict{Symbol, Any}()
    for variable in variables
        snapshots = trajectory_entry(reference, variable)
        length(snapshots) == nsteps || throw(
            ArgumentError(
                "reference variable `$variable` has $(length(snapshots)) snapshots; expected $nsteps",
            ),
        )
        trajectory_entry(drivers.initial_state, variable)
        trajectory_tolerance(tolerances, variable)
        metrics[variable] = (
            maximum_absolute_error = 0.0,
            maximum_relative_error = 0.0,
            maximum_absolute_error_step = 0,
            compared_steps = 0,
        )
    end

    Y, p, _ = ClimaLand.initialize(model)
    component = getproperty(Y, ClimaLand.name(model))
    for variable in variables
        field = getproperty(component, variable)
        initial = trajectory_entry(drivers.initial_state, variable)
        destination = vec(parent(field))
        if initial isa Number
            length(destination) == 1 || throw(
                ArgumentError(
                    "initial variable `$variable` is scalar; model state has $(length(destination)) values",
                ),
            )
            destination[begin] = initial
        else
            values = trajectory_values(initial)
            length(destination) == length(values) || throw(
                ArgumentError(
                    "initial variable `$variable` has $(length(values)) values; model state has $(length(destination))",
                ),
            )
            destination .= values
        end
    end
    ClimaLand.make_set_initial_cache(model)(p, Y, first(times))

    for step in eachindex(times)
        if step > firstindex(times)
            previous_step = step - 1
            drivers.advance!(
                Y,
                p,
                times[previous_step],
                times[step] - times[previous_step],
            )
        end
        for variable in variables
            (variable, step) in skipped_comparisons && continue
            actual = vec(Array(parent(getproperty(component, variable))))
            expected =
                trajectory_values(trajectory_entry(reference, variable)[step])
            length(actual) == length(expected) || throw(
                ArgumentError(
                    "reference variable `$variable` has $(length(expected)) values at step $step; model state has $(length(actual))",
                ),
            )
            tolerance = trajectory_tolerance(tolerances, variable)
            absolute_errors = abs.(actual .- expected)
            allowed_errors = tolerance.atol .+ tolerance.rtol .* abs.(expected)
            @test all(absolute_errors .<= allowed_errors)

            relative_errors = map(absolute_errors, expected) do absolute, value
                iszero(value) ? (iszero(absolute) ? zero(absolute) : Inf) :
                absolute / abs(value)
            end
            maximum_absolute = maximum(absolute_errors)
            entry = metrics[variable]
            maximum_step =
                if entry.compared_steps == 0 ||
                   maximum_absolute > entry.maximum_absolute_error
                    step
                else
                    entry.maximum_absolute_error_step
                end
            metrics[variable] = (
                maximum_absolute_error = max(
                    entry.maximum_absolute_error,
                    maximum_absolute,
                ),
                maximum_relative_error = max(
                    entry.maximum_relative_error,
                    maximum(relative_errors),
                ),
                maximum_absolute_error_step = maximum_step,
                compared_steps = entry.compared_steps + 1,
            )
        end
    end

    return NamedTuple{variables}(map(variable -> metrics[variable], variables))
end
