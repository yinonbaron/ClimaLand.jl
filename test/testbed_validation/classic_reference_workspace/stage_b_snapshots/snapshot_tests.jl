using Test
using TOML

include("snapshots.jl")
using .StageBSnapshots

const HEX_A = repeat("a", 64)
const HEX_B = repeat("b", 64)

function representative_fields()
    return [
        snapshot_field(
            "pre.litrmass",
            :pre_state,
            :owned_state,
            "kg C m-2",
            reshape(Float32[1, 2, 3, 4], 1, 2, 2),
        ),
        snapshot_field(
            "forcing.tbar",
            :forcing,
            :external_forcing,
            "K",
            reshape(Float32[273.15, 274.0], 1, 2),
        ),
        snapshot_field(
            "audit.ltresveg",
            :audit,
            :audit_diagnostic,
            "umol CO2 m-2 s-1",
            reshape(Float32[0.25, 0.5], 1, 1, 2),
        ),
        snapshot_field(
            "post.soilcmas",
            :post_state,
            :owned_state,
            "kg C m-2",
            reshape(Float32[4, 3, 2, 1], 1, 2, 2),
        ),
    ]
end

@testset "Stage B snapshot round trip preserves exact bits" begin
    mktempdir() do directory
        snapshot = joinpath(directory, "ordinary")
        fields = representative_fields()
        write_snapshot(
            snapshot,
            fields;
            transition = "ordinary",
            site = "DE-Hai",
            source_sha256 = HEX_A,
            patch_sha256 = HEX_B,
        )

        report = verify_snapshot(snapshot)
        @test report.ok
        @test report.transition == "ordinary"
        @test report.site == "DE-Hai"
        @test reinterpret(UInt32, vec(read_field(snapshot, "pre.litrmass"))) ==
              reinterpret(UInt32, vec(first(fields).values))
        @test size(read_field(snapshot, "forcing.tbar")) == (1, 2)
    end
end

@testset "Stage B snapshot validation fails closed" begin
    mktempdir() do directory
        snapshot = joinpath(directory, "difficult")
        write_snapshot(
            snapshot,
            representative_fields();
            transition = "frozen_soil",
            site = "DE-Hai",
            source_sha256 = HEX_A,
            patch_sha256 = HEX_B,
        )

        open(joinpath(snapshot, "fields", "forcing.tbar.bin"), "a") do io
            write(io, UInt8(0))
        end
        report = verify_snapshot(snapshot)
        @test !report.ok
        @test any(occursin("forcing.tbar", issue) for issue in report.issues)
        @test_throws ArgumentError read_field(snapshot, "forcing.tbar")

        manifest_path = joinpath(snapshot, "manifest.toml")
        manifest = TOML.parsefile(manifest_path)
        filter!(field -> field["name"] != "post.soilcmas", manifest["field"])
        open(manifest_path, "w") do io
            TOML.print(io, manifest; sorted = true)
        end
        report = verify_snapshot(snapshot)
        @test !report.ok
        @test "missing required snapshot field: post.soilcmas" in report.issues
    end
end

@testset "instrumentation anchors are deterministic and preserve pristine source" begin
    mktempdir() do directory
        pristine = joinpath(directory, "ctemDriver.F90")
        write(
            pristine,
            "before\n    call heterotrophicRespiration(args)\n" *
            "    call updatePoolsHetResp(args)\n" *
            "    call turbation(args)\nafter\n",
        )
        before = read(pristine)
        first_bundle = joinpath(directory, "first")
        second_bundle = joinpath(directory, "second")

        first_receipt = generate_instrumentation_bundle(
            pristine,
            first_bundle;
            source_commit = repeat("a", 40),
        )
        second_receipt = generate_instrumentation_bundle(
            pristine,
            second_bundle;
            source_commit = repeat("a", 40),
        )

        @test read(pristine) == before
        @test first_receipt.patch_sha256 == second_receipt.patch_sha256
        @test read(first_receipt.patch, String) ==
              read(second_receipt.patch, String)
        @test occursin(
            "stage_b_snapshot_before_heterotrophic",
            read(first_receipt.patch, String),
        )

        write(pristine, "anchor-free source\n")
        @test_throws ArgumentError generate_instrumentation_bundle(
            pristine,
            joinpath(directory, "invalid");
            source_commit = repeat("a", 40),
        )
    end
end
