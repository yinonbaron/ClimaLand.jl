using Test
import TOML

@testset "selected MIMICS-CN validation workflow" begin
    mktempdir() do run_root
        source_root = abspath(joinpath(@__DIR__, "..", ".."))
        result = SelectedMIMICSCNValidation.write_workflow(
            source_root,
            run_root;
            prepare = false,
            source_commit = "82c57f8aa1179865d9752b617493ef06f45c3266",
        )
        workflow = TOML.parsefile(result.workflow_path)
        @test workflow["source_commit"] ==
              "82c57f8aa1179865d9752b617493ef06f45c3266"
        @test getindex.(workflow["stage"], "name") ==
              ["prespin", "spin", "spin_continuation", "historical"]
        expected = zip(
            (100, 499, 499, 1),
            (0, 3, 3, 3),
            (0, 0, 0, 1),
            ((1901, 1901), (1901, 1920), (1901, 1920), (1901, 2014)),
        )
        for (stage, (loops, initialization, daily, years)) in
            zip(workflow["stage"], expected)
            control = TestbedReferenceHarness.parse_control(
                joinpath(dirname(result.workflow_path), stage["control"]),
            )
            @test control[:points] == 37
            @test control[:loops] == loops
            @test control[:initialization] == initialization
            @test control[:daily_output] == daily
            @test control[:years] == years
            @test control[:soil_model] == 2
            @test control[:cycle] == 2
            @test control[:casa_initial] == "casa_initial.csv"
            @test control[:mimics_initial] == "mimics_initial.csv"
        end
        mimics_sources = [
            input["source"] for stage in workflow["stage"] for
            input in stage["input"] if
            input["destination"] == "mimics_parameters.csv"
        ]
        @test length(mimics_sources) == 4
        @test all(
            endswith(
                source,
                TestbedNativeMIMICSCNReconstruction.MIMICS_PARAMETER_FILE,
            ) for source in mimics_sources
        )
        prespin_sources = [
            input["source"] for stage in workflow["stage"] for
            input in stage["input"] if
            input["destination"] == "casa_parameters.csv" &&
            stage["name"] == "prespin"
        ]
        @test prespin_sources == [result.prespin_parameters]
        @test occursin("selected_inputs/candidates", only(prespin_sources))
    end
end
