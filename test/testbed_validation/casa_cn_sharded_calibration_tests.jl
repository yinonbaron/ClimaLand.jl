using Test

include("casa_cn_sharded_calibration.jl")

const CASA_CN_SHARDS = TestbedCASACNShardedCalibration

@testset "CASA-CN calibration shards cover the full grid exactly" begin
    ranges = CASA_CN_SHARDS.shard_ranges(4_263, 6)
    @test length(ranges) == 6
    @test first(first(ranges)) == 1
    @test last(last(ranges)) == 4_263
    @test reduce(vcat, collect.(ranges)) == collect(1:4_263)
    @test maximum(length.(ranges)) - minimum(length.(ranges)) == 1

    @test_throws ArgumentError CASA_CN_SHARDS.shard_ranges(0, 1)
    @test_throws ArgumentError CASA_CN_SHARDS.shard_ranges(10, 0)
    @test_throws ArgumentError CASA_CN_SHARDS.shard_ranges(3, 4)
end

@testset "CASA-CN shard aggregation preserves global grid order" begin
    shards = [
        (; first_grid_index = 1, last_grid_index = 2),
        (; first_grid_index = 3, last_grid_index = 5),
    ]
    values =
        Dict(1 => [1.0 11.0; 2.0 12.0], 3 => [3.0 13.0; 4.0 14.0; 5.0 15.0])
    combined = CASA_CN_SHARDS.combine_shards(shards, 5) do shard
        values[shard.first_grid_index]
    end
    @test combined == [
        1.0 11.0
        2.0 12.0
        3.0 13.0
        4.0 14.0
        5.0 15.0
    ]
    @test CASA_CN_SHARDS.combine_shards(shards, 5) do shard
        collect(Float64, (shard.first_grid_index):(shard.last_grid_index))
    end == collect(1.0:5.0)

    overlapping = [
        (; first_grid_index = 1, last_grid_index = 3),
        (; first_grid_index = 3, last_grid_index = 5),
    ]
    @test_throws ErrorException CASA_CN_SHARDS.combine_shards(
        overlapping,
        5,
    ) do shard
        zeros(shard.last_grid_index - shard.first_grid_index + 1, 1)
    end

    @test_throws ErrorException CASA_CN_SHARDS.combine_shards(
        [first(shards)],
        5,
    ) do shard
        zeros(shard.last_grid_index - shard.first_grid_index + 1)
    end
end

@testset "CASA-CN calibration commands obey their hard deadline" begin
    command = `$(Base.julia_cmd()) --startup-file=no -e 'sleep(10)'`
    result = CASA_CN_SHARDS.run_until(
        command,
        time() + 0.05;
        command_stdout = devnull,
        command_stderr = devnull,
    )
    @test result.timed_out
    @test result.exitcode == 124
end

@testset "CASA-CN invalid shards are preserved before replacement" begin
    mktempdir() do root
        invalid = joinpath(root, "shard-001")
        mkpath(invalid)
        write(joinpath(invalid, "partial.txt"), "recoverable")
        shards = [
            (; output_root = invalid),
            (; output_root = joinpath(root, "shard-002")),
        ]
        quarantined = CASA_CN_SHARDS.quarantine_invalid_shards(shards)
        @test length(quarantined) == 1
        @test !ispath(invalid)
        @test read(joinpath(only(quarantined), "partial.txt"), String) ==
              "recoverable"
    end
end

@testset "CASA-CN shard identity resolves every declared forcing file" begin
    mktempdir() do root
        forcing_root = joinpath(root, "forcing")
        reference_root = joinpath(root, "reference")
        metadata_root = joinpath(reference_root, "stages", "04-historical")
        mkpath(forcing_root)
        mkpath(metadata_root)
        names = ["met_$(year)_$(year).nc" for year in 1901:2014]
        metadata = Dict(
            "inputs" =>
                [Dict("destination" => name) for name in reverse(names)],
        )
        open(joinpath(metadata_root, "stage_metadata.toml"), "w") do io
            CASA_CN_SHARDS.TOML.print(io, metadata; sorted = true)
        end
        @test CASA_CN_SHARDS.forcing_paths(forcing_root, reference_root) ==
              joinpath.(forcing_root, names)
    end
end
