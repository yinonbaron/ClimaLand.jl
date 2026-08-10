using Dates
using Test
import NCDatasets
import TOML

include("real_capture.jl")
using .ClassicRealSiteCapture: capture_real_site!

@testset "Stage-B applicability rejects mixed mineral masks" begin
    @test ClassicRealSiteCapture.classify_stage_b_applicability(Int32[0]) ==
          "inactive"
    @test ClassicRealSiteCapture.classify_stage_b_applicability(Int32[1]) ==
          "active"
    @test_throws ArgumentError ClassicRealSiteCapture.classify_stage_b_applicability(
        Int32[0, 1],
    )
    @test_throws ArgumentError ClassicRealSiteCapture.classify_stage_b_applicability(
        Int32[2],
    )
    @test_throws ArgumentError ClassicRealSiteCapture.classify_stage_b_applicability(
        Int32[],
    )
end

@testset "real capture callback runs a non-DE-Hai site fixture" begin
    mktempdir() do directory
        required_fields = ["driver.thliq", "reference.post_litrmass"]
        calls = String[]
        fixture_runner = function (site, workspace, fields, config)
            push!(calls, site)
            capture = joinpath(workspace, "capture")
            mkpath(joinpath(capture, "evidence"))
            mkpath(joinpath(capture, "payloads"))
            for name in (
                "manifest.toml",
                "capture_receipt.toml",
                "field_activity.toml",
            )
                write(joinpath(capture, name), name)
            end
            return (; step_count = 365, fields = copy(fields))
        end
        result = capture_real_site!(
            "SD-Dem",
            directory,
            required_fields,
            (; site_runner = fixture_runner),
        )

        @test calls == ["SD-Dem"]
        @test result.step_count == 365
        @test result.fields == required_fields
        @test Set(readdir(joinpath(directory, "capture"))) == Set((
            "manifest.toml",
            "capture_receipt.toml",
            "field_activity.toml",
            "evidence",
            "payloads",
        ))
    end
end

@testset "canonical capture root rejects unexpected entries" begin
    mktempdir() do directory
        capture = joinpath(directory, "capture")
        mkpath(joinpath(capture, "evidence"))
        mkpath(joinpath(capture, "payloads"))
        for name in
            ("manifest.toml", "capture_receipt.toml", "field_activity.toml")
            write(joinpath(capture, name), name)
        end
        @test ClassicRealSiteCapture.validate_capture_root(capture)
        write(joinpath(capture, "exploratory_receipt.toml"), "fail")
        @test_throws ArgumentError ClassicRealSiteCapture.validate_capture_root(
            capture,
        )
    end
end

function write_daily_time(path, calendar)
    NCDatasets.NCDataset(path, "c") do dataset
        NCDatasets.defDim(dataset, "time", 365)
        time = NCDatasets.defVar(dataset, "time", Float64, ("time",))
        time.attrib["units"] = "days since 2004-12-31 00:00"
        time.attrib["calendar"] = calendar
        time[:] = collect(1.0:365.0)
        NCDatasets.defVar(dataset, "tsl", Float64, ("time",))[:] .= 0.0
    end
end

function write_ledger(path)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, "schema_version=1 capture_mode=all_daily max_events=365")
        for index in 1:365
            println(
                io,
                index,
                " ",
                index,
                " daily/event_",
                lpad(index, 8, '0'),
                ".raw",
            )
        end
        println(io, "capture_complete events=365 max_events=365")
    end
end

@testset "non-DE-Hai chronology is ISO-bound and fail closed" begin
    mktempdir() do directory
        raw_root = joinpath(directory, "raw")
        netcdf_root = joinpath(directory, "netCDF")
        mkpath(netcdf_root)
        write_ledger(joinpath(raw_root, "daily", "event_ledger.raw"))
        time_path = joinpath(netcdf_root, "tsl_daily.nc")
        write_daily_time(time_path, "standard")
        time_sha256 = NCDatasets.NCDataset(time_path) do dataset
            time = dataset["time"]
            ClassicRealSiteCapture.semantic_time_sha256(
                collect(DateTime.(time[:])),
                String(time.attrib["calendar"]),
                String(time.attrib["units"]),
            )
        end
        execution = (;
            raw_root,
            netcdf_root,
            event_count = 365,
            capture_year = 2005,
            capture_source_calendar = "standard",
            oracle_time_sha256 = time_sha256,
        )
        result =
            ClassicRealSiteCapture.write_time_evidence!("SD-Dem", execution)
        index = TOML.parsefile(result.index_path)

        @test index["site"] == "SD-Dem"
        @test index["source_calendar"] == "standard"
        @test index["normalized_calendar"] == "proleptic_gregorian"
        @test length(index["event"]) == 365
        @test first(index["event"])["time_start"] == "2005-01-01T00:00:00"
        @test last(index["event"])["time_end"] == "2006-01-01T00:00:00"
    end

    mktempdir() do directory
        raw_root = joinpath(directory, "raw")
        netcdf_root = joinpath(directory, "netCDF")
        mkpath(netcdf_root)
        write_ledger(joinpath(raw_root, "daily", "event_ledger.raw"))
        write_daily_time(joinpath(netcdf_root, "tsl_daily.nc"), "noleap")
        @test_throws ArgumentError ClassicRealSiteCapture.write_time_evidence!(
            "SD-Dem",
            (; raw_root, netcdf_root, event_count = 365),
        )
    end
end

@testset "activity collection preserves scalar and array fields" begin
    replay = (;
        static_data = Dict(
            "parameter.zero" => 1.0e-20,
            "parameter.scalar_array" => fill(2.5),
            "static.zbot" => [0.1, 0.2],
        ),
        initial_state = Dict("initial.litrmass" => reshape([1.0], 1, 1, 1)),
        steps = [(
            drivers = Dict("driver.fg" => Int32(0)),
            reference_state = Dict("reference.post_soilcmas" => [2.0]),
            audit_diagnostics = Dict("audit.soilresp" => 3.0),
        )],
    )

    values = ClassicRealSiteCapture.activity_values(replay)

    @test values["parameter.zero"] == [1.0e-20]
    @test values["parameter.scalar_array"] == [2.5]
    @test values["static.zbot"] == [0.1, 0.2]
    @test values["driver.fg"] == [0.0]
    @test values["audit.soilresp"] == [3.0]
end
