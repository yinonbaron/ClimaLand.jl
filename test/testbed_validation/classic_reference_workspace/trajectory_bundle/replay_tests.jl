@testset "replay reader separates inputs from comparison evidence" begin
    schema_path = joinpath(@__DIR__, "schema.toml")
    mktempdir() do directory
        bundle_path = joinpath(directory, "bundle")
        write_synthetic_bundle(bundle_path, schema_path)

        replay = open_replay(bundle_path, schema_path)
        @test Set(keys(replay.initial_state)) ==
              Set(("initial.litrmass", "initial.soilcmas"))
        @test haskey(replay.static_data, "parameter.bsratelt")
        @test length(replay.steps) == 2
        @test all(
            startswith(name, "driver.") for
            name in keys(replay.steps[1].drivers)
        )
        @test !any(
            startswith(name, "reference.") for
            name in keys(replay.steps[1].drivers)
        )
        @test haskey(replay.steps[1].reference_state, "reference.post_litrmass")
        @test haskey(replay.steps[1].audit_diagnostics, "audit.ltresveg")
        @test eltype(replay.steps[1].drivers["driver.tbar"]) == Float64
        @test size(replay.initial_state["initial.litrmass"]) == (1, 13, 20)
        @test replay.steps[1].time_end == replay.steps[2].time_start

        rewrite_manifest(bundle_path) do manifest
            manifest["step"][2]["time_start"] = "2000-01-04T00:00:00"
        end
        @test_throws ArgumentError open_replay(bundle_path, schema_path)
    end
end
