using Test
import SHA
import TOML

include(joinpath(@__DIR__, "fresh_reference_adapter.jl"))
const FreshReferenceAdapter = TestbedFreshReferenceAdapter

@testset "Fresh-reference adapter verifies shared builds" begin
    mktempdir() do directory
        executable = joinpath(directory, "casaclm_mimics-cn_corpse")
        write(executable, "shared executable")
        metadata_path = joinpath(directory, "build_metadata.toml")
        metadata = Dict(
            "schema_version" => 1,
            "verified" => true,
            "verification" => Dict(
                "executable" => basename(executable),
                "executable_sha256" =>
                    bytes2hex(SHA.sha256(read(executable))),
                "source_commit" =>
                    FreshReferenceAdapter.PINNED_SOURCE_COMMIT,
                "source_code_clean" => true,
            ),
        )
        open(metadata_path, "w") do io
            TOML.print(io, metadata; sorted = true)
        end

        @test FreshReferenceAdapter.verified_executable(directory) == executable
        write(executable, "changed")
        @test_throws FreshReferenceAdapter.AdapterError FreshReferenceAdapter.verified_executable(
            directory,
        )
    end
end

@testset "Fresh-reference commands expose the orchestration seam" begin
    commands = FreshReferenceAdapter.commands("../biogeochem_testbed")
    build = commands.build("/tmp/fresh-build")
    worker = commands.worker("CASA-C", "/tmp/fresh-casa", "/tmp/fresh-build")

    @test first(build.exec) == Base.julia_cmd().exec[1]
    @test "build" in build.exec
    @test abspath("../biogeochem_testbed") in build.exec
    @test "worker" in worker.exec
    @test "CASA-C" in worker.exec
    @test abspath("../biogeochem_testbed") in worker.exec
    @test_throws FreshReferenceAdapter.AdapterError commands.preflight([
        "CASA-C",
    ])
    @test_throws FreshReferenceAdapter.AdapterError commands.preflight([
        "MIMICS-CN",
    ])
    configured = FreshReferenceAdapter.commands(
        "../biogeochem_testbed";
        mimics_cn_forcing_root = "/tmp/forcing",
        mimics_cn_reference_template = "/tmp/reference-template",
    )
    @test isnothing(configured.preflight(["MIMICS-CN"]))
    mimics_cn = configured.worker(
        "MIMICS-CN",
        "/tmp/fresh-mimics-cn",
        "/tmp/fresh-build",
    )
    @test "worker" in mimics_cn.exec
    @test "/tmp/forcing" in mimics_cn.exec
    @test "/tmp/reference-template" in mimics_cn.exec
end

@testset "Fresh model capabilities expose exact remaining gaps" begin
    @test Set(keys(FreshReferenceAdapter.MISSING_MODEL_COMMANDS)) ==
          Set(("CASA-C", "CASA-CN", "MIMICS-C", "CORPSE"))
    @test Set(keys(FreshReferenceAdapter.MODEL_CAPABILITIES)) ==
          Set(FreshReferenceAdapter.ModelProcesses.MODELS)
    for model in FreshReferenceAdapter.ModelProcesses.MODELS
        capability = FreshReferenceAdapter.model_capability(model)
        @test isfile(capability.runner)
        if model == "MIMICS-CN"
            @test capability.representative_ready
            @test isempty(capability.blocker)
            @test FreshReferenceAdapter.require_model_command(model) ==
                  capability
        else
            @test !capability.representative_ready
            @test !isempty(capability.blocker)
            error = try
                FreshReferenceAdapter.require_model_command(model)
                nothing
            catch caught
                caught
            end
            @test error isa FreshReferenceAdapter.AdapterError
            @test occursin(model, error.message)
            @test occursin("Representative", error.message)
        end
    end
    mimics_cn = FreshReferenceAdapter.model_capability("MIMICS-CN")
    @test mimics_cn.deepest_scope == "representative"
    @test mimics_cn.shared_build
    @test mimics_cn.completed_phases ==
          ("fortran", "julia", "comparison", "eligibility_gap_proposal")
    status = FreshReferenceAdapter.status_document()
    @test status["representative_workers_ready"] === false
    @test Set(keys(status["model"])) ==
          Set(FreshReferenceAdapter.ModelProcesses.MODELS)
end

@testset "Fresh MIMICS-CN bridge writes the standard comparison contract" begin
    mktempdir() do directory
        oracle = joinpath(directory, "reduced_oracle.toml")
        write(oracle, "model = \"MIMICS-CN\"\n")
        scientific = joinpath(directory, "scientific.toml")
        open(scientific, "w") do io
            TOML.print(
                io,
                Dict(
                    "schema_version" => 1,
                    "coverage" => Dict(
                        "scope_cells" => 80,
                        "compared_cells" => 80,
                    ),
                    "boundary_comparison" => Dict(
                        stage => Dict("all_match" => true) for stage in
                        ("prespin", "spin", "spin_continuation", "historical")
                    ),
                    "historical_comparison" => Dict("all_match" => true),
                    "carbon_budget" => Dict("all_close" => true),
                    "nitrogen_budget" => Dict("all_close" => true),
                );
                sorted = true,
            )
        end

        comparison = FreshReferenceAdapter.write_mimics_cn_comparison(
            directory,
            scientific,
            oracle,
        )

        @test comparison.passed
        @test basename(comparison.path) == "comparison.toml"
        report = TOML.parsefile(comparison.path)
        @test report["model"] == "MIMICS-CN"
        @test report["scope"] == "representative"
        @test report["outcome"] == "passed"
        @test report["reference"]["sha256"] ==
              FreshReferenceAdapter.sha256sum(oracle)
        @test report["boundary_comparison"]["historical"]["all_match"]

        failed = TOML.parsefile(scientific)
        failed["historical_comparison"]["all_match"] = false
        open(scientific, "w") do io
            TOML.print(io, failed; sorted = true)
        end
        @test !FreshReferenceAdapter.write_mimics_cn_comparison(
            directory,
            scientific,
            oracle,
        ).passed

        delete!(failed["boundary_comparison"], "historical")
        open(scientific, "w") do io
            TOML.print(io, failed; sorted = true)
        end
        @test_throws FreshReferenceAdapter.AdapterError FreshReferenceAdapter.write_mimics_cn_comparison(
            directory,
            scientific,
            oracle,
        )
    end
end

@testset "Fresh MIMICS-CN bridge emits first nonfinite evidence by cell" begin
    finite = [1.0, 2.0]
    boundaries = Dict(
        "prespin" => Dict("casa_plant.c_leaf" => finite),
        "spin" => Dict(
            "casa_plant.c_leaf" => [Inf, 2.0],
            "mimics_soil.n_mineral" => finite,
        ),
        "spin_continuation" => Dict(
            "casa_plant.c_leaf" => [Inf, 2.0],
            "mimics_soil.n_mineral" => [1.0, -Inf],
        ),
        "historical" => Dict("casa_plant.c_leaf" => [Inf, 2.0]),
    )

    records = FreshReferenceAdapter.first_mimics_cn_boundary_nonfinites(
        boundaries,
        [51, 3442],
    )

    @test getindex.(records, "cell_id") == [51, 3442]
    @test getindex.(records, "first_nonfinite_stage") ==
          ["spin", "spin_continuation"]
    @test getindex.(records, "first_nonfinite_date") ==
          ["1920-12-31", "1920-12-31"]
    @test getindex.(records, "evidence_side") == ["fortran", "fortran"]
    @test records[2]["first_nonfinite_variable"] ==
          "mimics_soil.n_mineral"

    mktempdir() do directory
        path = FreshReferenceAdapter.write_mimics_cn_nonfinite_results(
            directory,
            records,
        )
        document = TOML.parsefile(path)
        @test document["schema_version"] == 1
        @test document["model"] == "MIMICS-CN"
        @test document["nonfinite"] == records
    end
end

@testset "Fresh MIMICS-CN historical and Julia nonfinites retain exact evidence" begin
    calls = Int[]
    read_year = year -> begin
        push!(calls, year)
        first_variable = zeros(2, 365)
        second_variable = zeros(2, 365)
        if year == 1901
            first_variable[1, 91] = Inf
            second_variable[1, 90] = -Inf
        elseif year == 1902
            first_variable[2, 365] = NaN
        end
        Dict(
            "diagnostic.alpha" => first_variable,
            "diagnostic.zeta" => second_variable,
        )
    end
    historical =
        FreshReferenceAdapter.first_mimics_cn_historical_nonfinites(
            1901:2014,
            [51, 3442],
            read_year,
        )
    @test calls == [1901, 1902]
    @test getindex.(historical, "cell_id") == [51, 3442]
    @test getindex.(historical, "first_nonfinite_date") ==
          ["1901-03-31", "1902-12-31"]
    @test historical[1]["first_nonfinite_variable"] == "diagnostic.zeta"

    boundary = [
        Dict(
            "cell_id" => 51,
            "evidence_side" => "fortran",
            "first_nonfinite_date" => "2014-12-31",
            "first_nonfinite_stage" => "historical",
            "first_nonfinite_variable" => "casa_plant.c_leaf",
            "reason" => "boundary",
        ),
        Dict(
            "cell_id" => 3442,
            "evidence_side" => "fortran",
            "first_nonfinite_date" => "1920-12-31",
            "first_nonfinite_stage" => "spin",
            "first_nonfinite_variable" => "casa_plant.c_leaf",
            "reason" => "boundary",
        ),
    ]
    earliest = FreshReferenceAdapter.earliest_mimics_cn_nonfinites(
        boundary,
        historical,
    )
    @test earliest[1]["first_nonfinite_date"] == "1901-03-31"
    @test earliest[2]["first_nonfinite_stage"] == "spin"

    observer =
        FreshReferenceAdapter.mimics_cn_julia_nonfinite_observer([51, 3442])
    error = try
        observer(
            (; name = :historical, write_output = true),
            365 + 60,
            (;
                mimics_soil = (; c_microbe_r = [1.0, Inf]),
            ),
            nothing,
            ((;
                name = "diagnostic__cnpp",
                compute = (_, _) -> [2.0, 3.0],
            ),),
        )
        nothing
    catch caught
        caught
    end
    @test error isa FreshReferenceAdapter.MIMICSCNNonfiniteError
    @test only(error.records)["cell_id"] == 3442
    @test only(error.records)["evidence_side"] == "julia"
    @test only(error.records)["first_nonfinite_date"] == "1902-03-01"
    @test only(error.records)["first_nonfinite_variable"] ==
          "mimics_soil.c_microbe_r"

    mktempdir() do directory
        success = FreshReferenceAdapter.run_mimics_cn_julia(
            directory,
            (; value) -> value;
            value = :completed,
        )
        @test success.julia == :completed
        @test isempty(success.nonfinite)

        runner = (; nonfinite_observer) -> nonfinite_observer(
            (; name = :spin_continuation, write_output = false),
            365,
            (; casa_plant = (; c_leaf = [Inf, 1.0])),
            nothing,
            (),
        )
        result = FreshReferenceAdapter.run_mimics_cn_julia(
            directory,
            runner;
            nonfinite_observer =
                FreshReferenceAdapter.mimics_cn_julia_nonfinite_observer([
                    51,
                    3442,
                ]),
        )
        @test isnothing(result.julia)
        @test only(result.nonfinite)["cell_id"] == 51
        document = TOML.parsefile(
            joinpath(directory, "nonfinite_results.toml"),
        )
        @test only(document["nonfinite"])["first_nonfinite_stage"] ==
              "spin_continuation"
    end
end

@testset "Fresh-reference tracer requires an empty directory" begin
    mktempdir() do directory
        fresh = joinpath(directory, "fresh")
        @test FreshReferenceAdapter.require_empty_directory(fresh) == fresh
        @test isdir(fresh)
        write(joinpath(fresh, "stale"), "old output")
        @test_throws FreshReferenceAdapter.AdapterError FreshReferenceAdapter.require_empty_directory(
            fresh,
        )
        file = joinpath(directory, "not-a-directory")
        write(file, "file")
        @test_throws FreshReferenceAdapter.AdapterError FreshReferenceAdapter.require_empty_directory(
            file,
        )
    end
end

@testset "Fresh MIMICS-CN workflow records the shared build source" begin
    mktempdir() do directory
        path = joinpath(directory, "workflow.toml")
        open(path, "w") do io
            TOML.print(
                io,
                Dict("schema_version" => 1, "source_commit" => "archive"),
            )
        end
        FreshReferenceAdapter.pin_workflow_source!(path)
        @test TOML.parsefile(path)["source_commit"] ==
              FreshReferenceAdapter.PINNED_SOURCE_COMMIT
    end
end

@testset "CASA-C tracer is explicitly not a Representative worker" begin
    @test FreshReferenceAdapter.CASA_C_TRACER_MODEL == "CASA-C"
    @test FreshReferenceAdapter.CASA_C_TRACER_SCOPE == "one-cell-boundary"
    @test_throws FreshReferenceAdapter.AdapterError FreshReferenceAdapter.main([
        "worker",
        "CASA-C",
        "/tmp/run",
        "/tmp/build",
        abspath("../biogeochem_testbed"),
    ],)
end
