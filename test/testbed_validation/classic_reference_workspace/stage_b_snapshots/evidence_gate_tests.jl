using Test
using TOML

include("snapshots.jl")
include("schema.jl")
include("evidence_gate.jl")
using .StageBSnapshots
using .StageBSnapshotEvidence

function write_synthetic_schema(path)
    write(
        path,
        """
        schema_version = 1
        scope = "synthetic Stage B"
        site = "DE-Hai"
        storage_order = "fortran_column_major"
        endianness = "little"
        [dimensions]
        tile = 1

        [[field]]
        name = "pre.litrmass"
        phase = "pre_state"
        role = "owned_state"
        units = "kg C m-2"
        dtype = "float32"
        shape = [1]
        dimensions = ["tile"]

        [[field]]
        name = "post.litrmass"
        phase = "post_state"
        role = "reference_state"
        units = "kg C m-2"
        dtype = "float32"
        shape = [1]
        dimensions = ["tile"]
        """,
    )
end

function write_complete_snapshot(path, transition, patch_sha256)
    fields = [
        snapshot_field(
            "pre.litrmass",
            :pre_state,
            :owned_state,
            "kg C m-2",
            Float32[1],
        ),
        snapshot_field(
            "post.litrmass",
            :post_state,
            :reference_state,
            "kg C m-2",
            Float32[0.9],
        ),
    ]
    write_snapshot(
        path,
        fields;
        transition,
        site = "DE-Hai",
        source_sha256 = repeat("a", 64),
        patch_sha256,
    )
end

@testset "Stage B evidence gate requires two snapshots and pristine parity" begin
    mktempdir() do directory
        schema = joinpath(directory, "schema.toml")
        patch = joinpath(directory, "instrumentation.patch")
        receipt = joinpath(directory, "instrumentation_receipt.toml")
        comparison = joinpath(directory, "comparison.toml")
        ordinary = joinpath(directory, "ordinary")
        difficult = joinpath(directory, "frozen_soil")
        write_synthetic_schema(schema)
        write(patch, "deterministic patch\n")
        patch_sha256 = sha256sum(patch)
        open(receipt, "w") do io
            TOML.print(
                io,
                Dict(
                    "schema_version" => 1,
                    "status" => "complete",
                    "source_sha256" => repeat("a", 64),
                    "patch_path" => basename(patch),
                    "patch_sha256" => patch_sha256,
                );
                sorted = true,
            )
        end
        open(comparison, "w") do io
            TOML.print(
                io,
                Dict(
                    "schema_version" => 1,
                    "result" => "pass",
                    "criteria" => "exact values, coordinates, masks, dimensions, types, and units",
                    "compared_files" => 57,
                    "failed_files" => 0,
                );
                sorted = true,
            )
        end
        write_complete_snapshot(ordinary, "ordinary", patch_sha256)
        write_complete_snapshot(difficult, "frozen_soil", patch_sha256)

        report = verify_stage_b_evidence(
            schema,
            ordinary,
            difficult,
            receipt,
            comparison,
        )
        @test report.ok

        write(patch, "changed patch\n")
        report = verify_stage_b_evidence(
            schema,
            ordinary,
            difficult,
            receipt,
            comparison,
        )
        @test !report.ok
        @test "instrumentation patch SHA-256 is inconsistent" in report.issues

        comparison_data = TOML.parsefile(comparison)
        comparison_data["failed_files"] = 1
        open(comparison, "w") do io
            TOML.print(io, comparison_data; sorted = true)
        end
        report = verify_stage_b_evidence(
            schema,
            ordinary,
            difficult,
            receipt,
            comparison,
        )
        @test !report.ok
        @test "instrumented ordinary output does not match pristine output" in
              report.issues
    end
end
