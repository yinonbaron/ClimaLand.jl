@testset "neutral CLASSIC callback adapter owns one ordered lifecycle" begin
    replay = callback_replay()
    transition = classic_callback_transition(replay)
    report = free_replay(replay, transition; atol = 0.0, rtol = 0.0)
    @test report.ok
    @test report.initialization_count == 1
    @test report.recurrent_state_replacements == 0
    @test length(report.steps) == 2

    transition = classic_callback_transition(replay)
    state = callback_initial_state(replay)
    first_result = transition(
        state,
        replay.static_data,
        replay.steps[1].drivers,
        replay.steps[1].reference_state,
        replay.steps[1].audit_diagnostics,
    )
    @test Set(keys(first_result.state)) == Set(("litrmass", "soilcmas"))
    @test Set(keys(first_result.checkpoints)) ==
          ClassicFreeReplay.CHECKPOINT_NAMES
    @test Set(keys(first_result.audits)) ==
          Set(first.(ClassicFreeReplay.FREE_REPLAY_AUDIT_SHAPES))
    @test first_result.state["litrmass"][1, 1, 1] == 1.0
    second_result = transition(
        first_result.state,
        replay.static_data,
        replay.steps[2].drivers,
        replay.steps[2].reference_state,
        replay.steps[2].audit_diagnostics,
    )
    @test second_result.state["litrmass"][1, 1, 1] == 1.0
    @test_throws ArgumentError transition(
        second_result.state,
        replay.static_data,
        replay.steps[2].drivers,
        nothing,
        nothing,
    )

    replacement = callback_initial_state(replay)
    replacement["litrmass"][1, 1, 1] = 2.0
    @test_throws ArgumentError classic_callback_transition(replay)(
        replacement,
        replay.static_data,
        replay.steps[1].drivers,
        nothing,
        nothing,
    )
    @test_throws ArgumentError classic_callback_transition(replay)(
        callback_initial_state(replay),
        replay.static_data,
        replay.steps[2].drivers,
        nothing,
        nothing,
    )
end
