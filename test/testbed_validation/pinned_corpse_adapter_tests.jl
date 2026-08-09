module TestbedPinnedCORPSEAdapterTests

using Test
import NCDatasets
import SHA
import Tar
import TOML

include(joinpath(@__DIR__, "pinned_corpse_adapter.jl"))
const PinnedCORPSE = TestbedPinnedCORPSEAdapter

const VALID_TEST_SHA256 = repeat("a", 64)
const REVIEWED_GAPS = [
    Dict("model" => "CORPSE", "cell_id" => id, "reviewed" => true) for
    id in (51, 52)
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
            if relative == "reconstruction_report.toml"
                write_toml(
                    path,
                    Dict(
                        "schema_version" => 1,
                        "status" => "complete",
                        "points" => 80,
                        "source_commit" => PinnedCORPSE.FORTRAN_SOURCE_COMMIT,
                    ),
                )
            elseif basename(relative) == "grid.csv"
                write(path, "ijcam,ivt_igbp\n1,1\n")
            elseif basename(relative) == "stage_metadata.toml"
                stage = only(
                    name for
                    (name, directory) in PinnedCORPSE.CORPSE_STAGES if
                    occursin("stages/$directory/", relative)
                )
                write_toml(
                    path,
                    Dict(
                        "schema_version" => 1,
                        "name" => stage,
                        "status" => "complete",
                        "elapsed_seconds" => 9876.5,
                        "control" => Dict(
                            "source" => "/different/generated/run/$stage.lst",
                        ),
                        "inputs" => [
                            Dict("source" => "/different/generated/input.csv"),
                        ],
                        "outputs" => Dict(
                            name =>
                                Dict("bytes" => 1, "md5" => "different") for
                            name in ("casa_final.csv", "corpse_final.csv")
                        ),
                    ),
                )
            else
                write(path, relative)
            end
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
            "eligibility_gaps" => REVIEWED_GAPS,
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

function reduced_test_calibration()
    native = PinnedCORPSEExecutor.native_corpse()
    return Dict(
        "reducer" => Dict(
            reducer => Dict(
                description.name => Dict(
                    "finite_pair_count" => 78 * sample_count,
                    "units" => native.reduced_units(description, reducer),
                    "derived_policy" => Dict(
                        "atol" => 0.0,
                        "rtol" => 0.0,
                        "validation_failed_pairs" => 0,
                    ),
                ) for description in variables
            ) for (reducer, variables, sample_count) in (
                ("annual_mean", native.REDUCED_STATE_VARIABLES, 114),
                ("end_of_year", native.REDUCED_STATE_VARIABLES, 114),
                ("annual_total", native.REDUCED_FLUX_VARIABLES, 114),
                (
                    "fixed_daily_sample",
                    native.REDUCED_VARIABLES,
                    length(native.REDUCED_SAMPLE_DAYS),
                ),
            )
        ),
    )
end

function write_reduced_test_file(
    path,
    ids;
    eligible = trues(length(ids)),
    deflatelevel = 0,
)
    native = PinnedCORPSEExecutor.native_corpse()
    NCDatasets.NCDataset(path, "c"; format = :netcdf4) do output
        NCDatasets.defDim(output, "point", length(ids))
        NCDatasets.defDim(output, "year", 114)
        NCDatasets.defDim(output, "sample", length(native.REDUCED_SAMPLE_DAYS))
        NCDatasets.defVar(output, "cell_id", Int, ("point",))[:] = ids
        NCDatasets.defVar(output, "eligible", Int8, ("point",))[:] =
            Int8.(eligible)
        NCDatasets.defVar(output, "year", Int, ("year",))[:] = 1901:2014
        NCDatasets.defVar(output, "sample_day", Int, ("sample",))[:] =
            native.REDUCED_SAMPLE_DAYS
        for (reducer, variables, sample_count) in (
            ("annual_mean", native.REDUCED_STATE_VARIABLES, 114),
            ("end_of_year", native.REDUCED_STATE_VARIABLES, 114),
            ("annual_total", native.REDUCED_FLUX_VARIABLES, 114),
            (
                "fixed_daily_sample",
                native.REDUCED_VARIABLES,
                length(native.REDUCED_SAMPLE_DAYS),
            ),
        )
            values = repeat(Float64.(ids), 1, sample_count)
            dimension = reducer == "fixed_daily_sample" ? "sample" : "year"
            for description in variables
                NCDatasets.defVar(
                    output,
                    "$(reducer)__$(description.name)",
                    Float64,
                    ("point", dimension);
                    deflatelevel,
                    shuffle = deflatelevel > 0,
                )[
                    :,
                    :,
                ] = values
            end
        end
    end
    return path
end

@testset "Pinned CORPSE separates scientific hashes from regenerated metadata" begin
    mktempdir() do root
        inputs = make_inputs(root)
        bundle = PinnedCORPSE.pinned_corpse_bundle(inputs.reference)
        PinnedCORPSE.materialize_boundaries(bundle) do boundary_root
            stages = Dict{String, Any}()
            for (name, directory) in PinnedCORPSE.CORPSE_STAGES
                stages[name] = Dict(
                    key => Dict(
                        "id" => "fortran/$directory/$filename",
                        "sha256" => sha256sum(
                            joinpath(
                                boundary_root,
                                "stages",
                                directory,
                                filename,
                            ),
                        ),
                    ) for (key, filename) in (
                        "casa_boundary" => "casa_final.csv",
                        "corpse_boundary" => "corpse_final.csv",
                    )
                )
            end
            calibration = Dict("provenance" => Dict("fortran_stage" => stages))
            @test isnothing(
                PinnedCORPSE.verify_calibrated_boundaries(
                    calibration,
                    boundary_root,
                ),
            )
            @test isnothing(
                PinnedCORPSE.validate_boundary_documents(boundary_root, 80),
            )
            write(
                joinpath(
                    boundary_root,
                    "stages",
                    PinnedCORPSE.CORPSE_STAGES["historical"],
                    "corpse_final.csv",
                ),
                "scientifically changed",
            )
            @test_throws PinnedCORPSE.AdapterError PinnedCORPSE.verify_calibrated_boundaries(
                calibration,
                boundary_root,
            )
        end
    end
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
            @test TOML.parsefile(
                joinpath(boundary_root, "reconstruction_report.toml"),
            )["status"] == "complete"
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

@testset "Pinned CORPSE adapter executes one assigned cell shard" begin
    mktempdir() do root
        inputs = make_inputs(root)
        assigned = collect(1:8:80)
        executor = function (output_root; cell_ids, kwargs...)
            @test cell_ids == assigned
            mkpath(output_root)
            report = write_toml(
                joinpath(output_root, "report.toml"),
                Dict("outcome" => "passed"),
            )
            return (;
                passed = true,
                report,
                seconds = 0.1,
                coverage = Dict(
                    "scope_cells" => 10,
                    "eligible_cells" => 10,
                    "compared_cells" => 10,
                    "eligibility_gaps" => Dict{String, Any}[],
                ),
            )
        end

        result = PinnedCORPSE.run_pinned_corpse(
            joinpath(root, "output");
            scope_manifest = inputs.scope,
            forcing_artifact_root = inputs.forcing,
            reference_artifact_root = inputs.reference,
            cell_ids = assigned,
            executor,
        )

        @test result.passed
        @test result.coverage["scope_cells"] == 10
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

    mktempdir() do root
        inputs = make_inputs(root)
        executor = function (output_root; kwargs...)
            mkpath(output_root)
            report = write_toml(
                joinpath(output_root, "report.toml"),
                Dict("outcome" => "passed"),
            )
            extra_gap = Dict(
                "model" => "OTHER",
                "cell_id" => 99,
                "reviewed" => false,
            )
            return (;
                passed = true,
                report,
                seconds = 0.0,
                coverage = Dict(
                    "scope_cells" => 80,
                    "eligible_cells" => 78,
                    "compared_cells" => 78,
                    "eligibility_gaps" => [REVIEWED_GAPS; extra_gap],
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

@testset "Pinned CORPSE preflight validates the complete compatibility set" begin
    mktempdir() do root
        inputs = make_inputs(root)
        verified = PinnedCORPSE.preflight_inputs(
            inputs.scope,
            inputs.forcing,
            inputs.reference,
        )
        @test verified.scope.cell_ids == collect(1:80)

        manifest_path = joinpath(inputs.reference, "manifest.toml")
        manifest = TOML.parsefile(manifest_path)
        manifest["provenance"]["comparison_schema"] = "other-schema"
        write_toml(manifest_path, manifest)
        @test_throws PinnedCORPSE.AdapterError PinnedCORPSE.preflight_inputs(
            inputs.scope,
            inputs.forcing,
            inputs.reference,
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

include(joinpath(@__DIR__, "pinned_corpse_executor.jl"))
const PinnedCORPSEExecutor = TestbedPinnedCORPSEExecutor

@testset "Pinned CORPSE reduced shards map full-oracle rows by cell ID" begin
    mktempdir() do root
        mask = trues(80)
        mask[[51, 80]] .= false
        reference = write_reduced_test_file(
            joinpath(root, "reference.nc"),
            collect(1:80);
            eligible = mask,
        )
        candidate =
            write_reduced_test_file(joinpath(root, "candidate.nc"), [11, 33])
        calibration = reduced_test_calibration()
        comparison = PinnedCORPSEExecutor.compare_reduced_historical(
            candidate,
            reference,
            calibration;
            require_full_population = false,
        )
        @test PinnedCORPSEExecutor.reduced_passed(comparison)
        @test comparison["annual_mean"][first(
            keys(comparison["annual_mean"]),
        )]["values"] == 2 * 114

        for (name, ids) in ("unknown" => [11, 81], "duplicate" => [11, 11])
            invalid = write_reduced_test_file(joinpath(root, "$name.nc"), ids)
            @test_throws ErrorException PinnedCORPSEExecutor.compare_reduced_historical(
                invalid,
                reference,
                calibration;
                require_full_population = false,
            )
        end
    end
end

@testset "Pinned CORPSE compares compressed reduced shards directly" begin
    mktempdir() do root
        mask = trues(80)
        mask[[51, 80]] .= false
        reference = write_reduced_test_file(
            joinpath(root, "reference.nc"),
            collect(1:80);
            eligible = mask,
            deflatelevel = 3,
        )
        candidate = write_reduced_test_file(
            joinpath(root, "candidate.nc"),
            [11, 33];
            deflatelevel = 1,
        )
        calibration = reduced_test_calibration()

        comparison = PinnedCORPSEExecutor.compare_reduced_historical(
            candidate,
            reference,
            calibration;
            require_full_population = false,
        )
        @test PinnedCORPSEExecutor.reduced_passed(comparison)

        native = PinnedCORPSEExecutor.native_corpse()
        variable = "annual_mean__$(first(native.REDUCED_STATE_VARIABLES).name)"
        NCDatasets.NCDataset(candidate, "a") do output
            output[variable][1, 1] += 1
        end
        @test_throws ErrorException PinnedCORPSEExecutor.compare_reduced_historical(
            candidate,
            reference,
            calibration;
            require_full_population = false,
        )
    end
end
end
