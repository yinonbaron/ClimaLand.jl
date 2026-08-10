module DEHaiOutputComparison

import NCDatasets

include(joinpath(@__DIR__, "..", "..", "netcdf_compare.jl"))
const NetCDFCompare = TestbedNetCDFCompare

export compare_de_hai_directories, print_de_hai_report

const NON_MODELED_FILENAMES = Set(("rsFile_modified.nc",))

attribute(variable, name) =
    haskey(variable.attrib, name) ? variable.attrib[name] : nothing

function netcdf_files(directory)
    isdir(directory) || throw(ArgumentError("not a directory: $directory"))
    files = String[]
    for (root, _, names) in walkdir(directory)
        for name in names
            endswith(lowercase(name), ".nc") || continue
            push!(files, relpath(joinpath(root, name), directory))
        end
    end
    return sort!(files)
end

function modeled_variable_name(filename)
    stem = splitext(basename(filename))[1]
    return replace(stem, r"_(daily|monthly|annually)$" => "")
end

dimensions(dataset) =
    Dict(String(name) => Int(dimension) for (name, dimension) in dataset.dim)

function coordinate_names(dataset, variable)
    names = Set{String}()
    for dimension in NCDatasets.dimnames(variable)
        name = String(dimension)
        haskey(dataset, name) && push!(names, name)
    end
    coordinates = attribute(variable, "coordinates")
    if !isnothing(coordinates)
        union!(names, split(String(coordinates)))
    end
    return names
end

function selected_values(variable, selector; raw = false)
    source = raw ? variable.var : variable
    ndims(source) == 0 && return [source[]]
    indices = map(NCDatasets.dimnames(source)) do dimension
        String(dimension) == "time" ? selector : Colon()
    end
    return source[indices...]
end

function time_selection(reference, candidate, mismatches)
    reference_values = vec(reference.var[:])
    candidate_values = vec(candidate.var[:])

    if any(ismissing, reference_values) || any(ismissing, candidate_values)
        push!(mismatches, "time coordinate contains missing values")
        return (1:0, 1:0, nothing, 0)
    end
    if !issorted(reference_values) || !allunique(reference_values)
        push!(mismatches, "reference time coordinate is not unique and sorted")
    end
    if !issorted(candidate_values) || !allunique(candidate_values)
        push!(mismatches, "candidate time coordinate is not unique and sorted")
    end
    if !isequal(reference_values, candidate_values)
        push!(
            mismatches,
            "candidate time coordinate does not cover the complete published range",
        )
    end

    common =
        sort!(collect(intersect(Set(reference_values), Set(candidate_values))))
    if isempty(common)
        push!(mismatches, "time coordinates do not overlap")
        return (1:0, 1:0, nothing, 0)
    end

    reference_first = findfirst(isequal(first(common)), reference_values)
    reference_last = findlast(isequal(last(common)), reference_values)
    candidate_first = findfirst(isequal(first(common)), candidate_values)
    candidate_last = findlast(isequal(last(common)), candidate_values)
    reference_selector = reference_first:reference_last
    candidate_selector = candidate_first:candidate_last
    if !isequal(reference_values[reference_selector], common) ||
       !isequal(candidate_values[candidate_selector], common)
        push!(mismatches, "time overlap is not contiguous in both files")
        return (1:0, 1:0, (first(common), last(common)), 0)
    end
    return (
        reference_selector,
        candidate_selector,
        (first(common), last(common)),
        length(common),
    )
end

function compare_array_pair(
    reference,
    candidate,
    reference_selector,
    candidate_selector;
    raw = false,
)
    reference_values = selected_values(reference, reference_selector; raw)
    candidate_values = selected_values(candidate, candidate_selector; raw)
    values = NetCDFCompare.compare_values(
        reference_values,
        candidate_values;
        exact = true,
    )
    return (
        dimensions = (
            String.(NCDatasets.dimnames(reference)),
            String.(NCDatasets.dimnames(candidate)),
        ),
        element_types = if raw
            (eltype(reference.var), eltype(candidate.var))
        else
            (eltype(reference), eltype(candidate))
        end,
        units = (attribute(reference, "units"), attribute(candidate, "units")),
        calendars = (
            attribute(reference, "calendar"),
            attribute(candidate, "calendar"),
        ),
        fill_values = (
            attribute(reference, "_FillValue"),
            attribute(candidate, "_FillValue"),
        ),
        missing_values = (
            attribute(reference, "missing_value"),
            attribute(candidate, "missing_value"),
        ),
        missing_counts = (
            count(ismissing, reference_values),
            count(ismissing, candidate_values),
        ),
        values,
    )
end

function compare_metadata!(mismatches, label, comparison; require_units = true)
    comparison.dimensions[1] == comparison.dimensions[2] ||
        push!(mismatches, "$label dimension order differs")
    comparison.element_types[1] == comparison.element_types[2] ||
        push!(mismatches, "$label element type differs")
    if require_units && any(isnothing, comparison.units)
        push!(mismatches, "$label units are missing")
    elseif !isequal(comparison.units[1], comparison.units[2])
        push!(mismatches, "$label units differ")
    end
    isequal(comparison.calendars[1], comparison.calendars[2]) ||
        push!(mismatches, "$label calendar differs")
    isequal(comparison.fill_values[1], comparison.fill_values[2]) ||
        push!(mismatches, "$label _FillValue differs")
    isequal(comparison.missing_values[1], comparison.missing_values[2]) ||
        push!(mismatches, "$label missing_value differs")
    return nothing
end

function failed_file_comparison(filename, message)
    return (
        filename,
        variable_name = modeled_variable_name(filename),
        ok = false,
        dimensions = (
            reference = Dict{String, Int}(),
            candidate = Dict{String, Int}(),
        ),
        modeled_variables = (String[], String[]),
        overlap = (time_values = nothing, record_count = 0),
        calendar = (nothing, nothing),
        coordinates = Dict{String, Any}(),
        variable = nothing,
        metadata_mismatches = [message],
    )
end

function compare_file(reference_path, candidate_path, filename)
    try
        return NCDatasets.NCDataset(reference_path) do reference
            NCDatasets.NCDataset(candidate_path) do candidate
                compare_open_files(reference, candidate, filename)
            end
        end
    catch error
        return failed_file_comparison(
            filename,
            "comparison error: $(sprint(showerror, error))",
        )
    end
end

function compare_open_files(reference, candidate, filename)
    mismatches = String[]
    reference_dimensions = dimensions(reference)
    candidate_dimensions = dimensions(candidate)
    reference_dimension_names = Set(keys(reference_dimensions))
    candidate_dimension_names = Set(keys(candidate_dimensions))
    reference_dimension_names == candidate_dimension_names ||
        push!(mismatches, "dimension names differ")
    for name in intersect(reference_dimension_names, candidate_dimension_names)
        name == "time" && continue
        reference_dimensions[name] == candidate_dimensions[name] ||
            push!(mismatches, "$name dimension length differs")
    end

    variable_name = modeled_variable_name(filename)
    haskey(reference, variable_name) || return failed_file_comparison(
        filename,
        "reference is missing modeled variable $variable_name",
    )
    haskey(candidate, variable_name) || return failed_file_comparison(
        filename,
        "candidate is missing modeled variable $variable_name",
    )
    reference_variable = reference[variable_name]
    candidate_variable = candidate[variable_name]
    reference_coordinates = coordinate_names(reference, reference_variable)
    candidate_coordinates = coordinate_names(candidate, candidate_variable)
    reference_modeled = sort!(
        collect(setdiff(Set(String.(keys(reference))), reference_coordinates)),
    )
    candidate_modeled = sort!(
        collect(setdiff(Set(String.(keys(candidate))), candidate_coordinates)),
    )
    reference_modeled == [variable_name] || push!(
        mismatches,
        "reference modeled-variable inventory differs from filename",
    )
    candidate_modeled == [variable_name] || push!(
        mismatches,
        "candidate modeled-variable inventory differs from filename",
    )
    reference_coordinates == candidate_coordinates ||
        push!(mismatches, "coordinate variable names differ")

    reference_selector = Colon()
    candidate_selector = Colon()
    time_values = nothing
    record_count = 1
    calendar = (nothing, nothing)
    if "time" in union(reference_dimension_names, candidate_dimension_names)
        if !haskey(reference, "time") || !haskey(candidate, "time")
            push!(mismatches, "time dimension has no coordinate on both sides")
            reference_selector = 1:0
            candidate_selector = 1:0
            record_count = 0
        else
            reference_time = reference["time"]
            candidate_time = candidate["time"]
            calendar = (
                attribute(reference_time, "calendar"),
                attribute(candidate_time, "calendar"),
            )
            any(isnothing, calendar) &&
                push!(mismatches, "time calendar is missing")
            isequal(calendar[1], calendar[2]) ||
                push!(mismatches, "time calendar differs")
            time_units = (
                attribute(reference_time, "units"),
                attribute(candidate_time, "units"),
            )
            any(isnothing, time_units) &&
                push!(mismatches, "time units are missing")
            isequal(time_units[1], time_units[2]) ||
                push!(mismatches, "time units differ")
            reference_selector, candidate_selector, time_values, record_count =
                time_selection(reference_time, candidate_time, mismatches)
        end
    end

    coordinates = Dict{String, Any}()
    for name in
        sort!(collect(intersect(reference_coordinates, candidate_coordinates)))
        comparison = compare_array_pair(
            reference[name],
            candidate[name],
            reference_selector,
            candidate_selector,
            raw = name == "time",
        )
        coordinates[name] = comparison
        compare_metadata!(mismatches, "$name coordinate", comparison)
    end

    variable = compare_array_pair(
        reference_variable,
        candidate_variable,
        reference_selector,
        candidate_selector,
    )
    compare_metadata!(mismatches, "modeled variable", variable)
    values_ok =
        variable.values.ok &&
        all(comparison.values.ok for comparison in values(coordinates))
    return (
        filename,
        variable_name,
        ok = isempty(mismatches) && values_ok && record_count > 0,
        dimensions = (
            reference = reference_dimensions,
            candidate = candidate_dimensions,
        ),
        modeled_variables = (reference_modeled, candidate_modeled),
        overlap = (time_values = time_values, record_count = record_count),
        calendar,
        coordinates,
        variable,
        metadata_mismatches = mismatches,
    )
end

"""
    compare_de_hai_directories(reference_directory, candidate_directory)

Compare every paired DE-Hai modeled NetCDF file over its complete published
time range. The returned report is successful only when the modeled-file
inventories, time coordinates, paired metadata, coordinate masks, and values
agree exactly.
"""
function compare_de_hai_directories(reference_directory, candidate_directory)
    all_reference_files = netcdf_files(reference_directory)
    all_candidate_files = netcdf_files(candidate_directory)
    reference_excluded_files = sort!([
        name for name in all_reference_files if
        basename(name) in NON_MODELED_FILENAMES
    ])
    candidate_excluded_files = sort!([
        name for name in all_candidate_files if
        basename(name) in NON_MODELED_FILENAMES
    ])
    reference_files = setdiff(all_reference_files, reference_excluded_files)
    candidate_files = setdiff(all_candidate_files, candidate_excluded_files)
    reference_set = Set(reference_files)
    candidate_set = Set(candidate_files)
    compared_files = sort!(collect(intersect(reference_set, candidate_set)))
    reference_only_files = sort!(collect(setdiff(reference_set, candidate_set)))
    candidate_only_files = sort!(collect(setdiff(candidate_set, reference_set)))
    file_comparisons = [
        compare_file(
            joinpath(reference_directory, filename),
            joinpath(candidate_directory, filename),
            filename,
        ) for filename in compared_files
    ]
    ok =
        !isempty(compared_files) &&
        isempty(reference_only_files) &&
        isempty(candidate_only_files) &&
        all(comparison.ok for comparison in file_comparisons)
    return (
        ok,
        reference_directory = abspath(reference_directory),
        candidate_directory = abspath(candidate_directory),
        reference_netcdf_count = length(all_reference_files),
        candidate_netcdf_count = length(all_candidate_files),
        reference_file_count = length(reference_files),
        candidate_file_count = length(candidate_files),
        reference_excluded_files,
        candidate_excluded_files,
        compared_files,
        reference_only_files,
        candidate_only_files,
        file_comparisons,
    )
end

function print_value_report(label, comparison)
    println(
        "  ",
        label,
        ": dimensions=",
        comparison.dimensions,
        " units=",
        comparison.units,
        " calendar=",
        comparison.calendars,
        " fill=",
        comparison.fill_values,
        " missing_value=",
        comparison.missing_values,
        " missing_counts=",
        comparison.missing_counts,
        " missing_mask_mismatches=",
        comparison.values.missing_mismatch_count,
        " failures=",
        comparison.values.failure_count,
        " max_abs=",
        comparison.values.max_abs_error,
        " max_rel=",
        comparison.values.max_rel_error,
        " first_failure=",
        comparison.values.first_failure,
    )
end

"""
    print_de_hai_report(report)

Print the complete DE-Hai inventory, metadata, mask, and numerical comparison
and return its success status.
"""
function print_de_hai_report(report)
    println("reference directory: ", report.reference_directory)
    println("candidate directory: ", report.candidate_directory)
    println(
        "NetCDF inventory: reference=",
        report.reference_netcdf_count,
        " candidate=",
        report.candidate_netcdf_count,
        " modeled_reference=",
        report.reference_file_count,
        " modeled_candidate=",
        report.candidate_file_count,
        " compared=",
        length(report.compared_files),
    )
    println(
        "reference excluded non-modeled files: ",
        repr(report.reference_excluded_files),
    )
    println(
        "candidate excluded non-modeled files: ",
        repr(report.candidate_excluded_files),
    )
    println("reference-only files: ", repr(report.reference_only_files))
    println("candidate-only files: ", repr(report.candidate_only_files))
    for comparison in report.file_comparisons
        println(
            comparison.filename,
            ": ",
            comparison.ok ? "PASS" : "FAIL",
            " variable=",
            comparison.variable_name,
        )
        println("  dimensions: ", comparison.dimensions)
        println("  modeled variables: ", comparison.modeled_variables)
        println("  time overlap: ", comparison.overlap)
        println("  calendar: ", comparison.calendar)
        for mismatch in comparison.metadata_mismatches
            println("  metadata mismatch: ", mismatch)
        end
        for name in sort!(collect(keys(comparison.coordinates)))
            print_value_report("coordinate $name", comparison.coordinates[name])
        end
        isnothing(comparison.variable) ||
            print_value_report("modeled variable", comparison.variable)
    end
    println("overall: ", report.ok ? "PASS" : "FAIL")
    return report.ok
end

function main(arguments)
    if length(arguments) != 2
        println(
            stderr,
            "Usage: julia compare_de_hai_output.jl <published-netCDF-dir> <local-netCDF-dir>",
        )
        return 2
    end
    report = try
        compare_de_hai_directories(arguments[1], arguments[2])
    catch error
        println(stderr, "comparison failed: ", sprint(showerror, error))
        return 2
    end
    return print_de_hai_report(report) ? 0 : 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end

end
