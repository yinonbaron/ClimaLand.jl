function day_one_flux_tolerances(; socres = 0.0)
    tolerances = Dict(name => 0.0 for (name, _) in FREE_REPLAY_AUDIT_SHAPES)
    tolerances["audit.socres"] = socres
    return tolerances
end

@testset "day-one state remains bit exact" begin
    mktempdir() do directory
        replay = synthetic_generated_replay(directory; step_count = 1)
        function state_bit_difference(
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
            result.state["litrmass"][1] = nextfloat(result.state["litrmass"][1])
            return result
        end
        report = free_replay(
            replay,
            state_bit_difference;
            atol = 1.0,
            rtol = 0.0,
            day_one_flux_tolerances = day_one_flux_tolerances(),
            day_one_flux_tolerance_contract_sha256 = repeat("a", 64),
        )

        @test report.state_ok
        @test !report.day_one_state_exact
        @test report.day_one_flux_within_tolerance
        @test !report.ok
    end
end

@testset "day-one flux uses hash-bound per-field tolerances" begin
    mktempdir() do directory
        replay = synthetic_generated_replay(directory; step_count = 1)
        function small_flux_difference(
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
            result.audits["audit.socres"][1] = 1.0e-16
            return result
        end
        contract_sha256 = repeat("b", 64)
        accepted = free_replay(
            replay,
            small_flux_difference;
            atol = 1.0,
            rtol = 0.0,
            day_one_flux_tolerances = day_one_flux_tolerances(;
                socres = 2.0e-16,
            ),
            day_one_flux_tolerance_contract_sha256 = contract_sha256,
        )
        rejected = free_replay(
            replay,
            small_flux_difference;
            atol = 1.0,
            rtol = 0.0,
            day_one_flux_tolerances = day_one_flux_tolerances(;
                socres = 0.5e-16,
            ),
            day_one_flux_tolerance_contract_sha256 = contract_sha256,
        )

        @test accepted.day_one_state_exact
        @test accepted.day_one_flux_within_tolerance
        @test !accepted.day_one_exact
        @test accepted.ok
        @test accepted.day_one_flux_tolerance_contract_sha256 == contract_sha256
        @test !rejected.day_one_flux_within_tolerance
        @test !rejected.ok
        @test_throws ArgumentError free_replay(
            replay,
            small_flux_difference;
            atol = 1.0,
            day_one_flux_tolerances = day_one_flux_tolerances(;
                socres = 2.0e-16,
            ),
        )
    end
end
