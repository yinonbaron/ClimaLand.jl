using Test
import NCDatasets
import TOML

include("snapshots.jl")
include("time_index_receipt.jl")
include("execution_receipt.jl")
include("complete_evidence.jl")
using .StageBSnapshots
using .StageBTimeIndexReceipt
using .StageBExecutionReceipt
using .CompleteStageBEvidence

function complete_snapshot(
    directory,
    transition,
    time_start,
    time_end,
    temperature,
    ice,
)
    fields = SnapshotField[]
    for (name, contract) in sort!(collect(canonical_fields()); by = first)
        values =
            contract.dtype == "int32" ? zeros(Int32, contract.shape) :
            zeros(Float64, contract.shape)
        name == "forcing.tbar" && fill!(values, temperature)
        name == "forcing.thice" && (values[1] = ice)
        name == "static.delzw" && fill!(values, 0.1)
        name == "static.zbotw" &&
            (values .= reshape(collect(0.1:0.1:2.0), 1, :))
        name == "static.zbot" && (
            values .= cumsum(
                Float64[
                    fill(0.1, 10);
                    0.2;
                    0.3;
                    0.4;
                    0.5;
                    1.0;
                    3.0;
                    5.0;
                    15.0;
                    30.0;
                    5.0
                ],
            )
        )
        name == "static.tfrez" && fill!(values, 273.16)
        name == "static.tcrit" && fill!(values, -1.0)
        name == "static.deltat" && fill!(values, 1.0)
        name in
        ("static.spinfast", "static.mineral_mask", "static.turbation_on") &&
            fill!(values, 1)
        push!(
            fields,
            snapshot_field(
                name,
                Symbol(contract.phase),
                Symbol(contract.role),
                contract.units,
                values,
            ),
        )
    end
    write_snapshot(
        directory,
        fields;
        transition,
        site = "DE-Hai",
        source_sha256 = CompleteStageBEvidence.SOURCE_SHA256,
        patch_sha256 = repeat("a", 64),
    )
    manifest_path = joinpath(directory, "manifest.toml")
    manifest = TOML.parsefile(manifest_path)
    merge!(
        manifest["snapshot"],
        Dict(
            "time_start" => time_start,
            "time_end" => time_end,
            "deltat_days" => 1,
            "source_commit" => CompleteStageBEvidence.SOURCE_COMMIT,
            "executable_sha256" => repeat("b", 64),
            "job_options_sha256" => CompleteStageBEvidence.JOB_SHA256,
            "model_parameters_sha256" =>
                CompleteStageBEvidence.PARAMETER_SHA256,
            "initialization_sha256" =>
                CompleteStageBEvidence.INITIALIZATION_SHA256,
        ),
    )
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted = true)
    end
end

function complete_daily_outputs(directory)
    mkpath(directory)
    ordinary_t = fill(274.0, 20)
    frozen_t = fill(270.0, 20)
    frozen_mass = zeros(20)
    frozen_mass[1] = 50.0
    for (filename, variable_name, units, values) in (
        ("tsl_daily.nc", "tsl", "K", vcat(ordinary_t, frozen_t)),
        ("mrsfl_daily.nc", "mrsfl", "kg m-2", vcat(zeros(20), frozen_mass)),
    )
        NCDatasets.NCDataset(joinpath(directory, filename), "c") do dataset
            NCDatasets.defDim(dataset, "lon", 1)
            NCDatasets.defDim(dataset, "lat", 1)
            NCDatasets.defDim(dataset, "layer", 20)
            NCDatasets.defDim(dataset, "time", 2)
            time = NCDatasets.defVar(dataset, "time", Float64, ("time",))
            time.attrib["units"] = "days since 1999-12-31 00:00"
            time.attrib["calendar"] = "standard"
            time[:] = [1.0, 2.0]
            variable = NCDatasets.defVar(
                dataset,
                variable_name,
                Float64,
                ("lon", "lat", "layer", "time"),
            )
            variable.attrib["units"] = units
            variable[:, :, :, :] = reshape(values, 1, 1, 20, 2)
        end
    end
end

@testset "complete evidence promotes only a fully bound transition pair" begin
    mktempdir() do directory
        ordinary = joinpath(directory, "ordinary")
        frozen = joinpath(directory, "frozen")
        output = joinpath(directory, "output")
        complete_snapshot(
            ordinary,
            "ordinary",
            "1999-12-31",
            "2000-01-01",
            274.0,
            0.0,
        )
        complete_snapshot(
            frozen,
            "frozen_soil",
            "2000-01-01",
            "2000-01-02",
            270.0,
            0.5,
        )
        complete_daily_outputs(output)

        patch = joinpath(directory, "instrumentation.patch")
        binary = joinpath(directory, "CLASSIC_serial")
        write(patch, "patch")
        write(binary, "binary")
        patch_sha = StageBSnapshots.sha256sum(patch)
        binary_sha = StageBSnapshots.sha256sum(binary)
        for snapshot in (ordinary, frozen)
            path = joinpath(snapshot, "manifest.toml")
            manifest = TOML.parsefile(path)
            manifest["snapshot"]["patch_sha256"] = patch_sha
            manifest["snapshot"]["executable_sha256"] = binary_sha
            open(path, "w") do io
                TOML.print(io, manifest; sorted = true)
            end
        end

        generator = joinpath(directory, "generator.toml")
        open(generator, "w") do io
            TOML.print(
                io,
                Dict(
                    "status" => "generated",
                    "pre_resp_transfer_capture" => "measured_at_process_calls",
                    "patch_path" => basename(patch),
                    "patch_sha256" => patch_sha,
                );
                sorted = true,
            )
        end
        for filename in (
            "pristine-comparison.log",
            "pristine-output.sha256",
            "instrumented-output.sha256",
        )
            write(joinpath(directory, filename), filename)
        end
        comparison = joinpath(directory, "comparison.toml")
        open(comparison, "w") do io
            TOML.print(
                io,
                Dict(
                    "result" => "pass",
                    "criteria" => CompleteStageBEvidence.EXACT_CRITERIA,
                    "compared_files" => 57,
                    "failed_files" => 0,
                    "record_count_per_daily_file" => 4749,
                    "comparison_log_sha256" => StageBSnapshots.sha256sum(
                        joinpath(directory, "pristine-comparison.log"),
                    ),
                    "reference_output_manifest_sha256" =>
                        StageBSnapshots.sha256sum(
                            joinpath(directory, "pristine-output.sha256"),
                        ),
                    "candidate_output_manifest_sha256" =>
                        StageBSnapshots.sha256sum(
                            joinpath(directory, "instrumented-output.sha256"),
                        ),
                    "instrumentation_patch_sha256" => patch_sha,
                    "instrumented_executable_sha256" => binary_sha,
                    "job_options_sha256" => CompleteStageBEvidence.JOB_SHA256,
                    "model_parameters_sha256" =>
                        CompleteStageBEvidence.PARAMETER_SHA256,
                    "initialization_sha256" =>
                        CompleteStageBEvidence.INITIALIZATION_SHA256,
                );
                sorted = true,
            )
        end
        time_index = joinpath(directory, "time-index.toml")
        record_time_index_receipt(time_index, ordinary, frozen, output)

        source = joinpath(directory, "source.tar.gz")
        container = joinpath(directory, "container.tar.gz")
        sif = joinpath(directory, "container.sif")
        makefile = joinpath(directory, "Makefile")
        forcing = joinpath(directory, "forcing.nc")
        job_options = joinpath(directory, "job_options_file.txt")
        foreach(
            path -> write(path, basename(path)),
            (source, container, sif, makefile, forcing),
        )
        write(
            job_options,
            """
PFTCompetition = .false.,
lnduseon = .false.,
timberHarvest = .false.,
dofire = .false.,
prescribedFire = .false.,
""",
        )
        toolchain = joinpath(directory, "toolchain.log")
        build = joinpath(directory, "make.log")
        write(toolchain, "GNU Fortran (GCC) 12.2.0\n")
        write(
            build,
            "gfortran -O3 -fdefault-real-8 -ffree-line-length-none -fbacktrace -ffpe-trap=invalid,zero,overflow -fbounds-check\n",
        )
        execution = joinpath(directory, "execution.toml")
        record_execution_receipt(
            execution,
            source,
            container,
            sif,
            toolchain,
            build,
            makefile,
            binary,
            patch,
            [forcing, job_options],
        )

        receipt = joinpath(directory, "complete.toml")
        promoted = promote_complete_receipt(
            receipt,
            ordinary,
            frozen,
            comparison,
            generator,
            time_index,
            output,
            execution,
        )
        @test promoted["status"] == "complete"
        @test verify_complete_evidence(
            ordinary,
            frozen,
            comparison,
            generator,
            time_index,
            output,
            execution;
            complete_receipt_path = receipt,
        ).ok

        write(forcing, "tampered")
        report = verify_complete_evidence(
            ordinary,
            frozen,
            comparison,
            generator,
            time_index,
            output,
            execution;
            complete_receipt_path = receipt,
        )
        @test !report.ok
        @test "execution: forcing input 1 hash differs" in report.issues
    end
end
