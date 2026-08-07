using Test
using TOML

include("workspace.jl")
using .ClassicReferenceWorkspace

function write_test_manifest(path; md5 = "900150983cd24fb0d6963f7d28e17f72")
    write(
        path,
        """
        schema_version = 1

        [workspace]
        canonical_allocation_env = "WORK"
        directory_name = "classic-v2-reference"
        minimum_free_bytes = 6
        immutable_directories = ["immutable/archives"]
        replaceable_directories = ["replaceable/builds", "replaceable/runs"]

        [prerequisites]
        platform = "linux"
        commands = ["apptainer", "tar", "curl", "md5sum"]

        [[resource]]
        id = "fixture"
        record_id = 1
        doi = "10.5281/zenodo.1"
        record_url = "https://zenodo.org/records/1"
        version = "test"
        publication_date = "2026-01-01"
        record_license = "CC-BY-4.0"

          [[resource.file]]
          filename = "fixture.txt"
          relative_path = "immutable/archives/fixture.txt"
          bytes = 3
          md5 = "$md5"
          url = "https://zenodo.org/api/records/1/files/fixture.txt/content"
        """,
    )
end

@testset "manifest contract" begin
    mktempdir() do root
        path = joinpath(root, "manifest.toml")
        write_test_manifest(path)
        manifest = load_manifest(path)
        @test manifest["schema_version"] == 1
        @test only(manifest["resource"])["id"] == "fixture"

        write_test_manifest(path; md5 = "not-a-checksum")
        @test_throws ArgumentError load_manifest(path)

        write_test_manifest(path)
        nested_policy = replace(
            read(path, String),
            "replaceable/builds" => "immutable/archives/builds",
        )
        write(path, nested_policy)
        @test_throws ArgumentError load_manifest(path)
    end

    official = load_manifest(joinpath(@__DIR__, "manifest.toml"))
    @test Set(resource["id"] for resource in official["resource"]) ==
          Set(("source", "container", "benchmark_collection"))
    @test sum(length(resource["file"]) for resource in official["resource"]) ==
          5

    receipt = TOML.parsefile(joinpath(@__DIR__, "verification_receipt.toml"))
    @test receipt["result"] == "verified"
    expected_files = Dict(
        file["filename"] => (file["bytes"], file["md5"]) for
        resource in official["resource"] for file in resource["file"]
    )
    verified_files = Dict(
        file["filename"] => (file["bytes"], file["md5"]) for
        file in receipt["file"] if file["status"] == "verified"
    )
    @test verified_files == expected_files
end

@testset "workspace allocation boundary" begin
    mktempdir() do root
        allocation = joinpath(root, "work")
        repository = joinpath(root, "repo")
        outside = joinpath(root, "outside")
        mkpath.((allocation, repository, outside))

        workspace = joinpath(allocation, "classic-v2-reference")
        @test validate_workspace_location(workspace, allocation, repository) ==
              abspath(workspace)
        @test_throws ArgumentError validate_workspace_location(
            joinpath(outside, "classic-v2-reference"),
            allocation,
            repository,
        )
        @test_throws ArgumentError validate_workspace_location(
            joinpath(repository, "large-data"),
            allocation,
            repository,
        )

        link = joinpath(allocation, "escape")
        symlink(outside, link)
        @test_throws ArgumentError validate_workspace_location(
            joinpath(link, "classic-v2-reference"),
            allocation,
            repository,
        )
    end
end

@testset "size and checksum verification" begin
    mktempdir() do root
        manifest_path = joinpath(root, "manifest.toml")
        workspace = joinpath(root, "workspace")
        artifact = joinpath(workspace, "immutable", "archives", "fixture.txt")
        write_test_manifest(manifest_path)
        mkpath(dirname(artifact))
        write(artifact, "abc")

        manifest = load_manifest(manifest_path)
        report = verify_workspace(manifest, workspace)
        @test report.ok
        @test only(report.files).status == :verified

        write(artifact, "ab")
        report = verify_workspace(manifest, workspace)
        @test !report.ok
        @test only(report.files).status == :size_mismatch

        write(artifact, "abd")
        report = verify_workspace(manifest, workspace)
        @test !report.ok
        @test only(report.files).status == :checksum_mismatch
    end
end

@testset "public CLI is fail closed" begin
    mktempdir() do root
        manifest_path = joinpath(root, "manifest.toml")
        workspace = joinpath(root, "classic-v2-reference")
        environment = Dict("WORK" => root)
        write_test_manifest(manifest_path)

        output = IOBuffer()
        errors = IOBuffer()
        @test main(
            ["verify", manifest_path, workspace];
            stdout = output,
            stderr = errors,
            environment,
        ) == 1
        @test occursin("missing", String(take!(output)))

        artifact = joinpath(workspace, "immutable", "archives", "fixture.txt")
        mkpath(dirname(artifact))
        write(artifact, "abc")
        @test main(
            ["verify", manifest_path, workspace];
            stdout = output,
            stderr = errors,
            environment,
        ) == 0
        @test occursin("verified", String(take!(output)))

        @test main(
            ["unknown", manifest_path, workspace];
            stdout = output,
            stderr = errors,
        ) == 2
        @test occursin("usage:", String(take!(errors)))

        repository = joinpath(root, "repo")
        repository_workspace = joinpath(repository, "classic-v2-reference")
        mkpath(joinpath(repository_workspace, "replaceable", "staging"))
        @test main(
            ["fetch", manifest_path, repository_workspace];
            stdout = output,
            stderr = errors,
            environment,
            repository_root = repository,
        ) == 2
        @test occursin("outside the Git repository", String(take!(errors)))

        mktempdir() do outside
            outside_workspace = joinpath(outside, "classic-v2-reference")
            mkpath(joinpath(outside_workspace, "replaceable", "staging"))
            @test main(
                ["fetch", manifest_path, outside_workspace];
                stdout = output,
                stderr = errors,
                environment,
                repository_root = repository,
            ) == 2
            @test occursin("canonical allocation", String(take!(errors)))
        end
    end
end

@testset "fetch stages and protects immutable files" begin
    mktempdir() do root
        manifest_path = joinpath(root, "manifest.toml")
        workspace = joinpath(root, "workspace")
        source = joinpath(root, "source.txt")
        destination =
            joinpath(workspace, "immutable", "archives", "fixture.txt")
        write_test_manifest(manifest_path)
        write(source, "abc")
        mkpath(joinpath(workspace, "replaceable", "staging"))

        downloader = (_, temporary) -> cp(source, temporary)
        manifest = load_manifest(manifest_path)
        fetched = fetch_resources(manifest, workspace; downloader)
        @test fetched == [destination]
        @test read(destination, String) == "abc"

        write(destination, "abd")
        @test_throws ArgumentError fetch_resources(
            manifest,
            workspace;
            downloader,
        )
        @test read(destination, String) == "abd"

        rm(destination)
        write(source, "ab")
        @test_throws ArgumentError fetch_resources(
            manifest,
            workspace;
            downloader,
        )
        @test !ispath(destination)
        @test isempty(readdir(joinpath(workspace, "replaceable", "staging")))

        staging = joinpath(workspace, "replaceable", "staging")
        rm(staging)
        outside = joinpath(root, "outside")
        mkpath(outside)
        symlink(outside, staging)
        write(source, "abc")
        @test_throws ArgumentError fetch_resources(
            manifest,
            workspace;
            downloader,
        )
        @test isempty(readdir(outside))
    end
end
