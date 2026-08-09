using Test
using TOML

include("snapshots.jl")
include("schema.jl")
using .StageBSnapshots
using .StageBSnapshotSchema

@testset "official Stage B schema has an inspectable complete transition" begin
    schema = load_schema(joinpath(@__DIR__, "schema.toml"))
    names = Set(field["name"] for field in schema["field"])
    @test length(names) == length(schema["field"])
    @test Set((
        "pre.litrmass",
        "pre.soilcmas",
        "post.litrmass",
        "post.soilcmas",
    )) ⊆ names
    @test Set((
        "audit.ltresveg",
        "audit.scresveg",
        "audit.humtrsvg",
        "intermediate.before_turbation_litrmass",
        "intermediate.before_turbation_soilcmas",
    )) ⊆ names
    @test !any(
        occursin("product", name) || occursin("iccp2", name) for name in names
    )

    post = only(
        field for field in schema["field"] if field["name"] == "post.litrmass"
    )
    @test post["role"] == "reference_state"
    humification = only(
        field for field in schema["field"] if field["name"] == "audit.humtrsvg"
    )
    @test humification["units"] == "umol CO2 m-2 s-1"
end

@testset "schema verification fails closed on incomplete snapshots" begin
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
        snapshot = joinpath(directory, "snapshot")
        write_snapshot(
            snapshot,
            [
                snapshot_field(
                    "pre.litrmass",
                    :pre_state,
                    :owned_state,
                    "kg C m-2",
                    Float32[1],
                ),
            ];
            transition = "ordinary",
            site = "DE-Hai",
            source_sha256 = repeat("a", 64),
            patch_sha256 = repeat("b", 64),
        )

        report = verify_against_schema(snapshot, schema_path)
        @test !report.ok
        @test "missing schema field: post.litrmass" in report.issues
    end
end
