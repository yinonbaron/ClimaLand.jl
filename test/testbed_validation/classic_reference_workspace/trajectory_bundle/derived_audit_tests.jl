@testset "generator derives clamp and turbation conservation audits" begin
    trajectory_schema = joinpath(@__DIR__, "schema.toml")
    snapshot_schema =
        joinpath(@__DIR__, "..", "stage_b_snapshots", "schema.toml")
    mktempdir() do directory
        capture = write_synthetic_daily_capture(
            joinpath(directory, "capture"),
            snapshot_schema;
            step_count = 1,
        )
        event = joinpath(capture.root, "daily", "event_00000001.raw")

        litter = ones(1, 13, 20)
        litter[1] = 0.1
        write_raw_values(joinpath(event, "pre.litrmass.bin"), litter)
        litter_rate = zeros(1, 13, 20)
        litter_rate[1] = 96.362
        write_raw_values(joinpath(event, "audit.ltresveg.bin"), litter_rate)
        for name in (
            "intermediate.after_pool_update_litrmass",
            "intermediate.before_turbation_litrmass",
            "post.litrmass",
        )
            values = ones(1, 13, 20)
            values[1] = 0.0
            write_raw_values(joinpath(event, name * ".bin"), values)
        end
        turbation = zeros(1, 13, 20)
        turbation[1] = 0.25
        write_raw_values(
            joinpath(event, "audit.turbation_delta_litter.bin"),
            turbation,
        )

        bundle = generate_trajectory_bundle(
            joinpath(directory, "bundle"),
            capture.root,
            trajectory_schema,
            snapshot_schema,
            capture.time_index,
            capture.receipt,
        )
        step = only(open_replay(bundle, trajectory_schema).steps)

        @test step.audit_diagnostics["audit.litter_clamp_correction"][1] ≈ 0.1
        @test step.audit_diagnostics["audit.turbation_litter_column_residual"][1] ==
              0.25
    end
end
