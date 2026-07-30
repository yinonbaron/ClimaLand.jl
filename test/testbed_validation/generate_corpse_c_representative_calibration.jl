if !isdefined(@__MODULE__, :TestbedNativeCORPSECReconstruction)
    include(joinpath(@__DIR__, "native_corpse_c_reconstruction.jl"))
end

module TestbedCORPSERepresentativeCalibration

import SHA
import Statistics
import TOML

import ClimaLand
import NCDatasets

const TIMEOUT_SECONDS = 2 * 60 * 60
const CALIBRATION_ID = "corpse-c-representative-fresh-fortran-v1"
const COORDINATE_SCHEMAS = Dict(
    :boundary => Set{String}(),
    :annual => Set(("year",)),
    :fixed_daily => Set(("year", "sample_day", "day_of_year")),
)

native_corpse() =
    getfield(parentmodule(@__MODULE__), :TestbedNativeCORPSECReconstruction)

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

function right_derivative(r, errors, references)
    residuals = errors .- r .* references
    maximum_residual = maximum(residuals)
    maximum_value = max(0.0, maximum_residual)
    slopes = Float64[]
    iszero(maximum_value) && push!(slopes, Statistics.mean(references))
    for index in eachindex(residuals)
        residuals[index] == maximum_value &&
            push!(slopes, Statistics.mean(references) - references[index])
    end
    return maximum(slopes)
end

function calibrated_envelope(errors, references; numerical_scale)
    relative = 0.0
    if right_derivative(relative, errors, references) < 0
        upper = eps(Float64)
        while right_derivative(upper, errors, references) < 0
            upper *= 2
            isfinite(upper) ||
                error("unable to bracket calibrated relative tolerance")
        end
        lower = 0.0
        for _ in 1:256
            middle = (lower + upper) / 2
            if right_derivative(middle, errors, references) < 0
                lower = middle
            else
                upper = middle
            end
        end
        relative = upper
    end
    absolute = max(0.0, maximum(errors .- relative .* references))
    absolute_padding = 64eps(Float64) * numerical_scale
    atol = 1.05absolute + absolute_padding
    rtol = 1.05relative
    all(errors .<= atol .+ rtol .* references) ||
        error("calibrated tolerance does not enclose every eligible pair")
    return (;
        atol,
        rtol,
        raw_atol = absolute,
        raw_rtol = relative,
        absolute_numerical_padding = absolute_padding,
    )
end

function distribution(values)
    return Dict(
        "minimum" => minimum(values),
        "median" => Statistics.median(values),
        "p90" => Statistics.quantile(values, 0.90),
        "p95" => Statistics.quantile(values, 0.95),
        "p99" => Statistics.quantile(values, 0.99),
        "p999" => Statistics.quantile(values, 0.999),
        "maximum" => maximum(values),
        "mean" => Statistics.mean(values),
    )
end

function calibration_record(
    actual,
    expected,
    grid;
    units,
    coordinate_schema = :boundary,
    coordinates = Dict{String, Any}(),
)
    length(actual) == length(expected) == length(grid) ||
        error("calibration requires aligned eligible cell pairs")
    isempty(actual) && error("calibration requires at least one eligible pair")
    all(
        hasproperty(point, :latitude) && hasproperty(point, :longitude) for
        point in grid
    ) || error("calibration observations require latitude and longitude")
    haskey(COORDINATE_SCHEMAS, coordinate_schema) ||
        error("calibration contains an unsupported coordinate schema")
    Set(keys(coordinates)) == COORDINATE_SCHEMAS[coordinate_schema] ||
        error("calibration temporal coordinates differ from their schema")
    all(length(values) == length(actual) for values in values(coordinates)) ||
        error("calibration temporal coordinates are not aligned")
    all(isfinite, actual) || error(
        "eligible Julia Representative boundary contains a nonfinite value",
    )
    all(isfinite, expected) || error(
        "eligible Fortran Representative boundary contains a nonfinite value",
    )

    references = abs.(expected)
    errors = abs.(actual .- expected)
    nonzero_reference = findall(!iszero, references)
    relative_errors = errors[nonzero_reference] ./ references[nonzero_reference]
    relative_distribution = Dict{String, Any}(
        "defined_pair_count" => length(relative_errors),
        "undefined_zero_reference_count" =>
            length(references) - length(relative_errors),
    )
    isempty(relative_errors) ||
        merge!(relative_distribution, distribution(relative_errors))
    numerical_scale =
        max(maximum(abs, actual), maximum(abs, expected), floatmin(Float64))
    envelope = calibrated_envelope(errors, references; numerical_scale)
    residuals = errors .- envelope.raw_rtol .* references
    maximum_residual = maximum(residuals)
    active_tolerance = 256eps(Float64) * max(1.0, abs(maximum_residual))
    active =
        maximum_residual + active_tolerance >= 0 ?
        findall(
            residual -> isapprox(
                residual,
                maximum_residual;
                atol = active_tolerance,
                rtol = 0,
            ),
            residuals,
        ) : Int[]
    order = sortperm(errors; rev = true)
    outlier_count = min(6, length(order))
    outliers = [
        merge(
            Dict{String, Any}(
                "rank" => rank,
                "cell_id" => grid[index].cell_id,
                "pft" => grid[index].pft,
                "latitude" => grid[index].latitude,
                "longitude" => grid[index].longitude,
                "julia_value" => actual[index],
                "fortran_value" => expected[index],
                "absolute_error" => errors[index],
                "relative_error" =>
                    iszero(references[index]) ?
                    "undefined_zero_reference" :
                    errors[index] / references[index],
            ),
            Dict(name => values[index] for (name, values) in coordinates),
        ) for (rank, index) in enumerate(order[1:outlier_count])
    ]
    return Dict(
        "units" => units,
        "finite_pair_count" => length(errors),
        "absolute_error" => distribution(errors),
        "relative_error" => relative_distribution,
        "absolute_reference" => distribution(references),
        "active_constraint_cell_ids" =>
            [grid[index].cell_id for index in active],
        "active_constraint_objective_slopes" => [
            Statistics.mean(references) - references[index] for index in active
        ],
        "nonnegative_atol_constraint_active" => isapprox(
            0.0,
            max(0.0, maximum_residual);
            atol = active_tolerance,
            rtol = 0,
        ),
        "active_constraint" =>
            isempty(active) ? "nonnegative_atol" : "cell_pair",
        "top_outlier" => outliers,
        "derived_policy" => Dict(
            "atol" => envelope.atol,
            "rtol" => envelope.rtol,
            "raw_atol" => envelope.raw_atol,
            "raw_rtol" => envelope.raw_rtol,
            "absolute_numerical_padding" =>
                envelope.absolute_numerical_padding,
            "raw_objective" =>
                envelope.raw_atol +
                envelope.raw_rtol * Statistics.mean(references),
            "validation_failed_pairs" => count(
                errors .> envelope.atol .+ envelope.rtol .* references,
            ),
        ),
    )
end

function calibration_population(grid, reducer, coordinate)
    schema = if reducer == "fixed_daily_sample"
        :fixed_daily
    elseif reducer in ("annual_mean", "end_of_year", "annual_total")
        :annual
    else
        error("unsupported CORPSE historical reducer $reducer")
    end
    repeated_grid = repeat(grid, outer = length(coordinate))
    year_coordinate =
        schema == :fixed_daily ? 1900 .+ cld.(coordinate, 365) : coordinate
    coordinates = Dict(
        "year" => repeat(year_coordinate, inner = length(grid)),
    )
    schema == :fixed_daily && merge!(
        coordinates,
        Dict(
            "sample_day" => repeat(coordinate, inner = length(grid)),
            "day_of_year" =>
                repeat(mod1.(coordinate, 365), inner = length(grid)),
        ),
    )
    return repeated_grid, coordinates, schema
end

function checkpoint_path(output_root, stage)
    stage_root = joinpath(output_root, "stages", String(stage.name))
    manifest_path = joinpath(stage_root, "workflow.toml")
    manifest = TOML.parsefile(manifest_path)
    entries = manifest["stage"]
    length(entries) == 1 || error("expected one stage in $manifest_path")
    return joinpath(stage_root, entries[1]["checkpoint"]), manifest_path
end

function source_record(path, id)
    return Dict("id" => id, "sha256" => sha256sum(path))
end

function reduced_calibration(julia_path, fortran_path, scope, grid)
    return NCDatasets.NCDataset(julia_path) do julia
        NCDatasets.NCDataset(fortran_path) do fortran
            Int.(julia["cell_id"][:]) == scope.cell_ids ||
                error("Julia reduced output is not in Representative order")
            Int.(fortran["cell_id"][:]) == scope.cell_ids ||
                error("Fortran reduced output is not in Representative order")
            Int.(julia["year"][:]) ==
            Int.(fortran["year"][:]) ==
            collect(1901:2014) || error("reduced annual coordinates differ")
            Int.(julia["sample_day"][:]) ==
            Int.(fortran["sample_day"][:]) ==
            native_corpse().REDUCED_SAMPLE_DAYS ||
                error("reduced fixed-daily coordinates differ")
            eligible = findall(native_corpse().eligible_cell, grid)
            eligible_grid = grid[eligible]
            years = Int.(julia["year"][:])
            sample_days = Int.(julia["sample_day"][:])
            reducer_variables = (
                "annual_mean" => native_corpse().REDUCED_STATE_VARIABLES,
                "end_of_year" => native_corpse().REDUCED_STATE_VARIABLES,
                "annual_total" => native_corpse().REDUCED_FLUX_VARIABLES,
                "fixed_daily_sample" => native_corpse().REDUCED_VARIABLES,
            )
            return Dict(
                reducer => Dict(
                    name => begin
                        variable = "$(reducer)__$(name)"
                        haskey(julia, variable) || error(
                            "Julia reduced output is missing $variable",
                        )
                        haskey(fortran, variable) || error(
                            "Fortran reduced output is missing $variable",
                        )
                        actual = Float64.(julia[variable][eligible, :])
                        expected = Float64.(fortran[variable][eligible, :])
                        size(actual) == size(expected) ||
                            error("$variable reduced shapes differ")
                        coordinate = reducer == "fixed_daily_sample" ?
                                     sample_days : years
                        population =
                            calibration_population(eligible_grid, reducer, coordinate)
                        repeated_grid, coordinates, coordinate_schema =
                            population
                        length(repeated_grid) == length(actual) ||
                            error("$reducer coordinates are not aligned")
                        calibration_record(
                            vec(actual),
                            vec(expected),
                            repeated_grid,
                            units = native_corpse().reduced_units(
                                only(
                                    filter(
                                        item -> item.name == name,
                                        variables,
                                    ),
                                ),
                                reducer,
                            ),
                            coordinate_schema,
                            coordinates,
                        )
                    end for name in getproperty.(variables, :name)
                ) for (reducer, variables) in reducer_variables
            )
        end
    end
end

"""
    generate(
        source_root,
        forcing_root,
        julia_output,
        fortran_root,
        scope_manifest,
        fortran_reduced,
        output_path,
    )

Derive the portable, Git-versioned mixed absolute/relative calibration for
every boundary variable and every retained historical reducer. Policy wiring
remains a separate explicit step.
"""
function generate(
    source_root,
    forcing_root,
    julia_output,
    fortran_root,
    scope_manifest,
    fortran_reduced,
    output_path,
)
    native_corpse().assert_single_threaded()
    scope = native_corpse().representative_scope(scope_manifest)
    setup = native_corpse().build_setup(
        source_root,
        forcing_root;
        cell_ids = scope.cell_ids,
    )
    native_corpse().native_casa().close_forcing!(setup.forcing.base)
    length(setup.grid) == 80 ||
        error("calibration requires the 80-cell Representative scope")
    count(native_corpse().eligible_cell, setup.grid) == 78 ||
        error("calibration requires exactly 78 eligible CORPSE cells")
    actual_gaps = Dict(
        point.cell_id => point.pft for
        point in setup.grid if !native_corpse().eligible_cell(point)
    )
    actual_gaps == scope.gaps ||
        error("calibration gaps differ from the reviewed CORPSE gaps")
    julia_reduced = joinpath(julia_output, "reduced_historical.nc")
    isfile(julia_reduced) || error("Julia reduced historical output is missing")
    isfile(fortran_reduced) ||
        error("Fortran reduced historical reference is missing")
    fortran_reduced_manifest = fortran_reduced * ".toml"
    isfile(fortran_reduced_manifest) ||
        error("Fortran reduced historical reference manifest is missing")

    variables = Dict{String, Any}()
    julia_sources = Dict{String, Any}()
    fortran_sources = Dict{String, Any}()
    for stage in native_corpse().canonical_stages()
        checkpoint, workflow = checkpoint_path(julia_output, stage)
        state, _ = ClimaLand.read_checkpoint(checkpoint; model = setup.model)
        pairs = native_corpse().boundary_pairs(
            state,
            stage,
            setup.grid,
            fortran_root,
        )
        variables[String(stage.name)] = Dict(
            name => calibration_record(
                pair.actual,
                pair.expected,
                pair.grid;
                units = "kg C m-2",
            ) for (name, pair) in pairs
        )
        fortran_stage = joinpath(
            fortran_root,
            "stages",
            native_corpse().stage_directory(stage),
        )
        julia_sources[String(stage.name)] = Dict(
            "checkpoint" =>
                source_record(checkpoint, "julia/$(stage.name)/checkpoint"),
            "workflow" =>
                source_record(workflow, "julia/$(stage.name)/workflow"),
        )
        fortran_sources[String(stage.name)] = Dict(
            "casa_boundary" => source_record(
                joinpath(fortran_stage, "casa_final.csv"),
                "fortran/$(native_corpse().stage_directory(stage))/casa_final.csv",
            ),
            "corpse_boundary" => source_record(
                joinpath(fortran_stage, "corpse_final.csv"),
                "fortran/$(native_corpse().stage_directory(stage))/corpse_final.csv",
            ),
            "metadata" => source_record(
                joinpath(fortran_stage, "stage_metadata.toml"),
                "fortran/$(native_corpse().stage_directory(stage))/stage_metadata.toml",
            ),
        )
    end
    reconstruction_report = joinpath(fortran_root, "reconstruction_report.toml")
    runner_report = joinpath(julia_output, "corpse_boundary_report.toml")
    run = TOML.parsefile(runner_report)
    get(run, "scope", nothing) == "representative" &&
        get(run, "grid_cells", nothing) == 80 &&
        get(run, "eligible_cells", nothing) == 78 ||
        error("Julia output is not a Representative CORPSE run")
    document = Dict(
        "schema_version" => 1,
        "calibration_id" => CALIBRATION_ID,
        "source" => "fresh_fortran_representative",
        "model" => "CORPSE",
        "scope" => "representative",
        "scope_cell_count" => 80,
        "eligible_cell_count" => 78,
        "eligibility_gaps" => scope.gap_entries,
        "ineligible_pfts" => collect(native_corpse().INELIGIBLE_PFTS),
        "comparison_variable_count" =>
            sum(native_corpse().comparison_variable_count()),
        "reducer_variable_count" =>
            length(native_corpse().REDUCED_VARIABLES),
        "state_reducer_variable_count" =>
            length(native_corpse().REDUCED_STATE_VARIABLES),
        "flux_reducer_variable_count" =>
            length(native_corpse().REDUCED_FLUX_VARIABLES),
        "method" => Dict(
            "error" => "e_i = abs(Julia_i - Fortran_i)",
            "reference_magnitude" => "x_i = abs(Fortran_i)",
            "selection" => "choose the smallest r >= 0 minimizing a(r) + r*mean(x)",
            "coefficient_constraints" => "fit atol >= 0 and rtol >= 0 solely from observed errors and absolute Fortran reference magnitudes",
            "numerical_padding" => "after the 5% fit, add 64*eps(Float64)*max(maximum(abs, Julia), maximum(abs, Fortran), floatmin(Float64)) to atol; add no rtol padding",
            "safety_margin" => "multiply both fitted coefficients by 1.05 before adding numerical padding",
            "acceptance" => "e_i <= atol + rtol*x_i for every eligible pair",
            "nonfinite" => "hard failure in any eligible Julia or Fortran pair",
            "globally_inapplicable_pfts" => "PFTs 11, 13, 15, and 17 map to Fortran vegetation category 0 in the pinned parameter table, so corpse_cycle is not executed for them",
            "representative_gaps" => "the immutable Representative scope contains two such cells: PFT 17 at cell 51 and PFT 11 at cell 3442",
            "outliers_per_variable" => 6,
            "population" => "all 78 eligible cells in the immutable 80-cell Representative scope",
            "boundary_population_per_variable" => 78,
            "annual_population_per_variable" => 78 * 114,
            "annual_flux_total_population_per_variable" => 78 * 114,
            "fixed_daily_population_per_variable" => 78 * 84,
            "flux_annual_total" => "daily kg C m-2 s-1 Julia fluxes are integrated over 86,400 seconds and converted to g C m-2 to match the sum of Fortran daily g C m-2 outputs",
        ),
        "execution" => Dict(
            "julia_threads" => Threads.nthreads(),
            "blas_threads" =>
                native_corpse().LinearAlgebra.BLAS.get_num_threads(),
            "timeout_seconds" => TIMEOUT_SECONDS,
            "report_is_ephemeral" => false,
            "portable_provenance" => true,
            "comparison_policy_modified" => false,
        ),
        "provenance" => Dict(
            "julia_runner_report" => source_record(
                runner_report,
                "julia/corpse_boundary_report.toml",
            ),
            "fortran_reconstruction_report" => source_record(
                reconstruction_report,
                "fortran/reconstruction_report.toml",
            ),
            "scope_manifest" => source_record(
                scope_manifest,
                "validation/scopes/representative.toml",
            ),
            "julia_reduced_historical" => source_record(
                julia_reduced,
                "julia/reduced_historical.nc",
            ),
            "fortran_reduced_historical" => source_record(
                fortran_reduced,
                "fortran/reduced_historical.nc",
            ),
            "fortran_reduced_historical_manifest" => source_record(
                fortran_reduced_manifest,
                "fortran/reduced_historical.nc.toml",
            ),
            "julia_stage" => julia_sources,
            "fortran_stage" => fortran_sources,
            "runner_source" => source_record(
                joinpath(@__DIR__, "native_corpse_c_reconstruction.jl"),
                "test/testbed_validation/native_corpse_c_reconstruction.jl",
            ),
            "calibration_source" => source_record(
                @__FILE__,
                "test/testbed_validation/generate_corpse_c_representative_calibration.jl",
            ),
        ),
        "stage" => variables,
        "reducer" => reduced_calibration(
            julia_reduced,
            fortran_reduced,
            scope,
            setup.grid,
        ),
    )
    mkpath(dirname(output_path))
    open(output_path, "w") do io
        TOML.print(io, document; sorted = true)
    end
    return output_path
end

run_with_timeout(command; timeout_seconds = TIMEOUT_SECONDS) =
    native_corpse().run_with_timeout(command; timeout_seconds)

function main(args = ARGS)
    worker = !isempty(args) && first(args) == "--worker"
    values = worker ? args[2:end] : args
    length(values) == 7 || error(
        "usage: generate_corpse_c_representative_calibration.jl SOURCE_ROOT FORCING_ROOT JULIA_OUTPUT FORTRAN_ROOT SCOPE_MANIFEST FORTRAN_REDUCED OUTPUT_TOML",
    )
    if worker
        println(generate(values...))
        return nothing
    end
    project = dirname(Base.active_project())
    command = addenv(
        `$(Base.julia_cmd()) --startup-file=no --project=$project $(@__FILE__) --worker $values`,
        "JULIA_NUM_THREADS" => "1",
        "OPENBLAS_NUM_THREADS" => "1",
    )
    run_with_timeout(command)
    return nothing
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    TestbedCORPSERepresentativeCalibration.main()
end
