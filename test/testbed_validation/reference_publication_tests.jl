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
const PUBLICATION_SCOPE_PATH =
    joinpath(@__DIR__, "validation", "scopes", "representative.toml")
const PUBLICATION_SCOPE = TOML.parsefile(PUBLICATION_SCOPE_PATH)
const PUBLICATION_CELL_IDS = Int.(PUBLICATION_SCOPE["cell_ids"])

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
        "scope_manifest_sha256" => sha256sum(PUBLICATION_SCOPE_PATH),
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

function write_build_receipt(
    root;
    canonical = true,
    compiler_identity = "GNU Fortran 14.2.0",
)
    metadata_path = joinpath(root, "build_metadata.toml")
    write_publication_manifest(
        metadata_path,
        Dict(
            "schema_version" => 1,
            "verified" => true,
            "build_platform" =>
                canonical ? "x86_64-linux-gnu" : "aarch64-apple-darwin",
            "toolchain_identity" => CANONICAL_TOOLCHAIN,
            "compiler_identity" => compiler_identity,
            "verification" => Dict(
                "source_commit" =>
                    "0123456789abcdef0123456789abcdef01234567",
                "source_code_clean" => true,
                "executable_sha256" => HEX_A,
            ),
        ),
    )
    path = joinpath(root, "canonical_build_receipt.toml")
    write_publication_manifest(
        path,
        Dict(
            "schema_version" => 1,
            "kind" => "canonical_fortran_build_receipt",
            "verified" => true,
            "canonical" => canonical,
            "compiler_identity" => compiler_identity,
            "build_platform" =>
                canonical ? "x86_64-linux-gnu" : "aarch64-apple-darwin",
            "toolchain_identity" => CANONICAL_TOOLCHAIN,
            "source_build_metadata_sha256" => sha256sum(metadata_path),
            "verification" => Dict(
                "source_commit" => "0123456789abcdef0123456789abcdef01234567",
                "source_code_clean" => true,
                "executable_sha256" => HEX_A,
            ),
        ),
    )
    return path
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
    build_receipt_sha256,
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
    if kind == "forcing"
        write_publication_manifest(
            joinpath(directory, payload["fixture_manifest"]),
            Dict(
                "schema_version" => 1,
                "selection" => Dict(
                    "representative_cell_ids" => PUBLICATION_CELL_IDS,
                    "scope_manifest_sha256" =>
                        sha256sum(PUBLICATION_SCOPE_PATH),
                ),
            ),
        )
    elseif model == "CORPSE"
        write(
            joinpath(directory, payload["boundaries"]),
            "$payload_text:boundaries",
        )
        write_publication_manifest(
            joinpath(directory, payload["boundaries_manifest"]),
            Dict(
                "schema_version" => 1,
                "schema" => "corpse-boundary-archive-v1",
                "model" => model,
                "scope" => "representative",
                "scope_cell_count" => 80,
                "eligible_cell_count" => 78,
            ),
        )
        reduced = joinpath(directory, payload["reduced_history"])
        write(reduced, "$payload_text:reduced-history")
        write_publication_manifest(
            joinpath(directory, payload["reduced_history_manifest"]),
            Dict(
                "schema_version" => 1,
                "reference_id" => "corpse-c-representative-fortran-reduced-v1",
                "scope" => "representative",
                "scope_cell_count" => 80,
                "eligible_cell_count" => 78,
            ),
        )
    else
        oracle = Dict{String, Any}(
            "schema_version" => 1,
            "cell_ids" => PUBLICATION_CELL_IDS,
        )
        if model in ("MIMICS-C", "MIMICS-CN")
            oracle["model"] = model
            oracle["scope"] = "representative"
            oracle["oracle"] = Dict(
                name => Dict("payload" => payload_text) for
                name in ("boundary", "annual", "daily", "budget")
            )
        else
            oracle["tier"] = "representative"
            configuration =
                model == "CASA-C" ? "carbon_only" : "carbon_nitrogen"
            oracle["configuration"] =
                Dict(configuration => Dict("payload" => payload_text))
        end
        write_publication_manifest(
            joinpath(directory, payload["oracle"]),
            oracle,
        )
    end
    for relative_path in values(payload)
        files[relative_path] = sha256sum(joinpath(directory, relative_path))
    end
    comparison_sha256 = nothing
    if kind == "reference"
        comparison_path = joinpath(dirname(directory), "comparison.toml")
        source_comparison_path =
            joinpath(dirname(directory), "source_comparison.toml")
        expected_eligible = model == "CORPSE" ? 78 : 80
        source_comparison = Dict{String, Any}(
            "schema_version" => 1,
            "model" => model,
            "scope" => "representative",
            "outcome" => "passed",
            "coverage" => Dict(
                "scope_cells" => 80,
                "eligible_cells" => expected_eligible,
                "compared_cells" => expected_eligible,
            ),
        )
        if model == "CORPSE"
            source_comparison["stage"] = Dict(
                "historical" => Dict(
                    "comparison" => Dict(
                        "state" => Dict("all_match" => true),
                    ),
                ),
            )
            source_comparison["reduced_historical"] = Dict(
                name => Dict("state" => Dict("all_match" => true)) for name in
                (
                    "annual_summaries",
                    "end_of_year",
                    "annual_budgets",
                    "fixed_daily_samples",
                )
            )
            source_comparison["budget"] = Dict("verified" => true)
        else
            source_comparison["boundary_comparison"] =
                Dict("historical" => Dict("all_match" => true))
            source_comparison["historical_comparison"] = Dict(
                "annual" => Dict("all_match" => true),
                "fixed_daily_samples" => Dict("all_match" => true),
            )
            source_comparison["carbon_budget"] = Dict("all_close" => true)
            model in ("MIMICS-CN", "CASA-CN") &&
                (source_comparison["nitrogen_budget"] =
                    Dict("all_close" => true))
        end
        write_publication_manifest(source_comparison_path, source_comparison)
        write_publication_manifest(
            comparison_path,
            Dict(
                "schema_version" => 1,
                "kind" => "reference_comparison_receipt",
                "model" => model,
                "scope" => "representative",
                "scope_manifest_sha256" => sha256sum(PUBLICATION_SCOPE_PATH),
                "build_receipt_sha256" => build_receipt_sha256,
                "outcome" => "passed",
                "source_comparison_sha256" =>
                    sha256sum(source_comparison_path),
                "coverage" => Dict(
                    "scope_cells" => 80,
                    "eligible_cells" => expected_eligible,
                    "compared_cells" => expected_eligible,
                ),
                "check" => Dict(
                    "boundaries" => true,
                    "annual_summaries" => true,
                    "budget_diagnostics" => true,
                    "fixed_daily_samples" => true,
                ),
                "reference_files" => files,
            ),
        )
        comparison_sha256 = sha256sum(comparison_path)
    end
    payload_provenance =
        provenance(; forcing_sha256, canonical, compiler_identity)
    payload_provenance["build_receipt_sha256"] = build_receipt_sha256
    isnothing(comparison_sha256) ||
        (payload_provenance["comparison_report_sha256"] = comparison_sha256)
    document = Dict{String, Any}(
        "schema_version" => 1,
        "kind" => kind,
        "scope" => "representative",
        "generation" => generation,
        "outcome" => "passed",
        "canonical" => canonical,
        "files" => files,
        "payload" => payload,
        "provenance" => payload_provenance,
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
    build_receipt = write_build_receipt(root; canonical, compiler_identity)
    build_receipt_sha256 = sha256sum(build_receipt)
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
        build_receipt_sha256,
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
            build_receipt_sha256,
        )
    end
    return root
end

function make_canonical_fresh_run(root, candidate)
    build = joinpath(root, "build")
    mkpath(build)
    executable = joinpath(build, "casaclm_mimics-cn_corpse")
    write(executable, "canonical executable")
    write_publication_manifest(
        joinpath(build, "build_metadata.toml"),
        Dict(
            "schema_version" => 1,
            "verified" => true,
            "build_platform" => "x86_64-linux-gnu",
            "toolchain_identity" => CANONICAL_TOOLCHAIN,
            "compiler_identity" => "GNU Fortran 14.2.0",
            "verification" => Dict(
                "executable" => basename(executable),
                "executable_sha256" => sha256sum(executable),
                "source_commit" =>
                    ReferencePublication.PINNED_FORTRAN_SOURCE_COMMIT,
                "source_code_clean" => true,
            ),
        ),
    )
    for model in PUBLICATION_MODELS
        model_root = joinpath(root, "model-$model")
        mkpath(model_root)
        payload = joinpath(candidate, "model-$model", "reference")
        role = model == "CORPSE" ? "reduced_history" : "oracle"
        relative = TOML.parsefile(joinpath(payload, "manifest.toml"))["payload"][role]
        reference = joinpath(model_root, basename(relative))
        cp(joinpath(payload, relative), reference)
        if model == "CORPSE"
            cp(payload, joinpath(model_root, "payload"))
        end
        historical = Dict(
            "all_match" => true,
            "annual" => Dict("all_match" => true),
            "fixed_daily_samples" => Dict("all_match" => true),
        )
        report = Dict{String, Any}(
            "schema_version" => 1,
            "model" => model,
            "scope" => "representative",
            "outcome" => "passed",
            "coverage" => Dict(
                "scope_cells" => 80,
                "eligible_cells" => model == "CORPSE" ? 78 : 80,
                "compared_cells" => model == "CORPSE" ? 78 : 80,
            ),
            "reference" => Dict(
                "path" => reference,
                "sha256" => sha256sum(reference),
                "kind" => "fresh_reduced_oracle",
            ),
        )
        if model == "CORPSE"
            report["stage"] = Dict(
                stage => Dict(
                    "comparison" => Dict(
                        "state" => Dict("all_match" => true),
                    ),
                ) for stage in
                ("prespin", "spin", "spin_continuation", "historical")
            )
            report["reduced_historical"] = Dict(
                name => Dict("state" => Dict("all_match" => true)) for name in
                (
                    "annual_summaries",
                    "end_of_year",
                    "annual_budgets",
                    "fixed_daily_samples",
                )
            )
            report["budget"] = Dict("verified" => true)
        else
            report["boundary_comparison"] = Dict(
                "historical" => Dict("all_match" => true),
            )
            report["historical_comparison"] = historical
            report["carbon_budget"] = Dict("all_close" => true)
            model in ("MIMICS-CN", "CASA-CN") &&
                (report["nitrogen_budget"] = Dict("all_close" => true))
        end
        write_publication_manifest(joinpath(model_root, "comparison.toml"), report)
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
            ReferencePublication._stage_prepared_publication(
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

@testset "Reference Publication rejects self-attested candidates" begin
    mktempdir() do directory
        candidate = make_candidate(joinpath(directory, "candidate"))
        rm(joinpath(candidate, "canonical_build_receipt.toml"))
        error = try
            ReferencePublication._stage_prepared_publication(
                candidate,
                joinpath(directory, "publication"),
                empty_artifacts_toml(joinpath(directory, "Artifacts.toml")),
                RELEASE_URL,
            )
            nothing
        catch exception
            exception
        end

        @test error isa ReferencePublication.PublicationError
        @test occursin("canonical build receipt", sprint(showerror, error))
    end
end

@testset "Reference Publication bridges validated fresh evidence" begin
    mktempdir() do directory
        candidate = make_candidate(joinpath(directory, "candidate"))
        fresh = make_canonical_fresh_run(joinpath(directory, "fresh"), candidate)
        rm(joinpath(candidate, "canonical_build_receipt.toml"))
        rm(joinpath(candidate, "build_metadata.toml"))
        for model in PUBLICATION_MODELS
            rm(joinpath(candidate, "model-$model", "comparison.toml"))
            rm(joinpath(candidate, "model-$model", "source_comparison.toml"))
        end
        destination = joinpath(directory, "publication")

        result = ReferencePublication.stage_publication(
            fresh,
            candidate,
            destination,
            empty_artifacts_toml(joinpath(directory, "Artifacts.toml")),
            RELEASE_URL,
        )

        @test result.output == destination
        evidence = joinpath(destination, "evidence")
        @test isfile(joinpath(evidence, "build_metadata.toml"))
        @test all(
            isfile(joinpath(evidence, "$model-source-comparison.toml")) for
            model in PUBLICATION_MODELS
        )
        receipt = TOML.parsefile(joinpath(evidence, "CASA-C-comparison.toml"))
        @test receipt["source_comparison_sha256"] ==
              sha256sum(joinpath(evidence, "CASA-C-source-comparison.toml"))

        tampered = make_candidate(joinpath(directory, "tampered-candidate"))
        tampered_fresh = make_canonical_fresh_run(
            joinpath(directory, "tampered-fresh"),
            tampered,
        )
        comparison = joinpath(tampered_fresh, "model-CASA-C", "comparison.toml")
        report = TOML.parsefile(comparison)
        write(report["reference"]["path"], "tampered after comparison")
        @test_throws ReferencePublication.PublicationError ReferencePublication.stage_publication(
            tampered_fresh,
            tampered,
            joinpath(directory, "tampered-publication"),
            empty_artifacts_toml(joinpath(directory, "tampered-Artifacts.toml")),
            RELEASE_URL,
        )

        incomplete = make_candidate(joinpath(directory, "incomplete-candidate"))
        incomplete_fresh = make_canonical_fresh_run(
            joinpath(directory, "incomplete-fresh"),
            incomplete,
        )
        comparison =
            joinpath(incomplete_fresh, "model-MIMICS-C", "comparison.toml")
        report = TOML.parsefile(comparison)
        delete!(report["historical_comparison"], "fixed_daily_samples")
        write_publication_manifest(comparison, report)
        @test_throws ReferencePublication.PublicationError ReferencePublication.stage_publication(
            incomplete_fresh,
            incomplete,
            joinpath(directory, "incomplete-publication"),
            empty_artifacts_toml(joinpath(directory, "incomplete-Artifacts.toml")),
            RELEASE_URL,
        )
    end
end

@testset "Reference Publication stages one immutable shared compatibility set" begin
    mktempdir() do directory
        candidate = make_candidate(joinpath(directory, "candidate"))
        artifacts = empty_artifacts_toml(joinpath(directory, "Artifacts.toml"))
        original_bindings = read(artifacts)
        destination = joinpath(directory, "publication")

        result = ReferencePublication._stage_prepared_publication(
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
        evidence = joinpath(destination, "evidence")
        @test Set(readdir(evidence)) == Set((
            "canonical_build_receipt.toml",
            "build_metadata.toml",
            ("$model-comparison.toml" for model in PUBLICATION_MODELS)...,
            ("$model-source-comparison.toml" for model in PUBLICATION_MODELS)...,
        ))
        build_receipt_sha256 =
            sha256sum(joinpath(evidence, "canonical_build_receipt.toml"))
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
            @test expected["provenance"]["scope_manifest_sha256"] ==
                  sha256sum(PUBLICATION_SCOPE_PATH)
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
            @test expected["provenance"]["build_receipt_sha256"] ==
                  build_receipt_sha256
            if asset["binding"] != "representative_forcing"
                model = only(
                    model for
                    (model, binding) in ReferencePublication.BINDINGS if
                    binding == asset["binding"]
                )
                @test expected["provenance"]["comparison_report_sha256"] ==
                      sha256sum(joinpath(evidence, "$model-comparison.toml"))
            end
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

        @test_throws ReferencePublication.PublicationError ReferencePublication._stage_prepared_publication(
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
                ReferencePublication._stage_prepared_publication(
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

@testset "Reference Publication verifies canonical comparison evidence" begin
    cases = (
        (
            "unverified build",
            root -> begin
                path = joinpath(root, "canonical_build_receipt.toml")
                receipt = TOML.parsefile(path)
                receipt["verification"]["executable_sha256"] = "not-a-sha256"
                write_publication_manifest(path, receipt)
            end,
            "executable evidence",
        ),
        (
            "failed comparison",
            root -> begin
                path = joinpath(root, "model-MIMICS-C", "comparison.toml")
                report = TOML.parsefile(path)
                report["outcome"] = "failed"
                write_publication_manifest(path, report)
            end,
            "successful canonical comparison",
        ),
        (
            "incomplete coverage",
            root -> begin
                path = joinpath(root, "model-MIMICS-CN", "comparison.toml")
                report = TOML.parsefile(path)
                report["coverage"]["compared_cells"] = 79
                write_publication_manifest(path, report)
            end,
            "incomplete coverage",
        ),
        (
            "wrong scope",
            root -> begin
                path = joinpath(root, "model-CASA-C", "reference", "oracle.toml")
                oracle = TOML.parsefile(path)
                oracle["cell_ids"] = PUBLICATION_CELL_IDS[1:79]
                write_publication_manifest(path, oracle)
                manifest_path = joinpath(dirname(path), "manifest.toml")
                manifest = TOML.parsefile(manifest_path)
                manifest["files"]["oracle.toml"] = sha256sum(path)
                write_publication_manifest(manifest_path, manifest)
            end,
            "exact Representative scope",
        ),
        (
            "incomplete oracle",
            root -> begin
                path = joinpath(root, "model-MIMICS-C", "reference", "oracle.toml")
                oracle = TOML.parsefile(path)
                delete!(oracle["oracle"], "daily")
                write_publication_manifest(path, oracle)
                manifest_path = joinpath(dirname(path), "manifest.toml")
                manifest = TOML.parsefile(manifest_path)
                manifest["files"]["oracle.toml"] = sha256sum(path)
                write_publication_manifest(manifest_path, manifest)
            end,
            "incompatible schema",
        ),
    )
    for (label, mutate, message) in cases
        mktempdir() do directory
            candidate = make_candidate(joinpath(directory, "candidate"))
            mutate(candidate)
            error = try
                ReferencePublication._stage_prepared_publication(
                    candidate,
                    joinpath(directory, "publication"),
                    empty_artifacts_toml(joinpath(directory, "Artifacts.toml")),
                    RELEASE_URL,
                )
                nothing
            catch exception
                exception
            end
            @test error isa ReferencePublication.PublicationError
            @test occursin(message, sprint(showerror, error))
            @test !ispath(joinpath(directory, "publication"))
        end
    end
end

@testset "Reference Publication permits one compatible model-only update" begin
    mktempdir() do directory
        shared = make_candidate(joinpath(directory, "shared"))
        initial = joinpath(directory, "initial")
        artifacts = empty_artifacts_toml(joinpath(directory, "Artifacts.toml"))
        ReferencePublication._stage_prepared_publication(
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
        result = ReferencePublication._stage_prepared_publication(
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
            ReferencePublication._stage_prepared_publication(
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

        forcing_manifest_path =
            joinpath(initial, "manifests", "representative_forcing.toml")
        forcing_manifest = TOML.parsefile(forcing_manifest_path)
        forcing_manifest["provenance"]["forcing_sha256"]["forcing.nc"] = HEX_C
        write_publication_manifest(forcing_manifest_path, forcing_manifest)
        mixed = joinpath(directory, "mixed-existing-generation")
        error = try
            ReferencePublication._stage_prepared_publication(
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
        ReferencePublication._stage_prepared_publication(
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
            ReferencePublication._stage_prepared_publication(
                model_candidate,
                stale_binding,
                joinpath(clean_initial, "Artifacts.toml"),
                RELEASE_URL;
                expected_manifest_directory = joinpath(
                    clean_initial,
                    "manifests",
                ),
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
