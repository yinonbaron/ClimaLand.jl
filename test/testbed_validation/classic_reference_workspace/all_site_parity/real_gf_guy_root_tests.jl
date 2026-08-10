include("real_gf_guy_root.jl")
using .RealGFGuyRoot: required_archive_root

@testset "real GF-Guy archive root is explicit" begin
    @test_throws ArgumentError required_archive_root(
        String[],
        Dict{String, String}(),
    )
    @test_throws ArgumentError required_archive_root(
        ["first", "second"],
        Dict{String, String}(),
    )
    mktempdir() do cli_root
        mktempdir() do environment_root
            @test required_archive_root(
                String[],
                Dict("CLASSIC_ALL_SITE_ARCHIVE_ROOT" => environment_root),
            ) == abspath(environment_root)
            @test required_archive_root(
                [cli_root],
                Dict("CLASSIC_ALL_SITE_ARCHIVE_ROOT" => environment_root),
            ) == abspath(cli_root)
        end
    end
end
