module GeneratePinnedCORPSEPayloadTests

using Test
import Tar

include(joinpath(@__DIR__, "generate_pinned_corpse_payload.jl"))
const Generator = GeneratePinnedCORPSEPayload

@testset "boundary payload archive contains the exact contract members" begin
    mktempdir() do root
        source = joinpath(root, "source")
        mkpath(source)
        for relative in Generator.boundary_members()
            path = joinpath(source, relative)
            mkpath(dirname(path))
            write(path, relative)
        end
        archive = joinpath(root, "boundaries.tar")
        manifest = joinpath(root, "boundaries.toml")
        Generator.create_boundary_payload(source, archive, manifest)
        members = Set(
            header.path for header in Tar.list(archive; strict = true) if
            header.type == :file
        )
        @test members == Set(Generator.boundary_members())
    end
end

end
