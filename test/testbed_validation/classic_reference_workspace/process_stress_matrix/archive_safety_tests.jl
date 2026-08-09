import Tar

@testset "site archive extraction rejects unsafe members" begin
    @test_throws ArgumentError validate_archive_member_paths(["../escape"])
    @test_throws ArgumentError validate_archive_member_paths(["/absolute"])
    @test_throws ArgumentError validate_archive_member_paths(["manifest.toml"])
    control = ["manifest.toml", "capture_receipt.toml", "field_activity.toml"]
    @test validate_archive_member_paths(
        vcat(
            control,
            [
                "payloads",
                "payloads/fixed/static_zbot.bin",
                "evidence",
                "evidence/replay_receipt.toml",
            ],
        ),
    )
    @test_throws ArgumentError validate_archive_member_paths(
        vcat(control, ["replay_receipt_atol_1e-13.toml"]),
    )

    mktempdir() do directory
        source = joinpath(directory, "source")
        mkpath(source)
        for name in
            ("manifest.toml", "capture_receipt.toml", "field_activity.toml")
            write(joinpath(source, name), name)
        end
        archive = joinpath(directory, "safe.tar")
        Tar.create(source, archive)
        destination = joinpath(directory, "extracted")
        @test ClassicMatrixExecution.extract_site_archive(
            archive,
            destination,
        ) == destination
        @test isfile(joinpath(destination, "manifest.toml"))
        @test_throws ArgumentError ClassicMatrixExecution.extract_site_archive(
            archive,
            destination,
        )

        linked_source = joinpath(directory, "linked")
        mkpath(linked_source)
        for name in
            ("manifest.toml", "capture_receipt.toml", "field_activity.toml")
            write(joinpath(linked_source, name), name)
        end
        symlink("manifest.toml", joinpath(linked_source, "linked-manifest"))
        linked_archive = joinpath(directory, "linked.tar")
        Tar.create(linked_source, linked_archive)
        @test_throws ArgumentError ClassicMatrixExecution.extract_site_archive(
            linked_archive,
            joinpath(directory, "linked-extracted"),
        )
    end
end
