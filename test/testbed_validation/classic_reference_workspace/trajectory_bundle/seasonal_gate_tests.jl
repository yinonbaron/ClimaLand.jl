@testset "complete evidence requires a declared seasonal cycle" begin
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
        receipt["status"] = "complete"
        open(capture.receipt, "w") do io
            TOML.print(io, receipt; sorted = true)
        end
        @test_throws ArgumentError generate_trajectory_bundle(
            joinpath(directory, "not_seasonal"),
            capture.root,
            trajectory_schema,
            snapshot_schema,
            capture.time_index,
            capture.receipt,
        )
    end
end

function rewrite_time_index_receipt!(mutate!, capture)
    index = TOML.parsefile(capture.time_index)
    mutate!(index)
    open(capture.time_index, "w") do io
        TOML.print(io, index; sorted = true)
    end
    receipt = TOML.parsefile(capture.receipt)
    receipt["provenance"]["time_index_sha256"] =
        trajectory_test_sha256_file(capture.time_index)
    open(capture.receipt, "w") do io
        TOML.print(io, receipt; sorted = true)
    end
end

@testset "calendar normalization rejects unsupported source calendars" begin
    trajectory_schema = joinpath(@__DIR__, "schema.toml")
    snapshot_schema =
        joinpath(@__DIR__, "..", "stage_b_snapshots", "schema.toml")
    mktempdir() do directory
        capture = write_synthetic_daily_capture(
            joinpath(directory, "capture"),
            snapshot_schema;
            step_count = 2,
        )
        rewrite_time_index_receipt!(capture) do index
            index["source_calendar"] = "360_day"
        end
        @test_throws ArgumentError generate_trajectory_bundle(
            joinpath(directory, "unsupported_calendar"),
            capture.root,
            trajectory_schema,
            snapshot_schema,
            capture.time_index,
            capture.receipt,
        )
    end
end

@testset "calendar normalization rejects pre-Gregorian intervals" begin
    trajectory_schema = joinpath(@__DIR__, "schema.toml")
    snapshot_schema =
        joinpath(@__DIR__, "..", "stage_b_snapshots", "schema.toml")
    mktempdir() do directory
        capture = write_synthetic_daily_capture(
            joinpath(directory, "capture"),
            snapshot_schema;
            step_count = 2,
        )
        rewrite_time_index_receipt!(capture) do index
            start = DateTime(1500, 1, 1)
            for event in index["event"]
                event["time_start"] = string(start + Day(event["index"] - 1))
                event["time_end"] = string(start + Day(event["index"]))
            end
        end
        @test_throws ArgumentError generate_trajectory_bundle(
            joinpath(directory, "pre_cutover"),
            capture.root,
            trajectory_schema,
            snapshot_schema,
            capture.time_index,
            capture.receipt,
        )
    end
end
