if !isdefined(@__MODULE__, :TestbedNativeCORPSECReconstruction)
    include(joinpath(@__DIR__, "native_corpse_c_reconstruction.jl"))
end

module TestbedCORPSEFullGridCalibration

import SHA
import Statistics
import TOML

import ClimaLand

const TIMEOUT_SECONDS = 2 * 60 * 60

native_corpse() =
    getfield(parentmodule(@__MODULE__), :TestbedNativeCORPSECReconstruction)

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

function right_derivative(r, errors, references, absolute_floor)
    residuals = errors .- r .* references
    maximum_residual = maximum(residuals)
    maximum_value = max(absolute_floor, maximum_residual)
    slopes = Float64[]
    absolute_floor == maximum_value &&
        push!(slopes, Statistics.mean(references))
    for index in eachindex(residuals)
        residuals[index] == maximum_value &&
            push!(slopes, Statistics.mean(references) - references[index])
    end
    return maximum(slopes)
end

function calibrated_envelope(errors, references; absolute_floor)
    floor = absolute_floor + 64eps(Float64)
    relative = 0.0
    if right_derivative(relative, errors, references, floor) < 0
        upper = eps(Float64)
        while right_derivative(upper, errors, references, floor) < 0
            upper *= 2
            isfinite(upper) ||
                error("unable to bracket calibrated relative tolerance")
        end
        lower = 0.0
        for _ in 1:256
            middle = (lower + upper) / 2
            if right_derivative(middle, errors, references, floor) < 0
                lower = middle
            else
                upper = middle
            end
        end
        relative = upper
    end
    absolute = max(floor, maximum(errors .- relative .* references))
    atol = 1.05absolute + 64eps(Float64)
    rtol = 1.05relative
    all(errors .<= atol .+ rtol .* references) ||
        error("calibrated tolerance does not enclose every eligible pair")
    return (;
        atol,
        rtol,
        raw_atol = absolute,
        raw_rtol = relative,
        absolute_floor = floor,
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
    absolute_floor,
    quantity = "c",
)
    length(actual) == length(expected) == length(grid) ||
        error("calibration requires aligned eligible cell pairs")
    isempty(actual) && error("calibration requires at least one eligible pair")
    all(isfinite, actual) ||
        error("eligible Julia full-grid boundary contains a nonfinite value")
    all(isfinite, expected) ||
        error("eligible Fortran full-grid boundary contains a nonfinite value")

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
    envelope = calibrated_envelope(errors, references; absolute_floor)
    residuals = errors .- envelope.raw_rtol .* references
    maximum_residual = maximum(residuals)
    active_tolerance = 256eps(Float64) * max(1.0, abs(maximum_residual))
    active =
        maximum_residual + active_tolerance >= envelope.absolute_floor ?
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
        Dict(
            "rank" => rank,
            "cell_id" => grid[index].cell_id,
            "pft" => grid[index].pft,
            "julia_kg_$(quantity)_m2" => actual[index],
            "fortran_kg_$(quantity)_m2" => expected[index],
            "absolute_error_kg_$(quantity)_m2" => errors[index],
            "relative_error" =>
                iszero(references[index]) ? "undefined_zero_reference" :
                errors[index] / references[index],
        ) for (rank, index) in enumerate(order[1:outlier_count])
    ]
    return Dict(
        "finite_pair_count" => length(errors),
        "absolute_error_kg_$(quantity)_m2" => distribution(errors),
        "relative_error" => relative_distribution,
        "absolute_reference_kg_$(quantity)_m2" => distribution(references),
        "active_constraint_cell_ids" =>
            [grid[index].cell_id for index in active],
        "active_constraint_objective_slopes" => [
            Statistics.mean(references) - references[index] for index in active
        ],
        "floor_constraint_active" => isapprox(
            envelope.absolute_floor,
            max(envelope.absolute_floor, maximum_residual);
            atol = active_tolerance,
            rtol = 0,
        ),
        "active_constraint" => isempty(active) ? "absolute_floor" : "cell_pair",
        "top_outlier" => outliers,
        "derived_policy" => Dict(
            "atol" => envelope.atol,
            "rtol" => envelope.rtol,
            "raw_atol" => envelope.raw_atol,
            "raw_rtol" => envelope.raw_rtol,
            "absolute_floor" => envelope.absolute_floor,
            "raw_objective" =>
                envelope.raw_atol +
                envelope.raw_rtol * Statistics.mean(references),
            "validation_failed_pairs" => count(
                errors .> envelope.atol .+ envelope.rtol .* references,
            ),
        ),
    )
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
    return Dict(
        "id" => id,
        "path" => abspath(path),
        "sha256" => sha256sum(path),
    )
end

"""
    generate(source_root, forcing_root, julia_output, fortran_root, output_path)

Derive an ephemeral mixed absolute/relative envelope independently for every
stage and every one of the 5 CASA and 36 cohort-resolved CORPSE variables.
This function never edits the Git-versioned comparison policy.
"""
function generate(
    source_root,
    forcing_root,
    julia_output,
    fortran_root,
    output_path,
)
    native_corpse().assert_single_threaded()
    setup = native_corpse().build_setup(source_root, forcing_root)
    native_corpse().native_casa().close_forcing!(setup.forcing.base)
    length(setup.grid) == 4263 || error("calibration requires the global grid")
    count(native_corpse().eligible_cell, setup.grid) == 2970 ||
        error("calibration requires exactly 2,970 eligible CORPSE cells")

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
                absolute_floor = pair.absolute_floor,
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
    document = Dict(
        "schema_version" => 1,
        "calibration_id" => "corpse-c-fresh-fortran-full-grid-v1",
        "source" => "issue-44-fresh-fortran-full-grid",
        "model" => "CORPSE",
        "grid_cell_count" => 4263,
        "eligible_cell_count" => 2970,
        "ineligible_pfts" => collect(native_corpse().INELIGIBLE_PFTS),
        "comparison_variable_count" =>
            sum(native_corpse().comparison_variable_count()),
        "method" => Dict(
            "error" => "e_i = abs(Julia_i - Fortran_i)",
            "reference_magnitude" => "x_i = abs(Fortran_i)",
            "selection" => "choose the smallest r >= 0 minimizing a(r) + r*mean(x)",
            "absolute_floor_casa_kg_c_m2" => 5e-10,
            "absolute_floor_corpse_kg_c_m2" => 5e-7,
            "safety_margin" => "multiply both raw coefficients by 1.05; add 64eps(Float64) to atol",
            "acceptance" => "e_i <= atol + rtol*x_i for every eligible pair",
            "nonfinite" => "hard failure in any eligible Julia or Fortran pair",
            "excluded_pfts" => "11, 13, 15, and 17; Fortran ice/water category",
            "outliers_per_variable" => 6,
        ),
        "execution" => Dict(
            "julia_threads" => Threads.nthreads(),
            "blas_threads" =>
                native_corpse().LinearAlgebra.BLAS.get_num_threads(),
            "timeout_seconds" => TIMEOUT_SECONDS,
            "report_is_ephemeral" => true,
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
            "julia_stage" => julia_sources,
            "fortran_stage" => fortran_sources,
            "runner_source" => source_record(
                joinpath(@__DIR__, "native_corpse_c_reconstruction.jl"),
                "test/testbed_validation/native_corpse_c_reconstruction.jl",
            ),
            "calibration_source" => source_record(
                @__FILE__,
                "test/testbed_validation/generate_corpse_c_full_grid_calibration.jl",
            ),
        ),
        "stage" => variables,
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
    length(values) == 5 || error(
        "usage: generate_corpse_c_full_grid_calibration.jl SOURCE_ROOT FORCING_ROOT JULIA_OUTPUT FORTRAN_ROOT OUTPUT_TOML",
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
    TestbedCORPSEFullGridCalibration.main()
end
