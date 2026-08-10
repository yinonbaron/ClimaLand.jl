function rounded_primitive_terms(state, result, drivers, static_data)
    terms = Float64[]
    for pool in (result.state["litrmass"], result.state["soilcmas"])
        append!(terms, pool)
    end
    for pool in (state["litrmass"], state["soilcmas"])
        append!(terms, .-pool)
    end
    for (name, values) in drivers
        if occursin("_delta_litter", name) || occursin("_delta_soil", name)
            append!(terms, .-values)
        end
    end
    factor = Float64(only(static_data["parameter.deltat_days"])) / 963.62
    spinfast = Float64(only(static_data["parameter.spinfast"]))
    for (litter, humification, soil) in zip(
        result.audits["audit.ltresveg"],
        result.audits["audit.humtrsvg"],
        result.audits["audit.scresveg"],
    )
        push!(
            terms,
            (litter + humification - spinfast * (humification - soil)) * factor,
        )
    end
    for correction in (
        result.audits["audit.litter_clamp_correction"],
        result.audits["audit.soil_clamp_correction"],
    )
        append!(terms, .-correction)
    end
    return terms
end

function ledger_transition(state, static_data, drivers, time_start, time_end)
    result =
        zero_flux_transition(state, static_data, drivers, time_start, time_end)
    result.state["litrmass"][1] += 0.5
    result.state["soilcmas"][2] -= 0.125
    result.audits["audit.ltresveg"][1] = 0.75
    result.audits["audit.humtrsvg"][1] = 0.25
    result.audits["audit.scresveg"][1] = 0.125
    result.audits["audit.litter_clamp_correction"][2] = 0.0625
    result.audits["audit.soil_clamp_correction"][2] = 0.03125
    return result
end

@testset "Neumaier drift agrees with an offline BigFloat ledger" begin
    terms = [1.0e16, 1.0, -1.0e16]
    expected = Float64(sum(BigFloat.(terms)))

    @test sum(terms) == 0.0
    @test ClassicFreeReplay.neumaier_sum(terms) == expected == 1.0

    mktempdir() do directory
        replay = synthetic_generated_replay(directory; step_count = 2)
        for (index, step) in enumerate(replay.steps)
            for (name, values) in step.drivers
                if occursin("_delta_litter", name) ||
                   occursin("_delta_soil", name)
                    fill!(values, 0.0)
                    values[1] = 0.01 * index
                end
            end
        end
        state = Dict(
            "litrmass" => copy(replay.initial_state["initial.litrmass"]),
            "soilcmas" => copy(replay.initial_state["initial.soilcmas"]),
        )
        primitive_terms = Float64[]
        for step in replay.steps
            result = ledger_transition(
                state,
                replay.static_data,
                step.drivers,
                step.time_start,
                step.time_end,
            )
            append!(
                primitive_terms,
                rounded_primitive_terms(
                    state,
                    result,
                    step.drivers,
                    replay.static_data,
                ),
            )
            state = result.state
        end
        report = free_replay(replay, ledger_transition; atol = 1.0, rtol = 0.0)
        bigfloat_oracle = Float64(sum(BigFloat.(primitive_terms)))
        term_scale = 0.0
        for term in primitive_terms
            term_scale += abs(term)
        end

        @test report.accumulated_drift == bigfloat_oracle
        @test report.drift_term_count == length(primitive_terms)
        @test report.drift_term_scale == term_scale
        @test report.drift_algorithm == "neumaier_signed_primitive_ledger"
        @test report.drift_algorithm_version == 1
        @test report.drift_oracle_conversion ==
              "Float64 primitive terms; BigFloat summation oracle"
    end
end

@testset "compensated ledger rejects injected physical drift" begin
    mktempdir() do directory
        replay = synthetic_generated_replay(directory; step_count = 2)
        function physical_drift(
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
        report = free_replay(replay, physical_drift; atol = 1.5, rtol = 0.0)

        @test report.state_ok
        @test report.flux_ok
        @test report.closure_ok
        @test !report.drift_ok
        @test report.drift_algorithm == "neumaier_signed_primitive_ledger"
        @test report.drift_algorithm_version == 1
        @test report.drift_term_count > 0
        @test report.drift_term_scale > 0.0
        @test report.naive_accumulated_drift == -2.0
        @test report.accumulated_drift == -2.0
        @test !report.ok
    end
end

@testset "replay receipt records compensated drift evidence" begin
    mktempdir() do directory
        replay = synthetic_generated_replay(directory; step_count = 2)
        report = free_replay(replay, zero_flux_transition)
        path = joinpath(directory, "replay_receipt.toml")
        write_replay_receipt(path, report, repeat("e", 64))
        receipt = TOML.parsefile(path)

        @test receipt["naive_accumulated_drift"] == 0.0
        @test receipt["accumulated_drift"] == 0.0
        @test receipt["drift_algorithm"] == "neumaier_signed_primitive_ledger"
        @test receipt["drift_algorithm_version"] == 1
        @test receipt["drift_oracle_conversion"] ==
              "Float64 primitive terms; BigFloat summation oracle"
        @test receipt["drift_term_count"] == report.drift_term_count
        @test receipt["drift_term_scale"] == report.drift_term_scale
        @test all(
            haskey(step, "compensated_carbon_closure") &&
                haskey(step, "naive_accumulated_drift") for
            step in receipt["step"]
        )
    end
end

@testset "scale-aware compensated roundoff bound" begin
    n = 4_940
    scale = 902.9890184744821
    bound = ClassicFreeReplay.compensated_roundoff_bound(n, scale)

    @test ClassicFreeReplay.COMPENSATED_ROUNDOFF_BOUND_VERSION == 1
    @test ClassicFreeReplay.COMPENSATED_ROUNDOFF_BOUND_FORMULA ==
          "up((2u + gamma_(4n+1)^2) * S_upper)"
    @test ClassicFreeReplay.FLOAT64_UNIT_ROUNDOFF == 2.0^-53
    @test bound > 0.0
    @test isapprox(
        ClassicFreeReplay.compensated_roundoff_bound(n, 10scale),
        10bound;
        rtol = 4eps(Float64),
    )
    @test ClassicFreeReplay.within_compensated_roundoff_bound(
        prevfloat(bound),
        n,
        scale,
        0.0,
    )
    @test !ClassicFreeReplay.within_compensated_roundoff_bound(
        nextfloat(bound),
        n,
        scale,
        0.0,
    )
end


@testset "upper scale and bound cannot round downward" begin
    terms = [1.0, 2.0^-54, 2.0^-54]
    accumulator = ClassicFreeReplay.NeumaierAccumulator()
    foreach(term -> ClassicFreeReplay.add_term!(accumulator, term), terms)
    exact_scale = sum(BigFloat(abs(term)) for term in terms)
    evidence = ClassicFreeReplay.compensated_roundoff_evidence(
        accumulator.term_count,
        accumulator.term_scale,
    )
    exact_bound = setprecision(BigFloat, 256) do
        u = BigFloat(2)^-53
        ku = BigFloat(evidence.neumaier_operation_count) * u
        gamma = ku / (1 - ku)
        (2u + gamma^2) * exact_scale
    end

    @test BigFloat(accumulator.term_scale) < exact_scale
    @test BigFloat(evidence.upper_scale) >= exact_scale
    @test BigFloat(evidence.bound) >= exact_bound
    @test evidence.scale_operation_count == length(terms) - 1
    @test evidence.neumaier_operation_count == 4length(terms) + 1
end
@testset "scale-aware gate rejects injected physical drift" begin
    mktempdir() do directory
        replay = synthetic_generated_replay(directory; step_count = 2)
        function injected_drift(
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
            result.audits["audit.litter_clamp_correction"][1] = 1.0e-6
            return result
        end
        report = free_replay(replay, injected_drift; atol = 0.0, rtol = 0.0)

        @test !report.closure_ok
        @test !report.drift_ok
        @test abs(report.accumulated_drift) == 2.0e-6
        @test abs(report.accumulated_drift) > report.drift_roundoff_bound
        @test report.drift_roundoff_ratio > 1.0
        @test !report.ok
    end
end

@testset "receipt records scale-aware roundoff evidence" begin
    mktempdir() do directory
        replay = synthetic_generated_replay(directory; step_count = 2)
        report = free_replay(replay, zero_flux_transition)
        path = joinpath(directory, "scale_aware_receipt.toml")
        write_replay_receipt(path, report, repeat("f", 64))
        receipt = TOML.parsefile(path)

        @test receipt["roundoff_bound_formula"] ==
              "up((2u + gamma_(4n+1)^2) * S_upper)"
        @test receipt["roundoff_bound_version"] == 1
        @test receipt["roundoff_unit_roundoff"] == 2.0^-53
        @test receipt["roundoff_oracle_conversion"] ==
              "Float64 primitive terms; BigFloat summation oracle"
        @test occursin(
            "already-rounded primitive terms",
            receipt["roundoff_bound_assumptions"],
        )
        @test receipt["drift_roundoff_term_count"] == report.drift_term_count
        @test receipt["drift_roundoff_term_scale"] == report.drift_term_scale
        @test receipt["drift_roundoff_term_scale_upper"] >=
              receipt["drift_roundoff_term_scale"]
        @test receipt["drift_roundoff_scale_operation_count"] ==
              report.drift_term_count - 1
        @test receipt["drift_roundoff_operation_count"] ==
              4report.drift_term_count + 1
        @test receipt["drift_roundoff_bound"] == report.drift_roundoff_bound
        @test receipt["drift_roundoff_residual"] == report.accumulated_drift
        @test receipt["drift_roundoff_ratio"] == report.drift_roundoff_ratio
        @test all(
            haskey(step, "roundoff_term_count") &&
                haskey(step, "roundoff_term_scale") &&
                haskey(step, "roundoff_term_scale_upper") &&
                haskey(step, "roundoff_operation_count") &&
                haskey(step, "roundoff_bound") &&
                haskey(step, "roundoff_residual") &&
                haskey(step, "roundoff_ratio") for step in receipt["step"]
        )
    end
end
