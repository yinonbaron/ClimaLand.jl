using Test
import TOML

import NCDatasets

if !isdefined(@__MODULE__, :TestbedCASAFreshWorker)
    include(joinpath(@__DIR__, "casa_fresh_worker.jl"))
end

const CASAFreshWorker = TestbedCASAFreshWorker

function synthetic_representative_fixture(directory)
    scope_path = joinpath(directory, "representative.toml")
    open(scope_path, "w") do io
        TOML.print(
            io,
            Dict(
                "schema_version" => 1,
                "name" => "representative",
                "cell_ids" => collect(1:80),
            );
            sorted = true,
        )
    end
    marker = joinpath(directory, "forcing.bin")
    write(marker, "synthetic forcing marker")
    fixture_path = joinpath(directory, "fixture.toml")
    fixture = Dict(
        "schema_version" => 1,
        "selection" => Dict(
            "representative_cell_ids" => collect(1:80),
            "scope_manifest_sha256" =>
                TestbedNativeWorkflow.sha256sum(scope_path),
        ),
        "fixture" => Dict(
            "forcing" => Dict(
                "filename" => basename(marker),
                "bytes" => filesize(marker),
                "sha256" => TestbedNativeWorkflow.sha256sum(marker),
            ),
        ),
        "cell" => [
            Dict("id" => id, "pft" => 1, "reasons" => ["synthetic"]) for
            id in 1:80
        ],
    )
    open(fixture_path, "w") do io
        TOML.print(io, fixture; sorted = true)
    end
    return (; fixture_path, scope_path)
end

function stub_casa_workflow(configuration, _, collection, run_root)
    @test configuration == :carbon_only
    @test getproperty.(collection.cells, :id) == collect(1:80)
    controls = joinpath(run_root, "configuration", "controls")
    mkpath(controls)
    stages = Dict{String, Any}[]
    for stage in ("prespin", "accelerated_spin", "normal_spin", "historical")
        control = TestbedReferenceHarness.write_smoke_control(controls; points = 80)
        destination = joinpath(controls, "$stage.lst")
        mv(control, destination; force = true)
        push!(
            stages,
            Dict(
                "name" => stage,
                "control" => joinpath("controls", "$stage.lst"),
                "outputs" => ["casa_final.csv", "casa_flux_final.csv"],
                "input" => Dict{String, Any}[],
            ),
        )
    end
    path = joinpath(run_root, "configuration", "workflow.toml")
    TestbedReferenceHarness.write_toml_atomic(
        path,
        Dict(
            "schema_version" => 1,
            "name" => "synthetic-casa-fresh-worker",
            "source_commit" => CASAFreshWorker.PINNED_SOURCE_COMMIT,
            "stage" => stages,
        ),
    )
    return (; workflow_path = path, stage_hook = nothing)
end

function synthetic_finish(passed)
    return function (
        _configuration,
        _fixture,
        _scope,
        _fortran_root,
        julia_root,
        _reference;
        build_metadata_path,
        oracle_path,
    )
        @test isfile(build_metadata_path)
        mkpath(julia_root)
        write(oracle_path, "synthetic oracle")
        report = joinpath(julia_root, "reconstruction_report.toml")
        document = Dict(
            "schema_version" => 1,
            "initialization_comparison" => Dict("all_match" => true),
            "boundary_comparison" => Dict(
                stage => Dict("all_match" => true) for stage in
                ("prespin", "accelerated_spin", "normal_spin", "historical")
            ),
            "historical_comparison" => Dict("all_match" => true),
            "passive_restoration" => Dict(
                "verified" => true,
                "unaffected_verified" => true,
                "checkpoint_roundtrip_verified" => true,
            ),
            "carbon_budget" => Dict("all_close" => passed),
        )
        open(report, "w") do io
            TOML.print(io, document; sorted = true)
        end
        return (
            oracle_path,
            julia = (; report),
            report_path = report,
            nonfinite_records = Dict{String, Any}[],
        )
    end
end

@testset "CASA fresh worker invokes one verified shared executable" begin
    mktempdir() do directory
        fixture = synthetic_representative_fixture(directory)
        build = joinpath(directory, "build")
        mkpath(build)
        audit = joinpath(directory, "executions.log")
        executable = joinpath(build, "synthetic-fortran")
        write(
            executable,
            "#!/bin/sh\nprintf '%s\\n' \"\$PWD\" >> $(repr(audit))\nprintf 'ijcam,casapool%%clabile\\n1,1.0\\n' > casa_final.csv\nprintf 'flux\\n1.0\\n' > casa_flux_final.csv\n",
        )
        chmod(executable, 0o755)
        TestbedReferenceHarness.write_toml_atomic(
            joinpath(build, "build_metadata.toml"),
            Dict(
                "schema_version" => 1,
                "verified" => true,
                "verification" => Dict(
                    "executable" => basename(executable),
                    "executable_sha256" =>
                        TestbedNativeWorkflow.sha256sum(executable),
                    "source_commit" => CASAFreshWorker.PINNED_SOURCE_COMMIT,
                    "source_code_clean" => true,
                ),
            ),
        )
        reference = joinpath(directory, "reference.toml")
        open(reference, "w") do io
            TOML.print(
                io,
                Dict(
                    "schema_version" => 1,
                    "tier" => "representative",
                    "cell_ids" => collect(1:80),
                    "configuration" =>
                        Dict("carbon_only" => Dict{String, Any}()),
                );
                sorted = true,
            )
        end
        source = joinpath(directory, "source")
        mkpath(source)

        passed = CASAFreshWorker.run_worker(
            "CASA-C",
            source,
            dirname(fixture.fixture_path),
            reference,
            joinpath(directory, "passed"),
            build;
            scope_manifest_path = fixture.scope_path,
            workflow_writer = stub_casa_workflow,
            finisher = synthetic_finish(true),
        )

        @test length(readlines(audit)) == 4
        @test passed.comparison.passed
        @test CASAFreshWorker.worker_exit_code(passed) == 0
        @test isfile(joinpath(directory, "passed", "fortran_output.toml"))
        @test isfile(joinpath(directory, "passed", "julia_output.toml"))
        @test TOML.parsefile(joinpath(directory, "passed", "comparison.toml"))["outcome"] ==
              "passed"

        failed = CASAFreshWorker.run_worker(
            "CASA-C",
            source,
            dirname(fixture.fixture_path),
            reference,
            joinpath(directory, "failed"),
            build;
            scope_manifest_path = fixture.scope_path,
            workflow_writer = stub_casa_workflow,
            finisher = synthetic_finish(false),
        )
        @test !failed.comparison.passed
        @test CASAFreshWorker.worker_exit_code(failed) == 1
        @test TOML.parsefile(joinpath(directory, "failed", "comparison.toml"))["outcome"] ==
              "failed"
    end
end

@testset "CASA fresh worker preserves structured nonfinite evidence" begin
    record = Dict(
        "cell_id" => 51,
        "evidence_side" => "fortran",
        "first_nonfinite_stage" => "historical",
        "first_nonfinite_date" => "2014-12-31",
        "first_nonfinite_variable" => "casa_plant.c_leaf",
        "reason" => "synthetic",
    )
    mktempdir() do directory
        path = CASAFreshWorker.write_nonfinite_results(
            directory,
            "CASA-CN",
            [record],
        )
        @test TOML.parsefile(path)["nonfinite"] == [record]
    end
end

@testset "CASA fresh worker stage contract covers C and CN" begin
    carbon = CASAFreshWorker.stage_specs(:carbon_only)
    nitrogen = CASAFreshWorker.stage_specs(:carbon_nitrogen)
    @test getproperty.(carbon, :name) ==
          ("prespin", "accelerated_spin", "normal_spin", "historical")
    @test getproperty.(carbon, :initialization) == (0, 3, 3, 2)
    @test getproperty.(nitrogen, :initialization) == (0, 3, 3, 2)
    @test !last(carbon).daily
    @test last(nitrogen).daily
    @test CASAFreshWorker.model_configuration("CASA-C") == :carbon_only
    @test CASAFreshWorker.model_configuration("CASA-CN") == :carbon_nitrogen
    @test_throws ArgumentError CASAFreshWorker.model_configuration("MIMICS-C")
    @test CASAFreshWorker.main(
        fill("argument", 6);
        runner = (args...) -> (;
            nonfinite = Dict{String, Any}[],
            comparison = (; passed = true),
        ),
    ) == 0
    @test CASAFreshWorker.main(
        fill("argument", 6);
        runner = (args...) -> (;
            nonfinite = Dict{String, Any}[],
            comparison = (; passed = false),
        ),
    ) == 1
    @test_throws ErrorException CASAFreshWorker.main(String[])
end

@testset "CASA-CN fresh worker reduces one-cell daily output" begin
    mktempdir() do directory
        daily = joinpath(directory, CASAFreshWorker.daily_name(1901))
        NCDatasets.NCDataset(daily, "c"; format = :netcdf4) do output
            NCDatasets.defDim(output, "lon", 1)
            NCDatasets.defDim(output, "lat", 1)
            NCDatasets.defDim(output, "time", 365)
            cellid = NCDatasets.defVar(output, "cellid", Int32, ("lon", "lat"))
            cellid[:, :] .= 51
            for (reference_name, _) in
                TestbedNativeCASACNReconstruction.historical_variables()
                reference_name == "nLitInptStruc" && continue
                variable = NCDatasets.defVar(
                    output,
                    reference_name,
                    Float64,
                    ("lon", "lat", "time"),
                )
                variable[:, :, :] .= 2.0
            end
        end
        annual = joinpath(directory, CASAFreshWorker.ANNUAL_FILENAME)

        CASAFreshWorker.write_annual_year!(annual, daily, 1901)

        NCDatasets.NCDataset(annual) do output
            @test output.dim["time"] == 114
            @test vec(output["cellid"][:, :]) == [51]
            @test output["cleaf"][1, 1, 1] == 2.0
            @test output["cgpp"][1, 1, 1] == 2.0
        end
    end
end
