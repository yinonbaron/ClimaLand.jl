using Test
import TOML

include("seal_raw_snapshot.jl")

function seal_arguments(directory)
    return (
        transition = "ordinary",
        time_start = "1999-12-31",
        time_end = "2000-01-01",
        source_commit = repeat("a", 40),
        source_sha256 = repeat("b", 64),
        patch_sha256 = repeat("c", 64),
        executable_sha256 = repeat("d", 64),
        job_options_sha256 = repeat("e", 64),
        model_parameters_sha256 = repeat("f", 64),
        initialization_sha256 = repeat("0", 64),
    )
end

@testset "raw snapshot sealer records exact dtype, shape, units, and provenance" begin
    mktempdir() do directory
        raw = joinpath(directory, "ordinary.raw")
        mkpath(raw)
        open(joinpath(raw, "static.delzw.bin"), "w") do io
            write(io, Float64[0.1, 0.2])
        end
        write(joinpath(raw, "static.delzw.shape"), "1 2\n")
        open(joinpath(raw, "static.zbot.bin"), "w") do io
            write(io, Float64[0.1, 0.2])
        end
        write(joinpath(raw, "static.zbot.shape"), "2\n")
        manifest = seal_raw_snapshot(raw; seal_arguments(raw)...)
        delzw = only(
            field for
            field in manifest["field"] if field["name"] == "static.delzw"
        )
        zbot = only(
            field for
            field in manifest["field"] if field["name"] == "static.zbot"
        )
        @test delzw["dtype"] == "float64"
        @test delzw["shape"] == [1, 2]
        @test delzw["units"] == "m"
        @test zbot["shape"] == [2]
        @test zbot["units"] == "m"
        @test manifest["snapshot"]["deltat_days"] == 1
        @test_throws ErrorException seal_raw_snapshot(
            raw;
            seal_arguments(raw)...,
        )
    end
end

@testset "raw snapshot sealer rejects an unshaped payload" begin
    mktempdir() do directory
        raw = joinpath(directory, "raw")
        mkpath(raw)
        write(joinpath(raw, "forcing.tbar.bin"), zeros(UInt8, 8))
        @test_throws ErrorException seal_raw_snapshot(
            raw;
            seal_arguments(raw)...,
        )
    end
end
