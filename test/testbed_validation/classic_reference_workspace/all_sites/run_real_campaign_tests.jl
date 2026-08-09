module RunRealCampaignTests
using Test

include("run_real_campaign.jl")

@testset "real campaign callback isolates execution below packer workspace" begin
    mktempdir() do workspace
        observed = Ref{Any}()
        fake_capture! = function (site, execution_workspace, fields, config)
            observed[] = (; site, execution_workspace, fields, config)
            @test !ispath(execution_workspace)
            capture = joinpath(execution_workspace, "capture")
            mkpath(capture)
            write(joinpath(capture, "manifest.toml"), "capture")
            return (; status = "complete")
        end

        result = capture_in_child!(
            fake_capture!,
            "CA-Cbo",
            workspace,
            ["driver.thliq"],
            (; marker = "v5"),
        )

        @test result.status == "complete"
        @test observed[].site == "CA-Cbo"
        @test observed[].config.marker == "v5"
        @test isfile(joinpath(workspace, "capture", "manifest.toml"))
        @test !ispath(joinpath(workspace, "execution", "capture"))
    end

    mktempdir() do workspace
        mkpath(joinpath(workspace, "execution"))
        @test_throws ArgumentError capture_in_child!(
            (args...) -> error("stale workspace callback was invoked"),
            "CA-Cbo",
            workspace,
            String[],
            (;),
        )
    end
end
end
