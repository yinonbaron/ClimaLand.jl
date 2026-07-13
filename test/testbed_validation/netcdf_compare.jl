module TestbedNetCDFCompare

import NCDatasets
import Test

const CRITICAL_ATTRIBUTES = (
    "units",
    "calendar",
    "standard_name",
    "axis",
    "positive",
    "_FillValue",
    "missing_value",
)
const DEFAULT_EXACT_VARIABLES =
    Set(("lon", "lat", "time", "day", "cellMissing", "cellid", "IGBP_PFT"))

function compare_values(
    reference,
    candidate;
    atol = 0.0,
    rtol = 0.0,
    abs_floor = 0.0,
    exact = false,
)
    size(reference) == size(candidate) || return (
        ok = false,
        size_match = false,
        failure_count = max(length(reference), length(candidate)),
        missing_mismatch_count = 0,
        nonfinite_count = 0,
        sign_change_count = 0,
        max_abs_error = Inf,
        max_rel_error = Inf,
        first_failure = nothing,
    )

    failure_count = 0
    missing_mismatch_count = 0
    nonfinite_count = 0
    sign_change_count = 0
    max_abs_error = 0.0
    max_rel_error = 0.0
    first_failure = nothing
    indices = CartesianIndices(reference)

    for linear_index in eachindex(reference, candidate)
        reference_value = reference[linear_index]
        candidate_value = candidate[linear_index]
        failed = false

        if ismissing(reference_value) || ismissing(candidate_value)
            failed = !(ismissing(reference_value) && ismissing(candidate_value))
            missing_mismatch_count += failed
        elseif reference_value isa Number && candidate_value isa Number
            reference_nonfinite =
                reference_value isa AbstractFloat && !isfinite(reference_value)
            candidate_nonfinite =
                candidate_value isa AbstractFloat && !isfinite(candidate_value)
            if reference_nonfinite || candidate_nonfinite
                nonfinite_count += 1
                failed = !(
                    (isnan(reference_value) && isnan(candidate_value)) ||
                    isequal(reference_value, candidate_value)
                )
            elseif exact ||
                   reference_value isa Integer ||
                   candidate_value isa Integer
                failed = !isequal(reference_value, candidate_value)
                difference =
                    abs(Float64(candidate_value) - Float64(reference_value))
                max_abs_error = max(max_abs_error, difference)
                scale = max(abs(Float64(reference_value)), Float64(abs_floor))
                relative_error =
                    difference == 0 ? 0.0 :
                    scale == 0 ? Inf : difference / scale
                max_rel_error = max(max_rel_error, relative_error)
            else
                reference_float = Float64(reference_value)
                candidate_float = Float64(candidate_value)
                difference = abs(candidate_float - reference_float)
                scale = max(abs(reference_float), Float64(abs_floor))
                relative_error =
                    difference == 0 ? 0.0 :
                    scale == 0 ? Inf : difference / scale
                max_abs_error = max(max_abs_error, difference)
                max_rel_error = max(max_rel_error, relative_error)
                sign_changed =
                    reference_float != 0 &&
                    candidate_float != 0 &&
                    signbit(reference_float) != signbit(candidate_float)
                sign_change_count += sign_changed
                failed =
                    sign_changed ||
                    difference > Float64(atol) + Float64(rtol) * scale
            end
        else
            failed = !isequal(reference_value, candidate_value)
        end

        if failed
            failure_count += 1
            isnothing(first_failure) &&
                (first_failure = Tuple(indices[linear_index]))
        end
    end

    return (
        ok = failure_count == 0,
        size_match = true,
        failure_count,
        missing_mismatch_count,
        nonfinite_count,
        sign_change_count,
        max_abs_error,
        max_rel_error,
        first_failure,
    )
end

function read_variable(variable, selectors)
    ndims(variable) == 0 && return [variable[]]
    indices = map(NCDatasets.dimnames(variable)) do dimension
        selector = get(selectors, String(dimension), Colon())
        selector isa Integer ? (selector:selector) : selector
    end
    return variable[indices...]
end

selector_length(length, ::Colon) = length
selector_length(length, ::Integer) = 1
selector_length(length, selector) = Base.length(selector)

function selected_dimensions(dataset, selectors)
    return Dict(
        String(name) => selector_length(
            Int(dimension),
            get(selectors, String(name), Colon()),
        ) for (name, dimension) in dataset.dim
    )
end

attribute(variable, name) =
    haskey(variable.attrib, name) ? variable.attrib[name] : nothing

function compare_netcdf(
    reference_path,
    candidate_path;
    variables = String[],
    ignored_variables = String[],
    exact_variables = DEFAULT_EXACT_VARIABLES,
    tolerances = Dict{String, NamedTuple}(),
    reference_selectors = Dict{String, Any}(),
    candidate_selectors = Dict{String, Any}(),
    candidate_offsets = Dict{String, Real}(),
)
    ignored = Set(ignored_variables)
    metadata_mismatches = String[]
    results = Dict{String, NamedTuple}()

    NCDatasets.NCDataset(reference_path) do reference
        NCDatasets.NCDataset(candidate_path) do candidate
            reference_dimensions =
                selected_dimensions(reference, reference_selectors)
            candidate_dimensions =
                selected_dimensions(candidate, candidate_selectors)
            reference_dimensions == candidate_dimensions ||
                push!(metadata_mismatches, "dimension names or lengths differ")

            reference_names = setdiff(Set(String.(keys(reference))), ignored)
            candidate_names = setdiff(Set(String.(keys(candidate))), ignored)
            selected_names = if isempty(variables)
                missing_reference = sort!(
                    collect(setdiff(candidate_names, reference_names)),
                )
                missing_candidate = sort!(
                    collect(setdiff(reference_names, candidate_names)),
                )
                isempty(missing_reference) || push!(
                    metadata_mismatches,
                    "reference is missing $(join(missing_reference, ", "))",
                )
                isempty(missing_candidate) || push!(
                    metadata_mismatches,
                    "candidate is missing $(join(missing_candidate, ", "))",
                )
                sort!(collect(intersect(reference_names, candidate_names)))
            else
                requested = Set(variables)
                missing_reference = setdiff(requested, reference_names)
                missing_candidate = setdiff(requested, candidate_names)
                isempty(missing_reference) || push!(
                    metadata_mismatches,
                    "reference is missing $(join(sort!(collect(missing_reference)), ", "))",
                )
                isempty(missing_candidate) || push!(
                    metadata_mismatches,
                    "candidate is missing $(join(sort!(collect(missing_candidate)), ", "))",
                )
                sort!(
                    collect(
                        intersect(requested, reference_names, candidate_names),
                    ),
                )
            end

            for name in selected_names
                reference_variable = reference[name]
                candidate_variable = candidate[name]
                NCDatasets.dimnames(reference_variable) ==
                NCDatasets.dimnames(candidate_variable) ||
                    push!(metadata_mismatches, "$name dimension order differs")
                eltype(reference_variable) == eltype(candidate_variable) ||
                    push!(metadata_mismatches, "$name element type differs")
                for attribute_name in CRITICAL_ATTRIBUTES
                    isequal(
                        attribute(reference_variable, attribute_name),
                        attribute(candidate_variable, attribute_name),
                    ) || push!(
                        metadata_mismatches,
                        "$name attribute $attribute_name differs",
                    )
                end

                tolerance = get(
                    tolerances,
                    name,
                    (atol = 0.0, rtol = 0.0, abs_floor = 0.0),
                )
                reference_values =
                    read_variable(reference_variable, reference_selectors)
                candidate_values =
                    read_variable(candidate_variable, candidate_selectors)
                if haskey(candidate_offsets, name)
                    candidate_values =
                        candidate_values .+ candidate_offsets[name]
                end
                results[name] = compare_values(
                    reference_values,
                    candidate_values;
                    tolerance...,
                    exact = name in exact_variables,
                )
            end
        end
    end

    failed_variables =
        sort!([name for (name, result) in results if !result.ok],)
    return (
        ok = isempty(metadata_mismatches) && isempty(failed_variables),
        metadata_mismatches,
        failed_variables,
        results,
    )
end

function print_report(report)
    for mismatch in report.metadata_mismatches
        println("metadata: ", mismatch)
    end
    for name in report.failed_variables
        result = report.results[name]
        println(
            name,
            ": failures=",
            result.failure_count,
            " max_abs=",
            result.max_abs_error,
            " max_rel=",
            result.max_rel_error,
            " sign_changes=",
            result.sign_change_count,
            " first=",
            result.first_failure,
        )
    end
    println("variables compared: ", length(report.results))
    return report.ok
end

function write_test_file(
    path,
    values;
    units = "kg m-2",
    coordinate_values = collect(eachindex(values)),
    mask = zeros(Int, length(values)),
    history = "reference history",
    fillvalue = nothing,
)
    NCDatasets.NCDataset(path, "c") do dataset
        dataset.attrib["history"] = history
        NCDatasets.defDim(dataset, "x", length(values))
        coordinate = NCDatasets.defVar(dataset, "x", Float64, ("x",))
        coordinate.attrib["units"] = "1"
        coordinate[:] = coordinate_values
        cell_missing = NCDatasets.defVar(dataset, "cellMissing", Int, ("x",))
        cell_missing[:] = mask
        variable = if isnothing(fillvalue)
            NCDatasets.defVar(dataset, "stock", Float64, ("x",))
        else
            NCDatasets.defVar(dataset, "stock", Float64, ("x",); fillvalue)
        end
        variable.attrib["units"] = units
        variable[:] = values
    end
end

function self_test()
    Test.@testset "NetCDF comparison" begin
        exact = compare_values([1.0, 2.0], [1.0, 2.0])
        Test.@test exact.ok
        tolerant = compare_values(
            [1.0, 0.0],
            [1.001, 1.0e-8];
            rtol = 0.002,
            abs_floor = 1.0e-5,
        )
        Test.@test tolerant.ok
        sign_change = compare_values([1.0], [-1.0]; atol = 3.0)
        Test.@test !sign_change.ok
        Test.@test sign_change.sign_change_count == 1
        missing_mismatch = compare_values(
            Union{Missing, Float64}[missing],
            Union{Missing, Float64}[1.0],
        )
        Test.@test missing_mismatch.missing_mismatch_count == 1
        Test.@test compare_values([NaN, Inf], [NaN, Inf]).ok

        mktempdir() do directory
            reference = joinpath(directory, "reference.nc")
            matching = joinpath(directory, "matching.nc")
            different = joinpath(directory, "different.nc")
            wrong_units = joinpath(directory, "wrong_units.nc")
            write_test_file(reference, [1.0, 2.0])
            write_test_file(matching, [1.0, 2.0])
            write_test_file(different, [1.0, 3.0])
            write_test_file(wrong_units, [1.0, 2.0]; units = "g m-2")
            Test.@test compare_netcdf(reference, matching).ok
            Test.@test !compare_netcdf(reference, different).ok
            Test.@test !compare_netcdf(reference, wrong_units).ok

            different_coordinate =
                joinpath(directory, "different_coordinate.nc")
            write_test_file(
                different_coordinate,
                [1.0, 2.0];
                coordinate_values = [1.0, 3.0],
            )
            coordinate_report = compare_netcdf(reference, different_coordinate)
            Test.@test !coordinate_report.ok
            Test.@test "x" in coordinate_report.failed_variables

            different_mask = joinpath(directory, "different_mask.nc")
            write_test_file(different_mask, [1.0, 2.0]; mask = [0, 1])
            mask_report = compare_netcdf(reference, different_mask)
            Test.@test !mask_report.ok
            Test.@test "cellMissing" in mask_report.failed_variables

            missing_reference = joinpath(directory, "missing_reference.nc")
            missing_candidate = joinpath(directory, "missing_candidate.nc")
            write_test_file(
                missing_reference,
                Union{Missing, Float64}[1.0, missing];
                fillvalue = -9999.0,
            )
            write_test_file(
                missing_candidate,
                Union{Missing, Float64}[1.0, 2.0];
                fillvalue = -9999.0,
            )
            missing_report =
                compare_netcdf(missing_reference, missing_candidate)
            Test.@test !missing_report.ok
            Test.@test missing_report.results["stock"].missing_mismatch_count ==
                       1

            nonfinite = joinpath(directory, "nonfinite.nc")
            write_test_file(nonfinite, [1.0, Inf])
            nonfinite_report = compare_netcdf(reference, nonfinite)
            Test.@test !nonfinite_report.ok
            Test.@test nonfinite_report.results["stock"].nonfinite_count == 1

            different_history = joinpath(directory, "different_history.nc")
            write_test_file(
                different_history,
                [1.0, 2.0];
                history = "non-scientific creation metadata changed",
            )
            Test.@test compare_netcdf(reference, different_history).ok

            sliced = joinpath(directory, "sliced.nc")
            write_test_file(sliced, [2.0])
            Test.@test compare_netcdf(
                reference,
                sliced;
                variables = ["stock"],
                reference_selectors = Dict("x" => 2),
            ).ok

            offset = joinpath(directory, "offset.nc")
            write_test_file(offset, [-9.0, -8.0])
            Test.@test compare_netcdf(
                reference,
                offset;
                candidate_offsets = Dict("stock" => 10.0),
            ).ok
        end
    end
    return true
end

function main(args)
    length(args) >= 2 || begin
        println(
            stderr,
            "Usage: julia netcdf_compare.jl <reference.nc> <candidate.nc> [ignored-variable ...]",
        )
        return 2
    end
    report = compare_netcdf(args[1], args[2]; ignored_variables = args[3:end])
    return print_report(report) ? 0 : 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end

end
