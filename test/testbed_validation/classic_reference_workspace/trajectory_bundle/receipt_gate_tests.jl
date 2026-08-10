@testset "generator binds NetCDF time and validates evidence results" begin
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
        delete!(receipt["provenance"], "netcdf_time_receipt_path")
        delete!(receipt["provenance"], "netcdf_time_receipt_sha256")
        open(capture.receipt, "w") do io
            TOML.print(io, receipt; sorted = true)
        end
        @test_throws ArgumentError generate_trajectory_bundle(
            joinpath(directory, "missing_time_receipt"),
            capture.root,
            trajectory_schema,
            snapshot_schema,
            capture.time_index,
            capture.receipt,
        )
    end

    mktempdir() do directory
        capture = write_synthetic_daily_capture(
            joinpath(directory, "capture"),
            snapshot_schema;
            step_count = 2,
        )
        receipt = TOML.parsefile(capture.receipt)
        comparison_path = joinpath(
            capture.root,
            receipt["provenance"]["nonperturbation_receipt_path"],
        )
        comparison = TOML.parsefile(comparison_path)
        comparison["result"] = "fail"
        open(comparison_path, "w") do io
            TOML.print(io, comparison; sorted = true)
        end
        receipt["provenance"]["nonperturbation_receipt_sha256"] =
            trajectory_test_sha256_file(comparison_path)
        open(capture.receipt, "w") do io
            TOML.print(io, receipt; sorted = true)
        end
        @test_throws ArgumentError generate_trajectory_bundle(
            joinpath(directory, "failed_comparison"),
            capture.root,
            trajectory_schema,
            snapshot_schema,
            capture.time_index,
            capture.receipt,
        )
    end
end
