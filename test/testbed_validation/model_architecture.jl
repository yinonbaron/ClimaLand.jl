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
