using Dates
using Test
import NCDatasets
import TOML

include("site_execution.jl")
using .ClassicSiteExecution: execute_site!, sha256_file

const SITE = "AA-One"

function write_daily_file(path, variable_name, values)
    NCDatasets.NCDataset(path, "c") do dataset
        NCDatasets.defDim(dataset, "lon", 1)
        NCDatasets.defDim(dataset, "lat", 1)
        NCDatasets.defDim(dataset, "time", length(values))
        longitude = NCDatasets.defVar(dataset, "longitude", Float64, ("lon",))
        longitude.attrib["units"] = "degrees_east"
        longitude[:] = [10.0]
        latitude = NCDatasets.defVar(dataset, "latitude", Float64, ("lat",))
        latitude.attrib["units"] = "degrees_north"
        latitude[:] = [51.0]
        time = NCDatasets.defVar(dataset, "time", Float64, ("time",))
        time.attrib["units"] = "days since 2000-12-31 00:00"
        time.attrib["calendar"] = "standard"
        time[:] = collect(values)
        variable = NCDatasets.defVar(
            dataset,
            variable_name,
            Float64,
            ("lon", "lat", "time"),
        )
        variable.attrib["units"] = "1"
        variable.attrib["coordinates"] = "longitude latitude"
        variable[:, :, :] = reshape(Float64.(values), 1, 1, :)
    end
end

function write_oracle(root; run_end_year = 2001)
    site_root = joinpath(root, SITE)
    netcdf_root = joinpath(root, "outputFiles", SITE, "netCDF")
    evidence_root = joinpath(root, "site-evidence", SITE)
    mkpath.((site_root, netcdf_root, evidence_root))
    job_options = joinpath(site_root, "job_options_file.txt")
    write(
        job_options,
        """
        &joboptions
        runStartYear = 2001,
        runEndYear = $run_end_year,
        init_file = '/work_zone/run_tmp/$SITE/$(SITE)_init.nc',
        rs_file_to_overwrite = '/work_zone/run_tmp/$SITE/rsfile.nc',
        runparams_file = '/work_zone/run_tmp/model_params.nml',
        output_directory = '/work_zone/run_tmp/outputFiles/$SITE/netCDF',
        /
        """,
    )
    initialization = joinpath(site_root, "$(SITE)_init.nc")
    write(initialization, "initial condition")
    for index in 1:57
        name = index == 1 ? "tsl" : "v$(lpad(index, 2, '0'))"
        filename = "$(name)_daily.nc"
        values = 1:365
        if index == 57
            name = "sftlf"
            filename = "sftlf.nc"
            values = 1:1
        end
        write_daily_file(joinpath(netcdf_root, filename), name, values)
    end
    receipt = Dict(
        "schema_version" => 1,
        "site" => SITE,
        "local_oracle_status" => "available",
        "run_exit_code" => 0,
        "evidence_sha256" => Dict(
            "job_options_file.txt" => sha256_file(job_options),
            "$(SITE)_init.nc" => sha256_file(initialization),
        ),
    )
    receipt_path = joinpath(evidence_root, "receipt.toml")
    open(receipt_path, "w") do io
        TOML.print(io, receipt; sorted = true)
    end
    return (; site_root, netcdf_root, receipt_path)
end

function test_config(root, oracle_root)
    source_root = joinpath(root, "promoted-source")
    executable = joinpath(source_root, "bin", "CLASSIC_serial")
    container = joinpath(source_root, "tools", "CLASSIC.sif")
    parameters = joinpath(root, "model_params.nml")
    mkpath.(dirname.((executable, container)))
    write(executable, "executable")
    chmod(executable, 0o755)
    write(container, "container")
    write(parameters, "parameters")
    return (
        promoted_source_root = source_root,
        oracle_root,
        parameter_namelist_path = parameters,
        executable_path = executable,
        container_path = container,
        max_events = 365,
        source_archive_sha256 = repeat("a", 64),
        source_tree_sha256 = repeat("b", 64),
        source_commit = repeat("c", 40),
        instrumentation_patch_sha256 = repeat("d", 64),
        snapshot_schema_sha256 = repeat("e", 64),
    )
end

function fake_capture(
    workspace,
    oracle_netcdf_root;
    semantic_error = false,
    run_end_year = 2001,
)
    function capture(_)
        run_root = joinpath(workspace, "run")
        netcdf_root = joinpath(run_root, "outputFiles", SITE, "netCDF")
        @test isdir(netcdf_root)
        for name in readdir(oracle_netcdf_root)
            cp(joinpath(oracle_netcdf_root, name), joinpath(netcdf_root, name))
        end
        daily = joinpath(run_root, "stage_b_snapshots", "daily")
        mkpath(daily)
        ledger = joinpath(daily, "event_ledger.raw")
        open(ledger, "w") do io
            println(
                io,
                "schema_version=1 capture_mode=all_daily max_events=365",
            )
            for index in 1:365
                event = "event_$(lpad(index, 8, '0')).raw"
                event_root = joinpath(daily, event)
                mkpath(event_root)
                for field in 1:66
                    stem = "field_$(lpad(field, 2, '0'))"
                    for extension in (".bin", ".shape")
                        write(joinpath(event_root, stem * extension), "")
                    end
                end
                println(io, "$index $index daily/$event")
            end
            println(io, "capture_complete events=365 max_events=365")
        end
        log_path = joinpath(workspace, "execution_evidence", "run.log")
        open(log_path, "a") do io
            semantic_error && println(io, "NetCDF: HDF error")
            println(
                io,
                " done: met year =         $run_end_year  runyr =         $run_end_year",
            )
        end
        return (; exit_code = 0)
    end
    return capture
end

@testset "site execution prepares, bounds, compares, and binds evidence" begin
    mktempdir() do root
        oracle_root = joinpath(root, "oracle")
        oracle = write_oracle(oracle_root)
        config = test_config(root, oracle_root)
        source_alias = joinpath(root, "promoted-source-alias")
        symlink(config.promoted_source_root, source_alias)
        config = merge(
            config,
            (
                promoted_source_root = source_alias,
                executable_path = joinpath(
                    source_alias,
                    "bin",
                    "CLASSIC_serial",
                ),
                container_path = joinpath(source_alias, "tools", "CLASSIC.sif"),
            ),
        )

        outside_root = joinpath(root, "outside-source")
        mkpath(outside_root)
        outside_executable = joinpath(outside_root, "CLASSIC_serial")
        write(outside_executable, "executable")
        escape_alias = joinpath(config.promoted_source_root, "escaped-source")
        symlink(outside_root, escape_alias)
        escaped_config = merge(
            config,
            (; executable_path = joinpath(escape_alias, "CLASSIC_serial")),
        )
        escape_error = try
            execute_site!(
                SITE,
                joinpath(root, "escape"),
                escaped_config;
                command_runner = _ -> error("escaped executable was run"),
            )
            nothing
        catch exception
            exception
        end
        @test escape_error isa ArgumentError
        @test occursin(
            "outside promoted source",
            sprint(showerror, escape_error),
        )

        workspace = joinpath(root, "success")
        result = execute_site!(
            SITE,
            workspace,
            config;
            command_runner = fake_capture(workspace, oracle.netcdf_root),
        )
        expected_keys = Set((
            :site,
            :run_root,
            :site_root,
            :raw_root,
            :netcdf_root,
            :oracle_netcdf_root,
            :job_options_path,
            :initial_condition_path,
            :execution_receipt_path,
            :nonperturbation_receipt_path,
            :command_path,
            :run_log_path,
            :resource_time_path,
            :oracle_manifest_path,
            :oracle_receipt_path,
            :oracle_time_path,
            :oracle_time_file_sha256,
            :oracle_time_sha256,
            :capture_year,
            :capture_source_calendar,
            :capture_first_time,
            :capture_last_time,
            :capture_next_year_start,
            :event_count,
            :record_count_per_daily_file,
        ))
        @test Set(propertynames(result)) == expected_keys
        @test result.event_count == 365
        @test result.record_count_per_daily_file == 365
        @test sha256_file(result.job_options_path) ==
              sha256_file(joinpath(oracle.site_root, "job_options_file.txt"))
        @test sha256_file(result.initial_condition_path) ==
              sha256_file(joinpath(oracle.site_root, "$(SITE)_init.nc"))
        @test TOML.parsefile(result.execution_receipt_path)["status"] == "pass"
        comparison = TOML.parsefile(result.nonperturbation_receipt_path)
        @test comparison["status"] == "pass"
        @test comparison["compared_files"] == 57
        @test comparison["failed_files"] == 0
        command = read(result.command_path, String)
        @test occursin("CLASSIC_STAGE_B_CAPTURE_MAX_EVENTS=365", command)
        @test occursin("CLASSIC_STAGE_B_CAPTURE_MODE=all_daily", command)
        @test occursin(
            "CLASSIC_STAGE_B_SNAPSHOT_ROOT=/work_zone/run_tmp/stage_b_snapshots",
            command,
        )
        @test !occursin("CLASSIC_STAGE_B_CAPTURE_ROOT", command)

        failed_workspace = joinpath(root, "semantic-failure")
        error = try
            execute_site!(
                SITE,
                failed_workspace,
                config;
                command_runner = fake_capture(
                    failed_workspace,
                    oracle.netcdf_root;
                    semantic_error = true,
                ),
            )
            nothing
        catch exception
            exception
        end
        @test error isa ArgumentError
        @test occursin("semantic", sprint(showerror, error))
        failed_receipt = TOML.parsefile(
            joinpath(
                failed_workspace,
                "execution_evidence",
                "execution_receipt.toml",
            ),
        )
        @test failed_receipt["status"] == "failed"
        @test any(
            occursin("NetCDF", issue) for issue in failed_receipt["issue"]
        )
    end
end

@testset "capture bound follows oracle first year, not run-end leap status" begin
    mktempdir() do root
        oracle_root = joinpath(root, "oracle")
        oracle = write_oracle(oracle_root; run_end_year = 2004)
        config = test_config(root, oracle_root)
        workspace = joinpath(root, "first-year-cycle")

        result = execute_site!(
            SITE,
            workspace,
            config;
            command_runner = fake_capture(
                workspace,
                oracle.netcdf_root;
                run_end_year = 2004,
            ),
        )

        @test result.capture_year == 2001
        @test result.event_count == 365
        @test result.oracle_time_file_sha256 ==
              sha256_file(joinpath(oracle.netcdf_root, "tsl_daily.nc"))
        receipt = TOML.parsefile(result.execution_receipt_path)
        @test receipt["capture_year"] == 2001
        @test receipt["capture_event_count"] == 365
        @test receipt["oracle_daily_time_sha256"] == result.oracle_time_sha256
        @test receipt["oracle_daily_time_file_sha256"] ==
              result.oracle_time_file_sha256
    end
end

@testset "semantic time hash ignores encoding and detects timestamp changes" begin
    mktempdir() do root
        first_path = joinpath(root, "first.nc")
        encoded_path = joinpath(root, "encoded.nc")
        changed_path = joinpath(root, "changed.nc")
        write_daily_file(first_path, "tsl", 1:3)
        write_daily_file(encoded_path, "tsl", 1:3)
        NCDatasets.NCDataset(encoded_path, "a") do dataset
            dataset.attrib["encoding_note"] = "different container bytes"
        end
        write_daily_file(changed_path, "tsl", [1, 2, 4])

        function signature(path)
            return NCDatasets.NCDataset(path) do dataset
                time = dataset["time"]
                ClassicSiteExecution.semantic_time_sha256(
                    collect(DateTime.(time[:])),
                    String(time.attrib["calendar"]),
                    String(time.attrib["units"]),
                )
            end
        end

        @test sha256_file(first_path) != sha256_file(encoded_path)
        @test signature(first_path) == signature(encoded_path)
        @test signature(first_path) != signature(changed_path)
    end
end
