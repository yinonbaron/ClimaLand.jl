@testset "synthetic bundles cannot satisfy replay acceptance" begin
    schema_path = joinpath(@__DIR__, "schema.toml")
    mktempdir() do directory
        bundle_path = joinpath(directory, "bundle")
        write_synthetic_bundle(bundle_path, schema_path)

        report = verify_replay_acceptance(bundle_path, schema_path)
        @test !report.ok
        @test any(
            issue -> occursin("evidence_status is not complete", issue),
            report.issues,
        )

        rewrite_manifest(bundle_path) do manifest
            manifest["trajectory"]["evidence_status"] = "complete"
        end
        report = verify_replay_acceptance(bundle_path, schema_path)
        @test !report.ok
        @test any(
            issue -> occursin("real issue-#101 evidence", issue),
            report.issues,
        )
        @test isnothing(report.replay)
    end
end
