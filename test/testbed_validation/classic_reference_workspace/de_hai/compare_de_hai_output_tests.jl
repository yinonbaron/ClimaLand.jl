using Test

import NCDatasets

include("compare_de_hai_output.jl")
using .DEHaiOutputComparison

function write_de_hai_test_file(
    path,
    values;
    variable_name = "stock",
    times = collect(1:size(values, 1)),
    units = "kg m-2",
    calendar = "standard",
    longitude = 10.0,
    fillvalue = 1.0e38,
)
    NCDatasets.NCDataset(path, "c") do dataset
        NCDatasets.defDim(dataset, "lon", 1)
        NCDatasets.defDim(dataset, "lat", 1)
        NCDatasets.defDim(dataset, "time", length(times))

        lon = NCDatasets.defVar(dataset, "longitude", Float64, ("lon",))
        lon.attrib["units"] = "degrees_east"
        lon[:] = [longitude]
        lat = NCDatasets.defVar(dataset, "latitude", Float64, ("lat",))
        lat.attrib["units"] = "degrees_north"
        lat[:] = [51.0]
        time = NCDatasets.defVar(dataset, "time", Float64, ("time",))
        time.attrib["units"] = "days since 1999-12-31 00:00"
        time.attrib["calendar"] = calendar
        time[:] = times

        variable = NCDatasets.defVar(
            dataset,
            variable_name,
            Float64,
            ("time", "lat", "lon");
            fillvalue,
        )
        variable.attrib["units"] = units
        variable.attrib["coordinates"] = "latitude longitude"
        variable[:] = reshape(values, length(times), 1, 1)
    end
end

@testset "DE-Hai output directory comparison" begin
    mktempdir() do directory
        reference = joinpath(directory, "reference")
        candidate = joinpath(directory, "candidate")
        mkpath(reference)
        mkpath(candidate)

        write_de_hai_test_file(
            joinpath(reference, "stock_daily.nc"),
            [10.0, 11.0, 12.0, 13.0, 14.0],
        )
        write_de_hai_test_file(
            joinpath(candidate, "stock_daily.nc"),
            [10.0, 11.0, 12.0, 13.0, 14.0],
        )
        write_de_hai_test_file(
            joinpath(reference, "rsFile_modified.nc"),
            [99.0],
            variable_name = "restart_state",
        )

        report = compare_de_hai_directories(reference, candidate)
        @test report.ok
        @test report.compared_files == ["stock_daily.nc"]
        @test report.reference_excluded_files == ["rsFile_modified.nc"]
        @test isempty(report.candidate_excluded_files)
        @test isempty(report.reference_only_files)
        @test isempty(report.candidate_only_files)
        comparison = only(report.file_comparisons)
        @test comparison.overlap.time_values == (1.0, 5.0)
        @test comparison.overlap.record_count == 5
        @test comparison.dimensions.reference["time"] == 5
        @test comparison.dimensions.candidate["time"] == 5
        @test comparison.variable.units == ("kg m-2", "kg m-2")
        @test comparison.variable.missing_counts == (0, 0)
        @test comparison.variable.values.ok
        @test comparison.coordinates["time"].values.ok
    end
end

@testset "DE-Hai comparison fails closed" begin
    mktempdir() do directory
        reference = joinpath(directory, "reference")
        candidate = joinpath(directory, "candidate")
        mkpath(reference)
        mkpath(candidate)

        write_de_hai_test_file(
            joinpath(reference, "stock_daily.nc"),
            Union{Missing, Float64}[1.0, missing, 3.0];
            times = [1, 2, 3],
        )
        write_de_hai_test_file(
            joinpath(candidate, "stock_daily.nc"),
            [1.0, 2.0, 4.0];
            times = [1, 2, 3],
            units = "g m-2",
            calendar = "noleap",
            longitude = 11.0,
        )
        write_de_hai_test_file(
            joinpath(reference, "reference_only.nc"),
            [1.0],
            variable_name = "reference_only",
        )
        write_de_hai_test_file(
            joinpath(candidate, "candidate_only.nc"),
            [1.0],
            variable_name = "candidate_only",
        )

        report = compare_de_hai_directories(reference, candidate)
        @test !report.ok
        @test report.reference_only_files == ["reference_only.nc"]
        @test report.candidate_only_files == ["candidate_only.nc"]
        comparison = only(report.file_comparisons)
        @test !comparison.ok
        @test comparison.variable.units == ("kg m-2", "g m-2")
        @test comparison.variable.missing_counts == (1, 0)
        @test comparison.variable.values.missing_mismatch_count == 1
        @test comparison.variable.values.failure_count == 2
        @test !comparison.coordinates["longitude"].values.ok
        @test comparison.calendar == ("standard", "noleap")
        @test "modeled variable units differ" in comparison.metadata_mismatches
        @test "time calendar differs" in comparison.metadata_mismatches
    end

    mktempdir() do directory
        reference = joinpath(directory, "reference")
        candidate = joinpath(directory, "candidate")
        mkpath(reference)
        mkpath(candidate)
        write_de_hai_test_file(
            joinpath(reference, "stock_daily.nc"),
            [10.0, 11.0, 12.0, 13.0, 14.0],
        )
        write_de_hai_test_file(
            joinpath(candidate, "stock_daily.nc"),
            [11.0, 12.0, 13.0],
            times = [2, 3, 4],
        )

        report = compare_de_hai_directories(reference, candidate)
        @test !report.ok
        comparison = only(report.file_comparisons)
        @test comparison.overlap.time_values == (2.0, 4.0)
        @test comparison.overlap.record_count == 3
        @test "candidate time coordinate does not cover the complete published range" in
              comparison.metadata_mismatches
    end

    mktempdir() do directory
        reference = joinpath(directory, "reference")
        candidate = joinpath(directory, "candidate")
        mkpath(reference)
        mkpath(candidate)
        write_de_hai_test_file(
            joinpath(reference, "stock_daily.nc"),
            [1.0, 2.0];
            times = [1, 2],
        )
        write_de_hai_test_file(
            joinpath(candidate, "stock_daily.nc"),
            [1.0, 2.0];
            times = [3, 4],
        )

        report = compare_de_hai_directories(reference, candidate)
        @test !report.ok
        @test only(report.file_comparisons).overlap.record_count == 0
        @test "time coordinates do not overlap" in
              only(report.file_comparisons).metadata_mismatches
    end

    mktempdir() do directory
        reference = joinpath(directory, "reference")
        candidate = joinpath(directory, "candidate")
        mkpath(reference)
        mkpath(candidate)
        write_de_hai_test_file(
            joinpath(reference, "stock_daily.nc"),
            [1.0, 2.0, 3.0];
            times = [1, 2, 3],
        )
        write_de_hai_test_file(
            joinpath(candidate, "stock_daily.nc"),
            [1.0, 3.0];
            times = [1, 3],
        )

        report = compare_de_hai_directories(reference, candidate)
        @test !report.ok
        @test "time overlap is not contiguous in both files" in
              only(report.file_comparisons).metadata_mismatches
    end
end
