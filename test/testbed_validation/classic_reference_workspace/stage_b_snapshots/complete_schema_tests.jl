using Test

include("write_canonical_schema.jl")
include("schema.jl")
using .StageBSnapshotSchema

@testset "canonical schema declares exact Stage B contract" begin
    mktempdir() do directory
        path = write_canonical_schema(joinpath(directory, "schema.toml"))
        schema = load_schema(path)
        @test length(schema["field"]) == 66
        @test schema["dimensions"] == Dict(
            "tile" => 1,
            "pft" => 12,
            "pft_and_bare" => 13,
            "soil_layer" => 20,
            "parameter_class" => 15,
            "q10_parameter" => 4,
            "scalar" => 1,
        )
        zbot = only(
            field for
            field in schema["field"] if field["name"] == "static.zbot"
        )
        @test zbot["shape"] == [20]
        @test zbot["dimensions"] == ["soil_layer"]
        @test all(
            field["dtype"] in ("float64", "int32") for field in schema["field"]
        )
        @test all(
            field["shape"] ==
            [schema["dimensions"][label] for label in field["dimensions"]] for
            field in schema["field"]
        )
        @test "time_start" in schema["required_snapshot_metadata"]
        @test "executable_sha256" in schema["required_snapshot_metadata"]
        @test only(
            field for
            field in schema["field"] if field["name"] == "static.deltat"
        )["units"] == "d"
        @test only(
            field for
            field in schema["field"] if field["name"] == "post.soilcmas"
        )["role"] == "reference_state"
    end
end
