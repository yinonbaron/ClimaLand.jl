module TestbedValidationRunner

import SHA
import TOML

include(joinpath(@__DIR__, "selected_casa_workflow.jl"))

# ============================================================================
# Command-line interface
# ============================================================================

const SCOPES = ("core", "smoke", "representative", "broad", "global")
const MODELS = ("CORPSE", "MIMICS-C", "MIMICS-CN", "CASA-C", "CASA-CN")
const REFERENCE_MODES = ("pinned", "fresh")
const REPORT_FILENAME = "validation_report.toml"
const REFERENCE_OVERRIDE = "CLIMALAND_VALIDATION_CASA_C_REFERENCE"
const DEFAULT_REFERENCE = joinpath(
    @__DIR__,
    "fixtures",
    "selected_cells",
    "complete_casa_workflow.toml",
)
const SCOPE_MANIFEST = joinpath(
    @__DIR__,
    "fixtures",
    "selected_cells",
    "fixture.toml",
)

struct RunnerError <: Exception
    message::String
end

Base.showerror(io::IO, error::RunnerError) = print(io, error.message)

function usage(io = stdout)
    print(
        io,
        """
        Usage:
          julia --project=test test/testbed_validation/validation_runner.jl [options]

        Options:
          --scope NAME       core|smoke|representative|broad|global
          --models LIST      all or a comma-separated model list
          --reference MODE   pinned|fresh
          --workers N        positive model-worker limit
          --output PATH      report and model-output directory
          --help             show this help

        Defaults: representative scope, all models, pinned references, automatic
        worker count, and a temporary output directory.
        """,
    )
end

function option_value(args, index, option)
    index < length(args) ||
        throw(RunnerError("$option requires a value"))
    return args[index + 1]
end

function parse_models(value)
    value == "all" && return collect(MODELS)
    models = split(value, ','; keepempty = false)
    isempty(models) && throw(RunnerError("--models requires at least one model"))
    invalid = setdiff(models, MODELS)
    isempty(invalid) || throw(
        RunnerError(
            "models must be all or a comma-separated subset of $(join(MODELS, ", ")); invalid: $(join(invalid, ", "))",
        ),
    )
    return unique(models)
end

function parse_args(args)
    scope = "representative"
    models = collect(MODELS)
    reference_mode = "pinned"
    workers = min(length(MODELS), Sys.CPU_THREADS)
    output = nothing
    index = 1
    while index <= length(args)
        option = args[index]
        option == "--help" && return (; help = true)
        if option == "--scope"
            scope = option_value(args, index, option)
        elseif option == "--models"
            models = parse_models(option_value(args, index, option))
        elseif option == "--reference"
            reference_mode = option_value(args, index, option)
        elseif option == "--workers"
            value = option_value(args, index, option)
            workers = try
                parse(Int, value)
            catch
                throw(RunnerError("workers must be a positive integer"))
            end
            workers > 0 ||
                throw(RunnerError("workers must be positive"))
        elseif option == "--output"
            output = option_value(args, index, option)
        else
            throw(RunnerError("unknown option: $option"))
        end
        index += 2
    end
    scope in SCOPES ||
        throw(RunnerError("scope must be one of $(join(SCOPES, ", "))"))
    reference_mode in REFERENCE_MODES || throw(
        RunnerError(
            "reference mode must be one of $(join(REFERENCE_MODES, ", "))",
        ),
    )
    return (;
        help = false,
        scope,
        models,
        reference_mode,
        workers,
        output,
    )
end

# ============================================================================
# Validation Report
# ============================================================================

sha256sum(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

function core_cell_ids()
    manifest = TOML.parsefile(SCOPE_MANIFEST)
    return Int.(manifest["selection"]["core_cell_ids"])
end

function initial_report(configuration, output_root)
    cell_ids = core_cell_ids()
    return Dict(
        "schema_version" => 1,
        "scope" => Dict(
            "name" => configuration.scope,
            "cell_count" => length(cell_ids),
            "cell_ids" => cell_ids,
            "manifest" => abspath(SCOPE_MANIFEST),
            "manifest_sha256" => sha256sum(SCOPE_MANIFEST),
        ),
        "reference_mode" => configuration.reference_mode,
        "workers" => configuration.workers,
        "output" => abspath(output_root),
        "outcome" => "failed",
        "seconds" => 0.0,
        "model" => [
            Dict(
                "name" => "CASA-C",
                "reference_mode" => configuration.reference_mode,
                "coverage" => Dict(
                    "scope_cells" => length(cell_ids),
                    "eligible_cells" => length(cell_ids),
                    "compared_cells" => 0,
                    "eligibility_gaps" => Any[],
                ),
                "outcome" => "failed",
                "seconds" => 0.0,
            ),
        ],
    )
end

function write_report(output_root, report)
    mkpath(output_root)
    path = joinpath(output_root, REPORT_FILENAME)
    temporary = "$path.tmp"
    open(temporary, "w") do io
        TOML.print(io, report; sorted = true)
    end
    mv(temporary, path; force = true)
    return path
end

function print_summary(io, report, report_path)
    model = only(report["model"])
    coverage = model["coverage"]
    println(
        io,
        "Validation: $(report["outcome"]) | scope=$(report["scope"]["name"]) " *
        "| model=$(model["name"]) | coverage=$(coverage["compared_cells"])/$(coverage["scope_cells"]) " *
        "| reference=$(model["reference_mode"]) | seconds=$(round(report["seconds"]; digits = 3))",
    )
    println(io, "Validation Report: $report_path")
    return nothing
end

# ============================================================================
# Pinned Core CASA-C comparison
# ============================================================================

function validate_available(configuration)
    configuration.scope == "core" || throw(
        RunnerError(
            configuration.scope == "representative" ?
            "Representative Scope is not available yet; use --scope core" :
            "$(titlecase(configuration.scope)) Scope is not available yet; use --scope core",
        ),
    )
    configuration.models == ["CASA-C"] || throw(
        RunnerError(
            "only CASA-C is available in the first Validation Runner slice; use --models CASA-C",
        ),
    )
    configuration.reference_mode == "pinned" || throw(
        RunnerError(
            "Fresh Fortran References are not available yet; use --reference pinned",
        ),
    )
    return nothing
end

function reference_path()
    return get(ENV, REFERENCE_OVERRIDE, DEFAULT_REFERENCE)
end

function validate_reference_file(path)
    isfile(path) || throw(
        RunnerError(
            "Pinned CASA-C reference is missing at $path. Restore the pinned reference; pinned mode never falls back to fresh Fortran.",
        ),
    )
    reference = try
        TOML.parsefile(path)
    catch error
        throw(
            RunnerError(
                "Pinned CASA-C reference is unreadable at $path: $(sprint(showerror, error))",
            ),
        )
    end
    get(reference, "schema_version", nothing) == 1 || throw(
        RunnerError(
            "Pinned CASA-C reference at $path has an incompatible schema",
        ),
    )
    return nothing
end

function scientific_outcome(report, result)
    initialization =
        get(report, "initialization_comparison", Dict{String, Any}())
    boundaries = get(report, "boundary_comparison", Dict{String, Any}())
    carbon_budget = get(report, "carbon_budget", Dict{String, Any}())
    passive = get(report, "passive_restoration", Dict{String, Any}())
    passive_carbon = get(passive, "carbon", Dict{String, Any}())
    checks = Dict(
        "initialization" => get(initialization, "all_match", false),
        "fresh_fortran_boundaries" => all(
            get(
                get(
                    get(value, "source", Dict{String, Any}()),
                    "fresh_fortran",
                    Dict{String, Any}(),
                ),
                "all_match",
                false,
            ) for value in values(boundaries)
        ),
        "carbon_budget" => get(carbon_budget, "all_close", false),
        "passive_restoration" =>
            get(
                passive,
                "verified",
                get(passive_carbon, "verified", false),
            ) &&
            get(passive, "unaffected_verified", false) &&
            get(passive, "checkpoint_roundtrip_verified", false),
        "checkpoint_roundtrip" =>
            all(getproperty.(result.stages, :checkpoint_roundtrip_verified)),
    )
    return (; passed = all(values(checks)), checks)
end

function stage_core_casa(pinned_reference)
    manifest = TOML.parsefile(SCOPE_MANIFEST)
    collection = TestbedReferenceCellComparisons.selected_cell_collection(
        "core",
        manifest["selection"]["core_cell_ids"],
    )
    TestbedSelectedCASAWorkflow.workflow_reference(
        :carbon_only,
        collection;
        path = pinned_reference,
    )
    return collection
end

function run_core_casa!(
    report,
    output_root,
    configuration,
    pinned_reference,
    collection,
)
    started = time_ns()
    result = TestbedSelectedCASAWorkflow.run_selected_case(
        joinpath(output_root, "CASA-C");
        configuration = :carbon_only,
        collection,
        concurrency_budget = TestbedReferenceCellComparisons.ConcurrencyBudget(
            configuration.workers,
        ),
        reference_path = pinned_reference,
    )
    seconds = (time_ns() - started) / 1e9
    scientific_report = TOML.parsefile(result.report)
    outcome = scientific_outcome(scientific_report, result)
    model_report = only(report["model"])
    model_report["coverage"]["compared_cells"] =
        model_report["coverage"]["eligible_cells"]
    model_report["outcome"] = outcome.passed ? "passed" : "failed"
    model_report["seconds"] = seconds
    model_report["comparison_report"] = abspath(result.report)
    model_report["comparison"] = outcome.checks
    model_report["reference"] = Dict(
        "path" => abspath(pinned_reference),
        "sha256" => sha256sum(pinned_reference),
    )
    report["outcome"] = model_report["outcome"]
    report["seconds"] = seconds
    return outcome.passed
end

# ============================================================================
# Entry point
# ============================================================================

function main(args = ARGS)
    configuration = try
        parsed = parse_args(args)
        parsed.help || validate_available(parsed)
        parsed
    catch error
        error isa RunnerError || rethrow()
        println(stderr, "Validation Runner: ", error.message)
        return 2
    end
    if configuration.help
        usage()
        return 0
    end

    output_root =
        isnothing(configuration.output) ? mktempdir(; cleanup = false) :
        abspath(configuration.output)
    report = initial_report(configuration, output_root)
    pinned_reference = reference_path()
    started = time_ns()
    try
        validate_reference_file(pinned_reference)
        collection = try
            stage_core_casa(pinned_reference)
        catch error
            throw(
                RunnerError(
                    "Pinned CASA-C inputs are incompatible: $(sprint(showerror, error))",
                ),
            )
        end
        passed = run_core_casa!(
            report,
            output_root,
            configuration,
            pinned_reference,
            collection,
        )
        report_path = write_report(output_root, report)
        print_summary(stdout, report, report_path)
        return passed ? 0 : 1
    catch error
        seconds = (time_ns() - started) / 1e9
        report["seconds"] = seconds
        only(report["model"])["seconds"] = seconds
        report["error"] = sprint(showerror, error)
        report_path = write_report(output_root, report)
        println(stderr, "Validation Runner: ", report["error"])
        print_summary(stderr, report, report_path)
        return error isa RunnerError ? 2 : 1
    end
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(TestbedValidationRunner.main())
end
