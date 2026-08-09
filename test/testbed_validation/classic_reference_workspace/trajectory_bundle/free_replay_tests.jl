function zero_flux_transition(state, static_data, drivers, time_start, time_end)
    @test Set(keys(state)) == Set(("litrmass", "soilcmas"))
    @test all(startswith(name, "driver.") for name in keys(drivers))
    @test !any(startswith(name, "reference.") for name in keys(drivers))
    checkpoints = Dict(
        "reference.after_pool_update_litrmass" => copy(state["litrmass"]),
        "reference.after_pool_update_soilcmas" => copy(state["soilcmas"]),
        "reference.before_turbation_litrmass" => copy(state["litrmass"]),
        "reference.before_turbation_soilcmas" => copy(state["soilcmas"]),
    )
    audits = Dict(
        name => zeros(size(values)) for
        (name, values) in FREE_REPLAY_AUDIT_SHAPES
    )
    return (;
        state = Dict(
            "litrmass" => copy(state["litrmass"]),
            "soilcmas" => copy(state["soilcmas"]),
        ),
        checkpoints,
        audits,
    )
end

function synthetic_generated_replay(directory; step_count = 3)
    trajectory_schema = joinpath(@__DIR__, "schema.toml")
    snapshot_schema =
        joinpath(@__DIR__, "..", "stage_b_snapshots", "schema.toml")
    capture = write_synthetic_daily_capture(
        joinpath(directory, "capture"),
        snapshot_schema;
        step_count,
    )
    bundle = generate_trajectory_bundle(
        joinpath(directory, "bundle"),
        capture.root,
        trajectory_schema,
        snapshot_schema,
        capture.time_index,
        capture.receipt,
    )
    return open_replay(bundle, trajectory_schema)
end

@testset "free replay initializes once and reports independent metrics" begin
    mktempdir() do directory
        replay = synthetic_generated_replay(directory)
        report = free_replay(replay, zero_flux_transition)

        @test report.ok
        @test report.initialization_count == 1
        @test report.recurrent_state_replacements == 0
        @test length(report.steps) == 3
        @test report.max_state_error == 0.0
        @test report.max_flux_error == 0.0
        @test report.max_carbon_closure == 0.0
        @test report.day_one_exact
        @test report.state_ok
        @test report.flux_ok
        @test report.closure_ok
        @test report.drift_ok
        @test all(step.carbon_closure == 0.0 for step in report.steps)
        @test report.accumulated_drift == 0.0
    end
end

@testset "free replay carries Julia state instead of replacing it" begin
    mktempdir() do directory
        replay = synthetic_generated_replay(directory; step_count = 2)
        function drifting_transition(
            state,
            static_data,
            drivers,
            time_start,
            time_end,
        )
            state["litrmass"] .+= 1.0
            result = zero_flux_transition(
                state,
                static_data,
                drivers,
                time_start,
                time_end,
            )
            return result
        end
        report = free_replay(replay, drifting_transition)

        @test !report.ok
        @test [step.state_error for step in report.steps] == [1.0, 2.0]
        @test report.max_state_error == 2.0
        @test report.recurrent_state_replacements == 0
        @test report.steps[1].carbon_closure == 260.0
        @test report.steps[2].carbon_closure == 260.0
        @test report.naive_accumulated_drift == 520.0
        @test report.accumulated_drift == 520.0
    end
end

@testset "free replay requires every checkpoint and meaningful flux" begin
    mktempdir() do directory
        replay = synthetic_generated_replay(directory; step_count = 1)
        incomplete(state, static_data, drivers, time_start, time_end) = (;
            state,
            checkpoints = Dict{String, Any}(),
            audits = Dict{String, Any}(),
        )
        @test_throws ArgumentError free_replay(replay, incomplete)
    end
end

@testset "accumulated drift is gated independently" begin
    mktempdir() do directory
        replay = synthetic_generated_replay(directory; step_count = 2)
        function drifting_budget(
            state,
            static_data,
            drivers,
            time_start,
            time_end,
        )
            result = zero_flux_transition(
                state,
                static_data,
                drivers,
                time_start,
                time_end,
            )
            result.audits["audit.litter_clamp_correction"][1] = 1.0
            return result
        end
        report = free_replay(replay, drifting_budget; atol = 1.5, rtol = 0.0)

        @test report.state_ok
        @test report.flux_ok
        @test report.closure_ok
        @test !report.drift_ok
        @test report.max_carbon_closure == 1.0
        @test report.accumulated_drift == -2.0
        @test !report.ok
    end
end
