using Test
import SHA
import TOML
import ClimaCore
import NCDatasets

include(joinpath(@__DIR__, "fresh_reference_adapter.jl"))
const FreshReferenceAdapter = TestbedFreshReferenceAdapter

function observer_cost(observer, stage, state, parameters, diagnostics, steps)
    observer(stage, 1, state, parameters, diagnostics)
    GC.gc(false)
    bytes = Base.@allocated for step in 2:(steps + 1)
        state.casa_plant.c_leaf[1] = step
        observer(stage, step, state, parameters, diagnostics)
    end
    seconds = @elapsed for step in 2:(steps + 1)
        state.casa_plant.c_leaf[1] = step
        observer(stage, step, state, parameters, diagnostics)
    end
    return (; bytes, seconds)
end

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
        "MIMICS-C",
    ])
    @test_throws FreshReferenceAdapter.AdapterError commands.preflight([
        "MIMICS-CN",
    ])
    @test_throws FreshReferenceAdapter.AdapterError commands.preflight([
        "CORPSE",
    ])
    configured = FreshReferenceAdapter.commands(
        "../biogeochem_testbed";
        casa_forcing_root = "/tmp/casa-forcing",
        casa_c_reference_template = "/tmp/casa-c-reference-template",
        casa_cn_reference_template = "/tmp/casa-cn-reference-template",
        corpse_forcing_root = "/tmp/corpse-forcing",
        mimics_c_forcing_root = "/tmp/forcing",
        mimics_cn_forcing_root = "/tmp/forcing",
        mimics_cn_reference_template = "/tmp/reference-template",
    )
    @test isnothing(configured.preflight(["CASA-C"]))
    @test isnothing(configured.preflight(["CASA-CN"]))
    @test isnothing(configured.preflight(["MIMICS-CN"]))
    @test isnothing(configured.preflight(["MIMICS-C"]))
    @test isnothing(configured.preflight(["CORPSE"]))
    casa_c =
        configured.worker("CASA-C", "/tmp/fresh-casa-c", "/tmp/fresh-build")
    @test "/tmp/casa-forcing" in casa_c.exec
    @test "/tmp/casa-c-reference-template" in casa_c.exec
    @test !("/tmp/casa-cn-reference-template" in casa_c.exec)
    casa_cn = configured.worker(
        "CASA-CN",
        "/tmp/fresh-casa-cn",
        "/tmp/fresh-build",
    )
    @test "/tmp/casa-forcing" in casa_cn.exec
    @test "/tmp/casa-cn-reference-template" in casa_cn.exec
    @test !("/tmp/casa-c-reference-template" in casa_cn.exec)
    mimics_c = configured.worker(
        "MIMICS-C",
        "/tmp/fresh-mimics-c",
        "/tmp/fresh-build",
    )
    @test "worker" in mimics_c.exec
    @test "/tmp/forcing" in mimics_c.exec
    mimics_cn = configured.worker(
        "MIMICS-CN",
        "/tmp/fresh-mimics-cn",
        "/tmp/fresh-build",
    )
    @test "worker" in mimics_cn.exec
    @test "/tmp/forcing" in mimics_cn.exec
    @test "/tmp/reference-template" in mimics_cn.exec
    corpse = configured.worker(
        "CORPSE",
        "/tmp/fresh-corpse",
        "/tmp/fresh-build",
    )
    @test "worker" in corpse.exec
    @test "/tmp/corpse-forcing" in corpse.exec
end

@testset "Fresh model capabilities are complete" begin
    @test isempty(FreshReferenceAdapter.MISSING_MODEL_COMMANDS)
    @test Set(keys(FreshReferenceAdapter.MODEL_CAPABILITIES)) ==
          Set(FreshReferenceAdapter.ModelProcesses.MODELS)
    for model in FreshReferenceAdapter.ModelProcesses.MODELS
        capability = FreshReferenceAdapter.model_capability(model)
        @test isfile(capability.runner)
        @test capability.representative_ready
        @test isempty(capability.blocker)
        @test FreshReferenceAdapter.require_model_command(model) == capability
    end
    mimics_cn = FreshReferenceAdapter.model_capability("MIMICS-CN")
    @test mimics_cn.deepest_scope == "representative"
    @test mimics_cn.shared_build
    @test mimics_cn.completed_phases ==
          ("fortran", "julia", "comparison", "eligibility_gap_proposal")
    mimics_c = FreshReferenceAdapter.model_capability("MIMICS-C")
    @test mimics_c.deepest_scope == "representative"
    @test mimics_c.shared_build
    @test mimics_c.completed_phases == mimics_cn.completed_phases
    for model in ("CASA-C", "CASA-CN")
        casa = FreshReferenceAdapter.model_capability(model)
        @test casa.deepest_scope == "representative"
        @test casa.shared_build
        @test casa.completed_phases == mimics_cn.completed_phases
    end
    corpse = FreshReferenceAdapter.model_capability("CORPSE")
    @test corpse.deepest_scope == "representative"
    @test corpse.shared_build
    @test corpse.completed_phases == mimics_cn.completed_phases
    status = FreshReferenceAdapter.status_document()
    @test status["representative_workers_ready"] === true
    @test Set(keys(status["model"])) ==
          Set(FreshReferenceAdapter.ModelProcesses.MODELS)
end

@testset "Fresh CORPSE command wires every real bridge" begin
    captured = Ref{Any}()
    worker_runner = function (
        source_root,
        fixture_manifest,
        run_directory,
        build_directory;
        kwargs...,
    )
        captured[] = (;
            source_root,
            fixture_manifest,
            run_directory,
            build_directory,
            kwargs...,
        )
        return (; status = :passed)
    end
    result = FreshReferenceAdapter.run_corpse_80(
        "/tmp/source",
        "/tmp/corpse-forcing",
        "/tmp/corpse-run",
        "/tmp/shared-build";
        worker_runner,
    )
    @test result.status == :passed
    @test captured[].fixture_manifest == "/tmp/corpse-forcing/fixture.toml"
    @test captured[].scope_manifest == FreshReferenceAdapter.REPRESENTATIVE_SCOPE
    @test captured[].calibration_manifest ==
          FreshReferenceAdapter.CORPSE_CALIBRATION
    @test captured[].executable_resolver === FreshReferenceAdapter.verified_executable
    @test captured[].fortran_runner isa Function
    @test captured[].reference_reducer isa Function
    @test captured[].payload_builder isa Function
    @test captured[].julia_runner isa Function
    modules = FreshReferenceAdapter.corpse_modules()
    @test nameof(modules.worker) == :TestbedCORPSEFreshWorker
    @test nameof(modules.fortran) == :TestbedRepresentativeCORPSEFortran
    @test nameof(modules.julia) == :TestbedCORPSEFreshJuliaExecutor
    @test_throws FreshReferenceAdapter.AdapterError FreshReferenceAdapter.main([
        "worker",
        "CORPSE",
        "/tmp/run",
        "/tmp/build",
        "/tmp/source",
    ])
end

@testset "Fresh MIMICS-C worker comparison and nonfinite contracts" begin
    mktempdir() do directory
        oracle = joinpath(directory, "oracle.toml")
        write(oracle, "model = \"MIMICS-C\"\n")
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
                        stage => Dict("all_match" => true) for
                        stage in ("prespin", "spin", "historical")
                    ),
                    "historical_comparison" => Dict("all_match" => true),
                    "carbon_budget" => Dict("all_close" => true),
                );
                sorted = true,
            )
        end
        comparison = FreshReferenceAdapter.write_mimics_c_comparison(
            directory,
            scientific,
            oracle,
        )
        @test comparison.passed
        report = TOML.parsefile(comparison.path)
        @test report["model"] == "MIMICS-C"
        @test report["outcome"] == "passed"

        boundaries = Dict(
            "prespin" => Dict("casa_plant.c_leaf" => [1.0, 2.0]),
            "spin" => Dict("casa_plant.c_leaf" => [Inf, 2.0]),
            "historical" =>
                Dict("mimics_soil.c_microbe_r" => [Inf, -Inf]),
        )
        boundary = FreshReferenceAdapter.first_mimics_c_boundary_nonfinites(
            boundaries,
            [51, 3442],
        )
        @test getindex.(boundary, "first_nonfinite_stage") ==
              ["spin", "historical"]

        read_year = year -> begin
            values = zeros(2, 365)
            year == 1901 && (values[2, 60] = Inf)
            Dict("diagnostic.cnpp" => values)
        end
        historical =
            FreshReferenceAdapter.first_mimics_c_historical_nonfinites(
                1901:1901,
                [51, 3442],
                read_year,
            )
        @test only(historical)["first_nonfinite_date"] == "1901-03-01"
        earliest = FreshReferenceAdapter.earliest_mimics_c_nonfinites(
            boundary,
            historical,
        )
        @test earliest[2]["first_nonfinite_date"] == "1901-03-01"

        observer =
            FreshReferenceAdapter.mimics_c_julia_nonfinite_observer([51, 3442])
        runner = (; nonfinite_observer) -> nonfinite_observer(
            (; name = :historical),
            365 + 60,
            (; mimics_soil = (; c_microbe_r = [1.0, Inf])),
            nothing,
            (),
        )
        result = FreshReferenceAdapter.run_mimics_c_julia(
            directory,
            runner;
            nonfinite_observer = observer,
        )
        @test isnothing(result.julia)
        @test only(result.nonfinite)["evidence_side"] == "julia"
        @test only(result.nonfinite)["first_nonfinite_date"] == "1902-03-01"
        proposal_input = TOML.parsefile(
            joinpath(directory, "nonfinite_results.toml"),
        )
        @test proposal_input["model"] == "MIMICS-C"
        @test only(proposal_input["nonfinite"])["cell_id"] == 3442
    end
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

@testset "Fresh MIMICS finite observers are allocation-free" begin
    state = ClimaCore.Fields.FieldVector(;
        casa_plant = (; c_leaf = fill(1.0, 80)),
        mimics_soil = (; c_microbe_r = fill(2.0, 80)),
    )
    diagnostics = ((;
        name = "diagnostic__cnpp",
        compute = (Y, _) -> Y.casa_plant.c_leaf,
    ),)
    stage = (; name = :historical, write_output = true)
    for factory in (
        FreshReferenceAdapter.mimics_c_julia_nonfinite_observer,
        FreshReferenceAdapter.mimics_cn_julia_nonfinite_observer,
    )
        cost = observer_cost(
            factory(collect(1:80)),
            stage,
            state,
            nothing,
            diagnostics,
            10_000,
        )
        @test cost.bytes == 0
        @test cost.seconds < 1.0
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

@testset "CASA-C tracer rejects unsafe comparison selectors" begin
    cases = (
        (
            "reference_time_start",
            "1; error(\"injected\")",
            "reference_time_start",
        ),
        ("reference_time_start", 1.0, "reference_time_start"),
        ("reference_time_start", true, "reference_time_start"),
        ("reference_time_start", 0, "reference_time_start"),
        ("reference_time_stop", 0, "reference time range"),
        ("reference_time_stop", 10_001, "reference time range"),
        ("candidate_time_offset", 10_001, "candidate_time_offset"),
        ("candidate_time_offset", typemin(Int), "candidate_time_offset"),
    )
    for (key, value, expected_message) in cases
        mktempdir() do directory
            fixture = joinpath(directory, "fixture")
            mkpath(fixture)
            manifest = Dict(
                "schema_version" => 1,
                "generation" => Dict("roundtrip_exact" => true),
                "fixture" => Dict{String, Any}(),
                "comparison" => Dict{String, Any}(
                    "reference_time_start" => 1,
                    "reference_time_stop" => 365,
                    "candidate_time_offset" => 1900,
                ),
            )
            manifest["comparison"][key] = value
            open(joinpath(fixture, "fixture.toml"), "w") do io
                TOML.print(io, manifest; sorted = true)
            end

            error = try
                FreshReferenceAdapter.main([
                    "trace-casa-c",
                    joinpath(directory, "source"),
                    joinpath(directory, "run"),
                    joinpath(directory, "build"),
                    fixture,
                ])
                nothing
            catch caught
                caught
            end

            @test error isa FreshReferenceAdapter.AdapterError
            @test occursin(expected_message, sprint(showerror, error))
            @test !ispath(joinpath(directory, "injected"))
        end
    end
end

@testset "CASA-C tracer comparison uses structured arguments" begin
    mktempdir() do directory
        reference = joinpath(directory, "reference.nc")
        candidate = joinpath(directory, "candidate.nc")
        for path in (reference, candidate)
            NCDatasets.NCDataset(path, "c") do dataset
                NCDatasets.defDim(dataset, "time", 2)
                time = NCDatasets.defVar(dataset, "time", Int, ("time",))
                time[:] = [1, 2]
            end
        end
        report = joinpath(directory, "comparison.toml")

        @test FreshReferenceAdapter.compare_casa_c_tracer(
            reference,
            candidate,
            report,
            (; start = 1, stop = 2, offset = 0),
        )
        @test TOML.parsefile(report)["outcome"] == "passed"
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

@testset "CASA-C tracer remains separate from the Representative worker" begin
    @test FreshReferenceAdapter.CASA_C_TRACER_MODEL == "CASA-C"
    @test FreshReferenceAdapter.CASA_C_TRACER_SCOPE == "one-cell-boundary"
    @test nameof(FreshReferenceAdapter.casa_modules()) ==
          :TestbedCASAFreshWorker
    @test_throws FreshReferenceAdapter.AdapterError FreshReferenceAdapter.main([
        "worker",
        "CASA-C",
        "/tmp/run",
        "/tmp/build",
        abspath("../biogeochem_testbed"),
    ],)
end
