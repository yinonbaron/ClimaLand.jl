using Test
using TOML

include("snapshots.jl")
include("schema.jl")
include("evidence_gate.jl")
using .StageBSnapshots
using .StageBSnapshotEvidence

@testset "snapshot and receipt paths cannot escape their directories" begin
    mktempdir() do directory
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
        manifest_path = joinpath(snapshot, "manifest.toml")
        manifest = TOML.parsefile(manifest_path)
        only(manifest["field"])["path"] = "../outside.bin"
        open(manifest_path, "w") do io
            TOML.print(io, manifest; sorted = true)
        end
        report = verify_snapshot(snapshot)
        @test !report.ok
        @test "pre.litrmass payload escapes snapshot directory" in report.issues

        receipt = joinpath(directory, "receipt", "instrumentation_receipt.toml")
        mkpath(dirname(receipt))
        outside_patch = joinpath(directory, "outside.patch")
        write(outside_patch, "outside\n")
        open(receipt, "w") do io
            TOML.print(
                io,
                Dict(
                    "schema_version" => 1,
                    "status" => "complete",
                    "source_sha256" => repeat("a", 64),
                    "patch_path" => "../outside.patch",
                    "patch_sha256" => sha256sum(outside_patch),
                );
                sorted = true,
            )
        end
        evidence = verify_stage_b_evidence(
            joinpath(directory, "missing-schema.toml"),
            joinpath(directory, "missing-ordinary"),
            joinpath(directory, "missing-difficult"),
            receipt,
            joinpath(directory, "missing-comparison.toml"),
        )
        @test !evidence.ok
        @test "instrumentation patch SHA-256 is inconsistent" in evidence.issues
    end
end
