@testset "generated bundle binds every raw event" begin
    trajectory_schema = joinpath(@__DIR__, "schema.toml")
    snapshot_schema =
        joinpath(@__DIR__, "..", "stage_b_snapshots", "schema.toml")
    mktempdir() do directory
        capture = write_synthetic_daily_capture(
            joinpath(directory, "capture"),
            snapshot_schema;
            step_count = 2,
        )
        bundle = generate_trajectory_bundle(
            joinpath(directory, "bundle"),
            capture.root,
            trajectory_schema,
            snapshot_schema,
            capture.time_index,
            capture.receipt,
        )
        manifest = TOML.parsefile(joinpath(bundle, "manifest.toml"))

        @test all(
            ClassicTrajectoryBundle.valid_sha256(step["raw_event_sha256"]) for
            step in manifest["step"]
        )
        index_path =
            joinpath(bundle, manifest["evidence"]["sealed_event_index_path"])
        @test isfile(index_path)
        @test trajectory_test_sha256_file(index_path) ==
              manifest["evidence"]["sealed_event_index_sha256"]
        @test length(TOML.parsefile(index_path)["event"]) == 2
    end
end
