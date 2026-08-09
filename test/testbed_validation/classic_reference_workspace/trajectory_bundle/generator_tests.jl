@testset "all-daily snapshots generate a chronological forcing bundle" begin
    trajectory_schema = joinpath(@__DIR__, "schema.toml")
    snapshot_schema =
        joinpath(@__DIR__, "..", "stage_b_snapshots", "schema.toml")
    mktempdir() do directory
        capture = write_synthetic_daily_capture(
            joinpath(directory, "capture"),
            snapshot_schema;
            step_count = 3,
        )
        bundle = joinpath(directory, "bundle")

        generate_trajectory_bundle(
            bundle,
            capture.root,
            trajectory_schema,
            snapshot_schema,
            capture.time_index,
            capture.receipt,
        )

        report = validate_bundle(bundle, trajectory_schema)
        @test report.ok
        replay = open_replay(bundle, trajectory_schema)
        @test length(replay.steps) == 3
        @test Set(keys(replay.initial_state)) ==
              Set(("initial.litrmass", "initial.soilcmas"))
        @test haskey(replay.static_data, "static.zbot")
        @test haskey(replay.static_data, "static.delzw")
        @test replay.steps[1].time_end == replay.steps[2].time_start
        @test all(
            !startswith(name, "pre.") for step in replay.steps for
            name in keys(step.drivers)
        )
        @test report.manifest["provenance"]["capture_receipt_sha256"] ==
              trajectory_test_sha256_file(capture.receipt)
        @test report.manifest["provenance"]["snapshot_schema_sha256"] ==
              trajectory_test_sha256_file(snapshot_schema)
        @test report.manifest["evidence"]["status"] == "synthetic"
    end
end

@testset "generator fails closed on discontinuity and incomplete receipts" begin
    trajectory_schema = joinpath(@__DIR__, "schema.toml")
    snapshot_schema =
        joinpath(@__DIR__, "..", "stage_b_snapshots", "schema.toml")
    mktempdir() do directory
        capture = write_synthetic_daily_capture(
            joinpath(directory, "capture"),
            snapshot_schema;
            step_count = 2,
        )
        second_pre = joinpath(
            capture.root,
            "daily",
            "event_00000002.raw",
            "pre.litrmass.bin",
        )
        open(second_pre, "r+") do io
            write(io, htol(reinterpret(UInt64, 99.0)))
        end
        @test_throws ArgumentError generate_trajectory_bundle(
            joinpath(directory, "discontinuous"),
            capture.root,
            trajectory_schema,
            snapshot_schema,
            capture.time_index,
            capture.receipt,
        )

        capture = write_synthetic_daily_capture(
            joinpath(directory, "capture_missing_receipt"),
            snapshot_schema;
            step_count = 2,
        )
        receipt = TOML.parsefile(capture.receipt)
        delete!(receipt["provenance"], "execution_receipt_sha256")
        open(capture.receipt, "w") do io
            TOML.print(io, receipt; sorted = true)
        end
        @test_throws ArgumentError generate_trajectory_bundle(
            joinpath(directory, "incomplete"),
            capture.root,
            trajectory_schema,
            snapshot_schema,
            capture.time_index,
            capture.receipt,
        )
    end
end

@testset "generator preserves a non-DE-Hai site identity" begin
    trajectory_schema = joinpath(@__DIR__, "schema.toml")
    snapshot_schema =
        joinpath(@__DIR__, "..", "stage_b_snapshots", "schema.toml")
    mktempdir() do directory
        capture = write_synthetic_daily_capture(
            joinpath(directory, "capture"),
            snapshot_schema;
            step_count = 2,
        )
        index = TOML.parsefile(capture.time_index)
        index["site"] = "GF-Guy"
        open(capture.time_index, "w") do io
            TOML.print(io, index; sorted = true)
        end
        receipt = TOML.parsefile(capture.receipt)
        receipt["site"] = "GF-Guy"
        comparison_path = joinpath(
            capture.root,
            receipt["provenance"]["nonperturbation_receipt_path"],
        )
        comparison = TOML.parsefile(comparison_path)
        comparison["record_count_per_daily_file"] = 4018
        open(comparison_path, "w") do io
            TOML.print(io, comparison; sorted = true)
        end
        receipt["provenance"]["nonperturbation_receipt_sha256"] =
            trajectory_test_sha256_file(comparison_path)
        receipt["provenance"]["time_index_sha256"] =
            trajectory_test_sha256_file(capture.time_index)
        open(capture.receipt, "w") do io
            TOML.print(io, receipt; sorted = true)
        end

        output = generate_trajectory_bundle(
            joinpath(directory, "bundle"),
            capture.root,
            trajectory_schema,
            snapshot_schema,
            capture.time_index,
            capture.receipt,
        )
        report = validate_bundle(output, trajectory_schema)
        @test report.ok
        @test report.manifest["trajectory"]["site"] == "GF-Guy"
    end
end
