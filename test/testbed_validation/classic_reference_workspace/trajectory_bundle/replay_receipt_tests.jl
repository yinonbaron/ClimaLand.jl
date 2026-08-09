@testset "free replay writes a machine-readable evidence receipt" begin
    mktempdir() do directory
        replay = synthetic_generated_replay(directory; step_count = 2)
        contract_hash = repeat("d", 64)
        flux_tolerances =
            Dict(name => 0.0 for (name, _) in FREE_REPLAY_AUDIT_SHAPES)
        report = free_replay(
            replay,
            zero_flux_transition;
            day_one_flux_tolerances = flux_tolerances,
            day_one_flux_tolerance_contract_sha256 = contract_hash,
        )
        path = joinpath(directory, "replay_receipt.toml")
        bundle_hash = repeat("e", 64)

        write_replay_receipt(path, report, bundle_hash)

        receipt = TOML.parsefile(path)
        @test receipt["status"] == "pass"
        @test receipt["bundle_manifest_sha256"] == bundle_hash
        @test receipt["initialization_count"] == 1
        @test receipt["recurrent_state_replacements"] == 0
        @test receipt["max_state_error"] == 0.0
        @test receipt["max_flux_error"] == 0.0
        @test receipt["max_carbon_closure"] == 0.0
        @test receipt["day_one_exact"]
        @test receipt["day_one_state_exact"]
        @test receipt["day_one_flux_within_tolerance"]
        @test receipt["day_one_flux_tolerances"] == flux_tolerances
        @test receipt["day_one_flux_tolerance_contract_sha256"] == contract_hash
        @test receipt["state_ok"]
        @test receipt["flux_ok"]
        @test receipt["closure_ok"]
        @test receipt["drift_ok"]
        @test receipt["max_state_errors"]["reference.post_litrmass"] == 0.0
        @test receipt["max_flux_errors"]["audit.ltresveg"] == 0.0
        @test receipt["units"]["reference.post_litrmass"] == "kg C m-2"
        @test receipt["units"]["audit.ltresveg"] == "umol CO2 m-2 s-1"
        @test receipt["accumulated_drift"] == 0.0
        @test length(receipt["step"]) == 2
        @test_throws ArgumentError write_replay_receipt(
            path,
            report,
            bundle_hash,
        )
    end
end
