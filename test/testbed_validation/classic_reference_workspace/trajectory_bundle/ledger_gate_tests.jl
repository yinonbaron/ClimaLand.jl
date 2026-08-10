@testset "generator binds the append-only Fortran completion ledger" begin
    trajectory_schema = joinpath(@__DIR__, "schema.toml")
    snapshot_schema =
        joinpath(@__DIR__, "..", "stage_b_snapshots", "schema.toml")
    mktempdir() do directory
        capture = write_synthetic_daily_capture(
            joinpath(directory, "capture"),
            snapshot_schema;
            step_count = 2,
        )
        receipt = TOML.parsefile(capture.receipt)
        delete!(receipt["provenance"], "completion_ledger_path")
        delete!(receipt["provenance"], "completion_ledger_sha256")
        open(capture.receipt, "w") do io
            TOML.print(io, receipt; sorted = true)
        end
        @test_throws ArgumentError generate_trajectory_bundle(
            joinpath(directory, "missing_ledger"),
            capture.root,
            trajectory_schema,
            snapshot_schema,
            capture.time_index,
            capture.receipt,
        )
    end
end

@testset "generator accepts the promoted all-daily ledger envelope" begin
    trajectory_schema = joinpath(@__DIR__, "schema.toml")
    snapshot_schema =
        joinpath(@__DIR__, "..", "stage_b_snapshots", "schema.toml")
    mktempdir() do directory
        capture = write_synthetic_daily_capture(
            joinpath(directory, "capture"),
            snapshot_schema;
            step_count = 2,
        )
        output = joinpath(directory, "bundle")
        @test generate_trajectory_bundle(
            output,
            capture.root,
            trajectory_schema,
            snapshot_schema,
            capture.time_index,
            capture.receipt,
        ) == output
    end
end
