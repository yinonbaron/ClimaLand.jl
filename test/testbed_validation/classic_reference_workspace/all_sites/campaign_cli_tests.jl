using Test

if !isdefined(Main, :ClassicAllSitesCampaign)
    include("campaign.jl")
end

@testset "site receipt CLI accepts its documented arity" begin
    errors = IOBuffer()
    status = ClassicAllSitesCampaign.main(
        [
            "site-receipt",
            "AA-One",
            "/missing/evidence",
            "/missing/run",
            "/missing/output",
            "/missing/receipt.toml",
            "0",
            "0",
        ];
        stdout = IOBuffer(),
        stderr = errors,
    )
    message = String(take!(errors))
    @test status == 2
    @test occursin("missing command.txt", message)
    @test !occursin("usage:", message)
end
