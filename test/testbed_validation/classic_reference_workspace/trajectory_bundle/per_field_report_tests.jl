@testset "free replay reports every state and flux comparison" begin
    mktempdir() do directory
        replay = synthetic_generated_replay(directory; step_count = 1)
        report = free_replay(replay, zero_flux_transition)
        step = only(report.steps)

        @test Set(keys(step.state_errors)) ==
              Set(keys(replay.steps[1].reference_state))
        @test Set(keys(step.flux_errors)) ==
              Set(keys(replay.steps[1].audit_diagnostics))
        @test all(iszero, values(step.state_errors))
        @test all(iszero, values(step.flux_errors))
    end
end
