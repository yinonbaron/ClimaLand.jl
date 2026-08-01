module TestbedPinnedCORPSEAdapterTests

using Test
import SHA
import Tar
import TOML

include(joinpath(@__DIR__, "pinned_corpse_adapter.jl"))
const PinnedCORPSE = TestbedPinnedCORPSEAdapter

const VALID_TEST_SHA256 = repeat("a", 64)
const REVIEWED_GAPS = [
    Dict("model" => "CORPSE", "cell_id" => id, "reviewed" => true) for
    id in (51, 3442)
]

sha256sum(path) = bytes2hex(SHA.sha256(read(path)))

function write_toml(path, document)
    open(path, "w") do io
        TOML.print(io, document; sorted = true)
    end
    return path
end

function write_bundle(root, kind, scope_sha256; model = nothing)
    mkpath(root)
    payload = if kind == "forcing"
        Dict("fixture_manifest" => "fixture.toml")
    else
        Dict(
            "boundaries" => "boundaries.tar",
            "boundaries_manifest" => "boundaries.toml",
            "reduced_history" => "reduced_history.nc",
            "reduced_history_manifest" => "reduced_history.toml",
        )
    end
    if kind == "forcing"
        fixture = Dict(
            "schema_version" => 1,
            "selection" => Dict(
                "scope_manifest_sha256" => scope_sha256,
                "representative_cell_ids" => collect(1:80),
            ),
        )
        write_toml(joinpath(root, payload["fixture_manifest"]), fixture)
    else
        boundary_root = joinpath(root, "boundary_source")
        mkpath(boundary_root)
        members = Dict{String, String}()
        paths = ["reconstruction_report.toml"]
        for directory in values(PinnedCORPSE.CORPSE_STAGES),
            name in PinnedCORPSE.BOUNDARY_MEMBER_NAMES

            push!(paths, "stages/$directory/$name")
        end
        for relative in paths
            path = joinpath(boundary_root, relative)
            mkpath(dirname(path))
            write(path, relative)
            members[relative] = sha256sum(path)
        end
        Tar.create(boundary_root, joinpath(root, payload["boundaries"]))
        write_toml(
            joinpath(root, payload["boundaries_manifest"]),
            Dict(
                "schema_version" => 1,
                "schema" => "corpse-boundary-archive-v1",
                "model" => "CORPSE",
                "scope" => "representative",
                "scope_cell_count" => 80,
                "eligible_cell_count" => 78,
                "archive_format" => "tar",
                "stage" => PinnedCORPSE.CORPSE_STAGES,
                "members" => members,
            ),
        )
        rm(boundary_root; recursive = true)
        reduced_path = joinpath(root, payload["reduced_history"])
        write(reduced_path, "reduced history")
        write_toml(
            joinpath(root, payload["reduced_history_manifest"]),
            Dict(
                "schema_version" => 1,
                "reference_id" => "corpse-c-representative-fortran-reduced-v1",
                "scope" => "representative",
                "scope_cell_count" => 80,
                "eligible_cell_count" => 78,
                "reducers" => Dict(
                    reducer => reducer for reducer in PinnedCORPSE.REDUCERS
                ),
                "artifact" => Dict(
                    "sha256" => sha256sum(reduced_path),
                    "bytes" => filesize(reduced_path),
                ),
            ),
        )
    end
    files = Dict(
        path => sha256sum(joinpath(root, path)) for path in values(payload)
    )
    provenance = Dict(
        "scope_manifest_sha256" => scope_sha256,
        "forcing_sha256" => Dict("forcing.nc" => VALID_TEST_SHA256),
        "shared_parameter_sha256" =>
            Dict("shared.toml" => VALID_TEST_SHA256),
        "comparison_schema" => "reduced-comparison-oracle-v1",
    )
    manifest = Dict{String, Any}(
        "schema_version" => 1,
        "kind" => kind,
        "scope" => "representative",
        "files" => files,
        "payload" => payload,
        "provenance" => provenance,
    )
    isnothing(model) || (manifest["model"] = model)
    write_toml(joinpath(root, "manifest.toml"), manifest)
    return root
end

function make_inputs(root)
    scope = joinpath(root, "representative.toml")
    write_toml(
        scope,
        Dict(
            "schema_version" => 1,
            "name" => "representative",
            "cell_ids" => collect(1:80),
        ),
    )
    scope_sha256 = sha256sum(scope)
    forcing = write_bundle(joinpath(root, "forcing"), "forcing", scope_sha256)
    reference = write_bundle(
        joinpath(root, "reference"),
        "reference",
        scope_sha256;
        model = "CORPSE",
    )
    return (; scope, forcing, reference)
end

@testset "Pinned CORPSE adapter verifies bundle roles before execution" begin
    mktempdir() do root
        inputs = make_inputs(root)
        output = joinpath(root, "output")
        called = Ref(false)
        executor = function (
            output_root;
            bundle,
            boundary_root,
            fixture_manifest,
            scope_manifest,
            workers,
        )
            called[] = true
            @test output_root == output
            @test fixture_manifest == joinpath(inputs.forcing, "fixture.toml")
            @test scope_manifest == inputs.scope
            @test bundle.boundaries ==
                  joinpath(inputs.reference, "boundaries.tar")
            @test bundle.boundaries_manifest ==
                  joinpath(inputs.reference, "boundaries.toml")
            @test bundle.reduced_history ==
                  joinpath(inputs.reference, "reduced_history.nc")
            @test bundle.reduced_history_manifest ==
                  joinpath(inputs.reference, "reduced_history.toml")
            @test read(
                joinpath(boundary_root, "reconstruction_report.toml"),
                String,
            ) == "reconstruction_report.toml"
            @test workers == 2
            mkpath(output_root)
            report = write_toml(
                joinpath(output_root, "report.toml"),
                Dict("outcome" => "passed"),
            )
            return (;
                passed = true,
                report,
                seconds = 1.0,
                coverage = Dict(
                    "scope_cells" => 80,
                    "eligible_cells" => 78,
                    "compared_cells" => 78,
                    "eligibility_gaps" => REVIEWED_GAPS,
                ),
            )
        end

        result = PinnedCORPSE.run_pinned_corpse(
            output;
            scope_manifest = inputs.scope,
            forcing_artifact_root = inputs.forcing,
            reference_artifact_root = inputs.reference,
            workers = 2,
            executor,
        )

        @test called[]
        @test result.passed
        @test result.coverage["compared_cells"] == 78
    end
end

@testset "Pinned CORPSE adapter fails closed" begin
    mktempdir() do root
        inputs = make_inputs(root)
        manifest_path = joinpath(inputs.reference, "manifest.toml")
        manifest = TOML.parsefile(manifest_path)
        delete!(manifest["payload"], "reduced_history")
        write_toml(manifest_path, manifest)
        @test_throws PinnedCORPSE.AdapterError PinnedCORPSE.run_pinned_corpse(
            joinpath(root, "output");
            scope_manifest = inputs.scope,
            forcing_artifact_root = inputs.forcing,
            reference_artifact_root = inputs.reference,
            executor = _ -> error("must not execute"),
        )
    end

    mktempdir() do root
        inputs = make_inputs(root)
        write(joinpath(inputs.reference, "boundaries.tar"), "changed")
        @test_throws PinnedCORPSE.AdapterError PinnedCORPSE.pinned_corpse_bundle(
            inputs.reference,
        )
    end

    mktempdir() do root
        inputs = make_inputs(root)
        manifest_path = joinpath(inputs.reference, "manifest.toml")
        manifest = TOML.parsefile(manifest_path)
        manifest["payload"]["boundaries"] = "../boundaries.nc"
        manifest["files"]["../boundaries.nc"] = VALID_TEST_SHA256
        write_toml(manifest_path, manifest)
        @test_throws PinnedCORPSE.AdapterError PinnedCORPSE.pinned_corpse_bundle(
            inputs.reference,
        )
    end

    mktempdir() do root
        inputs = make_inputs(root)
        @test_throws PinnedCORPSE.AdapterError PinnedCORPSE.run_pinned_corpse(
            joinpath(root, "output");
            scope_manifest = inputs.scope,
            forcing_artifact_root = inputs.forcing,
            reference_artifact_root = inputs.reference,
        )
    end
end

@testset "Pinned CORPSE adapter rejects mixed compatibility sets" begin
    mktempdir() do root
        inputs = make_inputs(root)
        manifest_path = joinpath(inputs.reference, "manifest.toml")
        manifest = TOML.parsefile(manifest_path)
        manifest["provenance"]["comparison_schema"] = "other-schema"
        write_toml(manifest_path, manifest)

        @test_throws PinnedCORPSE.AdapterError PinnedCORPSE.run_pinned_corpse(
            joinpath(root, "output");
            scope_manifest = inputs.scope,
            forcing_artifact_root = inputs.forcing,
            reference_artifact_root = inputs.reference,
            executor = _ -> error("must not execute"),
        )
    end

    mktempdir() do root
        inputs = make_inputs(root)
        executor = function (output_root; kwargs...)
            mkpath(output_root)
            report = write_toml(
                joinpath(output_root, "report.toml"),
                Dict("outcome" => "passed"),
            )
            return (;
                passed = true,
                report,
                seconds = 0.0,
                coverage = Dict(
                    "scope_cells" => 80,
                    "eligible_cells" => 78,
                    "compared_cells" => 77,
                    "eligibility_gaps" => REVIEWED_GAPS,
                ),
            )
        end
        @test_throws PinnedCORPSE.AdapterError PinnedCORPSE.run_pinned_corpse(
            joinpath(root, "output");
            scope_manifest = inputs.scope,
            forcing_artifact_root = inputs.forcing,
            reference_artifact_root = inputs.reference,
            executor,
        )
    end
end

@testset "Pinned CORPSE adapter preserves scientific failure" begin
    mktempdir() do root
        inputs = make_inputs(root)
        executor = function (output_root; kwargs...)
            mkpath(output_root)
            report = write_toml(
                joinpath(output_root, "report.toml"),
                Dict("outcome" => "failed"),
            )
            return (;
                passed = false,
                report,
                seconds = 0.1,
                coverage = Dict(
                    "scope_cells" => 80,
                    "eligible_cells" => 78,
                    "compared_cells" => 78,
                    "eligibility_gaps" => REVIEWED_GAPS,
                ),
            )
        end
        result = PinnedCORPSE.run_pinned_corpse(
            joinpath(root, "output");
            scope_manifest = inputs.scope,
            forcing_artifact_root = inputs.forcing,
            reference_artifact_root = inputs.reference,
            executor,
        )
        @test !result.passed
        @test TOML.parsefile(result.report)["outcome"] == "failed"
    end
end

end
