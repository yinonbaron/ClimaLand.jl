using Test
using TOML

include("policy_inventory.jl")
using .ClassicSitePolicyInventory:
    CLASSIC_BENCHMARK_SITES, validate_policy_inventory

const INVENTORY_PATH = joinpath(@__DIR__, "site_policy_inventory.toml")

@testset "site policy inventory covers the released campaign exactly" begin
    report = validate_policy_inventory(INVENTORY_PATH)
    inventory = TOML.parsefile(INVENTORY_PATH)
    sites = getindex.(inventory["site"], "name")

    @test report.site_count == 59
    @test report.site_count == length(CLASSIC_BENCHMARK_SITES)
    @test sites == collect(CLASSIC_BENCHMARK_SITES)
    @test length(sites) == length(unique(sites))
    @test report.source_category_counts == Dict(
        "ameriflux" => 21,
        "fluxnet" => 37,
        "provider" => 1,
        "unknown" => 0,
    )
end

@testset "site policy inventory fails closed" begin
    inventory = TOML.parsefile(INVENTORY_PATH)

    @test all(
        site["redistribution_status"] == "blocked" for site in inventory["site"]
    )
    @test all(!isempty(site["unresolved_reason"]) for site in inventory["site"])
    @test inventory["artifact_policy"]["site_inputs"] == "external_only"
    @test inventory["artifact_policy"]["derived_tapes"] == "external_only"
    @test inventory["artifact_policy"]["trajectory_bundles"] == "external_only"

    mktempdir() do root
        incomplete_path = joinpath(root, "incomplete.toml")
        incomplete = deepcopy(inventory)
        pop!(incomplete["site"])
        open(incomplete_path, "w") do io
            TOML.print(io, incomplete)
        end
        @test_throws ArgumentError validate_policy_inventory(incomplete_path)

        unsafe_path = joinpath(root, "unsafe.toml")
        unsafe = deepcopy(inventory)
        unsafe["site"][1]["redistribution_status"] = "approved"
        open(unsafe_path, "w") do io
            TOML.print(io, unsafe)
        end
        @test_throws ArgumentError validate_policy_inventory(unsafe_path)

        unknown_path = joinpath(root, "unknown.toml")
        unknown = deepcopy(inventory)
        unknown["site"][1]["policy_status"] = "unknown"
        unknown["site"][1]["unresolved_reason"] = ""
        open(unknown_path, "w") do io
            TOML.print(io, unknown)
        end
        @test_throws ArgumentError validate_policy_inventory(unknown_path)
    end
end

@testset "restricted artifacts are not tracked in the reference workspace" begin
    tracked = readchomp(`git -C $(joinpath(@__DIR__, "../../../..")) ls-files`)
    tracked_paths = split(tracked, '\n'; keepempty = false)
    restricted_suffixes = (
        ".nc",
        ".nc4",
        ".csv",
        ".bin",
        ".h5",
        ".hdf5",
        ".npy",
        ".jld",
        ".jld2",
        ".tar",
        ".tar.gz",
        ".zip",
    )
    restricted = filter(tracked_paths) do path
        normalized = lowercase(path)
        startswith(
            normalized,
            "test/testbed_validation/classic_reference_workspace/",
        ) && (
            any(
                endswith(normalized, suffix) for suffix in restricted_suffixes
            ) || occursin(".zarr/", normalized)
        )
    end
    @test isempty(restricted)
end
