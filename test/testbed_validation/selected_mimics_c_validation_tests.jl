using Test
import TOML

@testset "selected MIMICS-C validation workflow" begin
    mktempdir() do run_root
        result = SelectedMIMICSCValidation.write_workflow(
            abspath(joinpath(@__DIR__, "..", "..")),
            run_root;
            prepare = false,
            source_commit = repeat("a", 40),
        )
        workflow = TOML.parsefile(result.workflow_path)
        @test workflow["source_commit"] == repeat("a", 40)
        @test getindex.(workflow["stage"], "name") ==
              ["prespin", "spin", "historical"]
        expected = zip(
            (100, 499, 1),
            (0, 3, 3),
            (0, 0, 1),
            ((1901, 1901), (1901, 1920), (1901, 2014)),
        )
        for (stage, (loops, initialization, daily, years)) in
            zip(workflow["stage"], expected)
            control = TestbedReferenceHarness.parse_control(
                joinpath(dirname(result.workflow_path), stage["control"]),
            )
            @test control[:points] == 80
            @test control[:loops] == loops
            @test control[:initialization] == initialization
            @test control[:daily_output] == daily
            @test control[:years] == years
            @test control[:soil_model] == 2
            @test control[:cycle] == 1
        end
    end
end
