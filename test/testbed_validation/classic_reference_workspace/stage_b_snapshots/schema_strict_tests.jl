using Test
import TOML

include("snapshots.jl")
include("schema.jl")
using .StageBSnapshots
using .StageBSnapshotSchema

@testset "schema loader requires dtype, shape, and exact dimensions" begin
    mktempdir() do directory
        schema_path = joinpath(directory, "schema.toml")
        write(
            schema_path,
            """
            schema_version = 1
            scope = "synthetic"
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
            dimensions = ["tile"]
            shape = [1]
            """,
        )
        @test_throws ArgumentError load_schema(schema_path)

        schema = TOML.parsefile(schema_path)
        schema["field"][1]["dtype"] = "float64"
        schema["field"][1]["shape"] = [2]
        open(schema_path, "w") do io
            TOML.print(io, schema; sorted = true)
        end
        @test_throws ArgumentError load_schema(schema_path)
    end
end

@testset "schema verifier rejects dtype and exact-extent mismatches" begin
    mktempdir() do directory
        schema_path = joinpath(directory, "schema.toml")
        write(
            schema_path,
            """
            schema_version = 1
            scope = "synthetic"
            site = "DE-Hai"
            storage_order = "fortran_column_major"
            endianness = "little"

            [dimensions]
            tile = 1
            soil_layer = 2

            [[field]]
            name = "pre.litrmass"
            phase = "pre_state"
            role = "owned_state"
            units = "kg C m-2"
            dtype = "float64"
            dimensions = ["tile", "soil_layer"]
            shape = [1, 2]
            """,
        )
        snapshot = joinpath(directory, "snapshot")
        write_snapshot(
            snapshot,
            [
                snapshot_field(
                    "pre.litrmass",
                    :pre_state,
                    :owned_state,
                    "kg C m-2",
                    reshape(Float32[1], 1, 1),
                ),
            ];
            transition = "ordinary",
            site = "DE-Hai",
            source_sha256 = repeat("a", 64),
            patch_sha256 = repeat("b", 64),
        )
        report = verify_against_schema(snapshot, schema_path)
        @test !report.ok
        @test "pre.litrmass dtype does not match schema" in report.issues
        @test "pre.litrmass shape does not match schema" in report.issues
    end
end
