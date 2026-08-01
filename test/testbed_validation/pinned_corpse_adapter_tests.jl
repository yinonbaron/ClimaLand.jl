module TestbedPinnedCORPSEAdapterTests

using Test
import SHA
import TOML

include(joinpath(@__DIR__, "pinned_corpse_adapter.jl"))
const PinnedCORPSE = TestbedPinnedCORPSEAdapter

const VALID_TEST_SHA256 = repeat("a", 64)

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
            "boundaries" => "boundaries.nc",
            "boundaries_manifest" => "boundaries.toml",
            "reduced_history" => "reduced_history.nc",
            "reduced_history_manifest" => "reduced_history.toml",
        )
    end
    for path in values(payload)
        if endswith(path, ".toml")
            write_toml(joinpath(root, path), Dict("schema_version" => 1))
        else
            write(joinpath(root, path), path)
        end
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
        executor = function (output_root; bundle, fixture_manifest, scope_manifest, workers)
            called[] = true
            @test output_root == output
            @test fixture_manifest == joinpath(inputs.forcing, "fixture.toml")
            @test scope_manifest == inputs.scope
            @test bundle.boundaries == joinpath(inputs.reference, "boundaries.nc")
            @test bundle.boundaries_manifest ==
                  joinpath(inputs.reference, "boundaries.toml")
            @test bundle.reduced_history ==
                  joinpath(inputs.reference, "reduced_history.nc")
            @test bundle.reduced_history_manifest ==
                  joinpath(inputs.reference, "reduced_history.toml")
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
                    "eligibility_gaps" => [Dict(), Dict()],
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
        write(joinpath(inputs.reference, "boundaries.nc"), "changed")
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
                    "eligibility_gaps" => [Dict(), Dict()],
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

end
