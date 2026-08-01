using Test
import SHA
import TOML

include(joinpath(@__DIR__, "reference_publication.jl"))
const ReferencePublication = TestbedReferencePublication

const PUBLICATION_MODELS =
    ("CORPSE", "MIMICS-C", "MIMICS-CN", "CASA-C", "CASA-CN")
const RELEASE_URL = "https://github.com/CliMA/ClimaLand.jl/releases/download/validation-v1"
const HEX_A = repeat("a", 64)
const HEX_B = repeat("b", 64)
const HEX_C = repeat("c", 64)
const CANONICAL_TOOLCHAIN = "climaland-biogeochem-reference-linux-gfortran-v1"

sha256sum(path) = bytes2hex(SHA.sha256(read(path)))

function write_publication_manifest(path, document)
    open(path, "w") do io
        TOML.print(io, document; sorted = true)
    end
end

function provenance(;
    forcing_sha256 = HEX_B,
    canonical = true,
    compiler_identity = "GNU Fortran 14.2.0",
)
    return Dict(
        "scope_manifest_sha256" => HEX_A,
        "forcing_sha256" => Dict("forcing.nc" => forcing_sha256),
        "shared_parameter_sha256" => Dict("shared.toml" => HEX_C),
        "source_revision" => "0123456789abcdef0123456789abcdef01234567",
        "parameter_sha256" => Dict("parameters.toml" => HEX_A),
        "comparison_schema" => "reduced-comparison-oracle-v1",
        "generator_revision" => "89abcdef0123456789abcdef0123456789abcdef",
        "compiler_identity" => compiler_identity,
        "build_platform" =>
            canonical ? "x86_64-linux-gnu" : "aarch64-apple-darwin",
        "toolchain_identity" => CANONICAL_TOOLCHAIN,
    )
end

function write_payload_manifest(
    directory,
    kind;
    model = nothing,
    generation = "representative-v1",
    forcing_sha256 = HEX_B,
    canonical = true,
    compiler_identity = "GNU Fortran 14.2.0",
    payload_text = kind,
)
    mkpath(directory)
    payload = if kind == "forcing"
        Dict("fixture_manifest" => "fixture.toml")
    elseif model == "CORPSE"
        Dict(
            "boundaries" => "boundaries.nc",
            "boundaries_manifest" => "boundaries.toml",
            "reduced_history" => "reduced_history.nc",
            "reduced_history_manifest" => "reduced_history.toml",
        )
    else
        Dict("oracle" => "oracle.toml")
    end
    files = Dict{String, String}()
    for relative_path in values(payload)
        payload_path = joinpath(directory, relative_path)
        write(payload_path, "$payload_text:$relative_path")
        files[relative_path] = sha256sum(payload_path)
    end
    document = Dict{String, Any}(
        "schema_version" => 1,
        "kind" => kind,
        "scope" => "representative",
        "generation" => generation,
        "outcome" => "passed",
        "canonical" => canonical,
        "files" => files,
        "payload" => payload,
        "provenance" =>
            provenance(; forcing_sha256, canonical, compiler_identity),
    )
    isnothing(model) || (document["model"] = model)
    write_publication_manifest(joinpath(directory, "manifest.toml"), document)
    return directory
end

function make_candidate(
    root;
    models = collect(PUBLICATION_MODELS),
    change_kind = "shared",
    omitted_model = nothing,
    incompatible_model = nothing,
    canonical = true,
    compiler_identity = "GNU Fortran 14.2.0",
    generation = "representative-v1",
    payload_suffix = "",
)
    mkpath(root)
    write_publication_manifest(
        joinpath(root, "publication_candidate.toml"),
        Dict(
            "schema_version" => 1,
            "operation" => "reference_publication",
            "outcome" => "passed",
            "scope" => "representative",
            "generation" => generation,
            "change_kind" => change_kind,
            "models" => models,
        ),
    )
    change_kind == "shared" && write_payload_manifest(
        joinpath(root, "forcing"),
        "forcing";
        generation,
        canonical,
        compiler_identity,
        payload_text = "forcing$payload_suffix",
    )
    for model in models
        model == omitted_model && continue
        write_payload_manifest(
            joinpath(root, "model-$model", "reference"),
            "reference";
            model,
            generation,
            forcing_sha256 = model == incompatible_model ? HEX_C : HEX_B,
            canonical,
            compiler_identity,
            payload_text = "$model$payload_suffix",
        )
    end
    return root
end

function empty_artifacts_toml(path)
    write(
        path,
        "[unrelated_fixture]\ngit-tree-sha1 = \"1111111111111111111111111111111111111111\"\n",
    )
    return path
end

@testset "Reference Publication rejects ordinary fresh output" begin
    mktempdir() do directory
        fresh = joinpath(directory, "fresh")
        mkpath(fresh)
        write(joinpath(fresh, "comparison.toml"), "outcome = \"passed\"\n")
        destination = joinpath(directory, "publication")

        error = try
            ReferencePublication.stage_publication(
                fresh,
                destination,
                empty_artifacts_toml(joinpath(directory, "Artifacts.toml")),
                RELEASE_URL,
            )
            nothing
        catch exception
            exception
        end

        @test error isa ReferencePublication.PublicationError
        @test occursin("publication candidate", sprint(showerror, error))
        @test !ispath(destination)
    end
end

@testset "Reference Publication stages one immutable shared compatibility set" begin
    mktempdir() do directory
        candidate = make_candidate(joinpath(directory, "candidate"))
        artifacts = empty_artifacts_toml(joinpath(directory, "Artifacts.toml"))
        original_bindings = read(artifacts)
        destination = joinpath(directory, "publication")

        result = ReferencePublication.stage_publication(
            candidate,
            destination,
            artifacts,
            RELEASE_URL,
        )

        @test result.output == destination
        @test result.generation == "representative-v1"
        @test result.models == collect(PUBLICATION_MODELS)
        @test ReferencePublication.CANONICAL_TOOLCHAIN_IDENTITY ==
              CANONICAL_TOOLCHAIN
        @test read(artifacts) == original_bindings
        staged_bindings =
            TOML.parsefile(joinpath(destination, "Artifacts.toml"))
        @test haskey(staged_bindings, "unrelated_fixture")
        expected_names = Set((
            "representative_forcing",
            "representative_corpse_reference",
            "representative_mimics_c_reference",
            "representative_mimics_cn_reference",
            "representative_casa_c_reference",
            "representative_casa_cn_reference",
        ))
        @test issetequal(
            setdiff(keys(staged_bindings), ["unrelated_fixture"]),
            expected_names,
        )
        publication = TOML.parsefile(joinpath(destination, "publication.toml"))
        @test publication["atomic_compatibility_set"]
        @test publication["change_kind"] == "shared"
        @test length(publication["asset"]) == 6
        for asset in publication["asset"]
            archive = joinpath(destination, "assets", asset["filename"])
            manifest =
                joinpath(destination, "manifests", "$(asset["binding"]).toml")
            @test isfile(archive)
            @test sha256sum(archive) == asset["sha256"]
            @test stat(archive).mode & 0o777 == 0o444
            @test isfile(manifest)
            expected = TOML.parsefile(manifest)
            @test expected["artifact"]["git_tree_sha1"] ==
                  asset["git_tree_sha1"]
            @test expected["artifact"]["sha256"] == asset["sha256"]
            binding = staged_bindings[asset["binding"]]
            @test binding["git-tree-sha1"] == asset["git_tree_sha1"]
            @test only(binding["download"])["sha256"] == asset["sha256"]
            @test startswith(only(binding["download"])["url"], RELEASE_URL)
            @test expected["provenance"]["compiler_identity"] ==
                  "GNU Fortran 14.2.0"
            @test expected["provenance"]["build_platform"] == "x86_64-linux-gnu"
            @test expected["provenance"]["scope_manifest_sha256"] == HEX_A
            @test expected["provenance"]["forcing_sha256"] ==
                  Dict("forcing.nc" => HEX_B)
            @test expected["provenance"]["parameter_sha256"] ==
                  Dict("parameters.toml" => HEX_A)
            @test expected["provenance"]["comparison_schema"] ==
                  "reduced-comparison-oracle-v1"
            @test expected["provenance"]["generator_revision"] ==
                  "89abcdef0123456789abcdef0123456789abcdef"
            @test expected["provenance"]["toolchain_identity"] ==
                  CANONICAL_TOOLCHAIN
            @test !isempty(expected["compatibility_identity"])
            required_roles = if asset["binding"] == "representative_forcing"
                Set(("fixture_manifest",))
            elseif asset["binding"] == "representative_corpse_reference"
                Set((
                    "boundaries",
                    "boundaries_manifest",
                    "reduced_history",
                    "reduced_history_manifest",
                ))
            else
                Set(("oracle",))
            end
            @test issetequal(keys(expected["payload"]), required_roles)
            @test all(
                path -> haskey(expected["files"], path),
                values(expected["payload"]),
            )
        end

        @test_throws ReferencePublication.PublicationError ReferencePublication.stage_publication(
            candidate,
            destination,
            artifacts,
            RELEASE_URL,
        )
    end
end

@testset "Reference Publication rejects partial, incompatible, and noncanonical sets" begin
    for (label, candidate_builder, message) in (
        (
            "partial",
            root -> make_candidate(root; omitted_model = "MIMICS-CN"),
            "partially mixed model set",
        ),
        (
            "incompatible",
            root -> make_candidate(root; incompatible_model = "CASA-C"),
            "compatibility",
        ),
        (
            "noncanonical",
            root -> make_candidate(root; canonical = false),
            "canonical Linux",
        ),
        (
            "non-GNU Fortran",
            root -> make_candidate(
                root;
                compiler_identity = "Intel Fortran Compiler 2021",
            ),
            "canonical Linux/GNU Fortran",
        ),
        (
            "incomplete provenance",
            root -> begin
                make_candidate(root)
                manifest_path = joinpath(
                    root,
                    "model-CASA-C",
                    "reference",
                    "manifest.toml",
                )
                manifest = TOML.parsefile(manifest_path)
                delete!(manifest["provenance"], "compiler_identity")
                write_publication_manifest(manifest_path, manifest)
                root
            end,
            "lacks compiler_identity",
        ),
        (
            "incomplete payload roles",
            root -> begin
                make_candidate(root)
                manifest_path = joinpath(
                    root,
                    "model-CORPSE",
                    "reference",
                    "manifest.toml",
                )
                manifest = TOML.parsefile(manifest_path)
                delete!(manifest["payload"], "reduced_history")
                write_publication_manifest(manifest_path, manifest)
                root
            end,
            "incompatible payload roles",
        ),
    )
        mktempdir() do directory
            candidate = candidate_builder(joinpath(directory, "candidate"))
            destination = joinpath(directory, "publication")
            error = try
                ReferencePublication.stage_publication(
                    candidate,
                    destination,
                    empty_artifacts_toml(joinpath(directory, "Artifacts.toml")),
                    RELEASE_URL,
                )
                nothing
            catch exception
                exception
            end
            @test error isa ReferencePublication.PublicationError
            @test occursin(message, sprint(showerror, error))
            @test !ispath(destination)
        end
    end
end

@testset "Reference Publication permits one compatible model-only update" begin
    mktempdir() do directory
        shared = make_candidate(joinpath(directory, "shared"))
        initial = joinpath(directory, "initial")
        artifacts = empty_artifacts_toml(joinpath(directory, "Artifacts.toml"))
        ReferencePublication.stage_publication(
            shared,
            initial,
            artifacts,
            RELEASE_URL,
        )

        model_candidate = make_candidate(
            joinpath(directory, "model-only");
            models = ["MIMICS-C"],
            change_kind = "model",
            generation = "mimics-c-v2",
            payload_suffix = "-changed",
        )
        updated = joinpath(directory, "updated")
        result = ReferencePublication.stage_publication(
            model_candidate,
            updated,
            joinpath(initial, "Artifacts.toml"),
            RELEASE_URL;
            expected_manifest_directory = joinpath(initial, "manifests"),
        )

        @test result.models == ["MIMICS-C"]
        publication = TOML.parsefile(joinpath(updated, "publication.toml"))
        @test publication["change_kind"] == "model"
        @test !publication["atomic_compatibility_set"]
        @test length(publication["asset"]) == 1
        @test only(publication["asset"])["binding"] ==
              "representative_mimics_c_reference"
        @test !haskey(
            TOML.parsefile(joinpath(updated, "Artifacts.toml")),
            "representative_forcing_v2",
        )

        incompatible = make_candidate(
            joinpath(directory, "incompatible-model");
            models = ["MIMICS-C"],
            change_kind = "model",
            incompatible_model = "MIMICS-C",
        )
        rejected = joinpath(directory, "rejected")
        error = try
            ReferencePublication.stage_publication(
                incompatible,
                rejected,
                joinpath(initial, "Artifacts.toml"),
                RELEASE_URL;
                expected_manifest_directory = joinpath(initial, "manifests"),
            )
            nothing
        catch exception
            exception
        end
        @test error isa ReferencePublication.PublicationError
        @test occursin("existing compatibility set", sprint(showerror, error))
        @test !ispath(rejected)

        forcing_manifest_path = joinpath(
            initial,
            "manifests",
            "representative_forcing.toml",
        )
        forcing_manifest = TOML.parsefile(forcing_manifest_path)
        forcing_manifest["provenance"]["forcing_sha256"]["forcing.nc"] =
            HEX_C
        write_publication_manifest(forcing_manifest_path, forcing_manifest)
        mixed = joinpath(directory, "mixed-existing-generation")
        error = try
            ReferencePublication.stage_publication(
                model_candidate,
                mixed,
                joinpath(initial, "Artifacts.toml"),
                RELEASE_URL;
                expected_manifest_directory = joinpath(initial, "manifests"),
            )
            nothing
        catch exception
            exception
        end
        @test error isa ReferencePublication.PublicationError
        @test occursin("forcing expected manifest", sprint(showerror, error))
        @test !ispath(mixed)

        shared_again = make_candidate(joinpath(directory, "shared-again"))
        clean_initial = joinpath(directory, "clean-initial")
        ReferencePublication.stage_publication(
            shared_again,
            clean_initial,
            artifacts,
            RELEASE_URL,
        )
        staged_bindings =
            TOML.parsefile(joinpath(clean_initial, "Artifacts.toml"))
        staged_bindings["representative_mimics_c_reference"]["git-tree-sha1"] =
            repeat("d", 40)
        write_publication_manifest(
            joinpath(clean_initial, "Artifacts.toml"),
            staged_bindings,
        )
        stale_binding = joinpath(directory, "stale-binding")
        error = try
            ReferencePublication.stage_publication(
                model_candidate,
                stale_binding,
                joinpath(clean_initial, "Artifacts.toml"),
                RELEASE_URL;
                expected_manifest_directory =
                    joinpath(clean_initial, "manifests"),
            )
            nothing
        catch exception
            exception
        end
        @test error isa ReferencePublication.PublicationError
        @test occursin("artifact binding", sprint(showerror, error))
        @test !ispath(stale_binding)
    end
end
