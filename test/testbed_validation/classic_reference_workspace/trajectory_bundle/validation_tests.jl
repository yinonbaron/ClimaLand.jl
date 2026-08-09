@testset "bundle validation is strict and chronological" begin
    schema_path = joinpath(@__DIR__, "schema.toml")
    mktempdir() do directory
        valid = joinpath(directory, "valid")
        write_synthetic_bundle(valid, schema_path)
        @test validate_bundle(valid, schema_path).ok

        wrong_role = joinpath(directory, "wrong_role")
        cp(valid, wrong_role)
        rewrite_manifest(wrong_role) do manifest
            manifest["step"][1]["field"][1]["role"] = "reference_state"
        end
        @test !validate_bundle(wrong_role, schema_path).ok
        incompatible = joinpath(directory, "incompatible")
        cp(valid, incompatible)
        rewrite_manifest(incompatible) do manifest
            delete!(manifest["provenance"], "executable_sha256")
            manifest["field"][1]["units"] = "wrong"
            manifest["field"][1]["dtype"] = "float32"
            manifest["field"][1]["shape"] = [1]
            manifest["endianness"] = "big"
            manifest["dimensions"]["pft"] = 11
        end
        report = validate_bundle(incompatible, schema_path)
        @test !report.ok
        @test any(
            issue -> occursin("invalid executable_sha256", issue),
            report.issues,
        )
        @test any(
            issue -> occursin("units does not match", issue),
            report.issues,
        )
        @test any(
            issue -> occursin("dtype does not match", issue),
            report.issues,
        )
        @test any(
            issue -> occursin("shape does not match", issue),
            report.issues,
        )
        @test any(issue -> occursin("endianness", issue), report.issues)

        @test any(
            issue -> occursin("DE-Hai schema extent", issue),
            report.issues,
        )
        noncontiguous = joinpath(directory, "noncontiguous")
        cp(valid, noncontiguous)
        rewrite_manifest(noncontiguous) do manifest
            manifest["step"][2]["time_start"] = "2000-01-04T00:00:00"
            manifest["step"][2]["time_end"] = "2000-01-05T00:00:00"
        end
        report = validate_bundle(noncontiguous, schema_path)
        @test !report.ok
        @test any(issue -> occursin("not contiguous", issue), report.issues)
        symlink_escape = joinpath(directory, "symlink_escape")
        cp(valid, symlink_escape)
        manifest = TOML.parsefile(joinpath(symlink_escape, "manifest.toml"))
        relative_payload = manifest["field"][1]["path"]
        payload = joinpath(symlink_escape, relative_payload)
        outside = joinpath(directory, "outside.bin")
        cp(payload, outside)
        rm(payload)
        symlink(outside, payload)
        report = validate_bundle(symlink_escape, schema_path)
        @test !report.ok
        @test any(issue -> occursin("escapes bundle", issue), report.issues)
    end
end
