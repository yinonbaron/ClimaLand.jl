module TestbedValidationRunner

import SHA
import TOML

include(joinpath(@__DIR__, "selected_casa_workflow.jl"))

# ============================================================================
# Command-line interface
# ============================================================================

const SCOPES = ("core", "smoke", "representative", "broad", "global")
const DEPRECATED_SCOPE_ALIASES =
    Dict("ordinary" => "core", "extended" => "smoke")
const MODELS = ("CORPSE", "MIMICS-C", "MIMICS-CN", "CASA-C", "CASA-CN")
const REFERENCE_MODES = ("pinned", "fresh")
const REPORT_FILENAME = "validation_report.toml"
const REFERENCE_OVERRIDE = "CLIMALAND_VALIDATION_CASA_C_REFERENCE"
const SCOPE_MANIFEST_DIRECTORY_OVERRIDE = "CLIMALAND_VALIDATION_SCOPE_MANIFEST_DIRECTORY"
const COMPARISON_POLICY_OVERRIDE = "CLIMALAND_VALIDATION_COMPARISON_POLICY"
const DEFAULT_REFERENCE = joinpath(
    @__DIR__,
    "fixtures",
    "selected_cells",
    "complete_casa_workflow.toml",
)
const SELECTED_CELL_MANIFEST =
    joinpath(@__DIR__, "fixtures", "selected_cells", "fixture.toml")
const DEFAULT_SCOPE_MANIFEST_DIRECTORY =
    joinpath(@__DIR__, "validation", "scopes")
const DEFAULT_COMPARISON_POLICY =
    joinpath(@__DIR__, "validation", "comparison_policy.toml")

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
    index < length(args) || throw(RunnerError("$option requires a value"))
    return args[index + 1]
end

function parse_models(value)
    value == "all" && return collect(MODELS)
    models = split(value, ','; keepempty = false)
    isempty(models) &&
        throw(RunnerError("--models requires at least one model"))
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
            workers > 0 || throw(RunnerError("workers must be positive"))
        elseif option == "--output"
            output = option_value(args, index, option)
        else
            throw(RunnerError("unknown option: $option"))
        end
        index += 2
    end
    if haskey(DEPRECATED_SCOPE_ALIASES, scope)
        canonical = DEPRECATED_SCOPE_ALIASES[scope]
        @warn "$scope is deprecated; use $canonical"
        scope = canonical
    end
    scope in SCOPES ||
        throw(RunnerError("scope must be one of $(join(SCOPES, ", "))"))
    reference_mode in REFERENCE_MODES || throw(
        RunnerError(
            "reference mode must be one of $(join(REFERENCE_MODES, ", "))",
        ),
    )
    return (; help = false, scope, models, reference_mode, workers, output)
end

# ============================================================================
# Validation Report
# ============================================================================

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

function parse_toml(path, description)
    isfile(path) || throw(RunnerError("$description is missing at $path"))
    try
        return TOML.parsefile(path)
    catch error
        throw(
            RunnerError(
                "$description is unreadable at $path: $(sprint(showerror, error))",
            ),
        )
    end
end

function scope_manifest_directory()
    return get(
        ENV,
        SCOPE_MANIFEST_DIRECTORY_OVERRIDE,
        DEFAULT_SCOPE_MANIFEST_DIRECTORY,
    )
end

function validate_scope_manifest(manifest, path, expected_name)
    get(manifest, "schema_version", nothing) == 1 ||
        throw(RunnerError("Scope Manifest at $path has an incompatible schema"))
    get(manifest, "name", nothing) == expected_name || throw(
        RunnerError(
            "Scope Manifest at $path declares name $(repr(get(manifest, "name", nothing))) instead of $expected_name",
        ),
    )
    cell_ids = try
        Int.(manifest["cell_ids"])
    catch
        throw(RunnerError("Scope Manifest at $path has invalid cell IDs"))
    end
    cell_ids == sort(unique(cell_ids)) || throw(
        RunnerError(
            "Scope Manifest at $path must declare unique cell IDs in deterministic order",
        ),
    )
    expected_count = expected_name == "core" ? 11 : 37
    length(cell_ids) == expected_count || throw(
        RunnerError(
            "$(titlecase(expected_name)) Scope must contain $expected_count cells, found $(length(cell_ids))",
        ),
    )
    selected_cells = TOML.parsefile(SELECTED_CELL_MANIFEST)["selection"]
    selected_key =
        expected_name == "core" ? "core_cell_ids" : "extended_cell_ids"
    cell_ids == Int.(selected_cells[selected_key]) || throw(
        RunnerError(
            "$(titlecase(expected_name)) Scope does not preserve the selected-cell collection",
        ),
    )
    partitions = get(manifest, "partition", Any[])
    length(partitions) == 1 ||
        throw(RunnerError("Scope Manifest at $path must declare one partition"))
    Int.(only(partitions)["cell_ids"]) == cell_ids || throw(
        RunnerError(
            "Scope Manifest at $path partition must cover every scope cell in order",
        ),
    )
    source_sha = get(
        get(manifest, "selection", Dict{String, Any}()),
        "source_manifest_sha256",
        nothing,
    )
    source_sha == sha256sum(SELECTED_CELL_MANIFEST) || throw(
        RunnerError(
            "Scope Manifest at $path does not match the selected-cell provenance",
        ),
    )
    gaps = get(manifest, "eligibility_gaps", Any[])
    seen_gaps = Set{Tuple{String, Int}}()
    for gap in gaps
        model = String(get(gap, "model", ""))
        cell_id = Int(get(gap, "cell_id", 0))
        reason = String(get(gap, "reason", ""))
        reviewed = get(gap, "reviewed", false)
        model in MODELS || throw(
            RunnerError("Scope Manifest at $path has an unknown gap model"),
        )
        cell_id in cell_ids || throw(
            RunnerError(
                "Scope Manifest at $path has an Eligibility Gap outside the scope",
            ),
        )
        !isempty(strip(reason)) && reviewed === true || throw(
            RunnerError(
                "Scope Manifest at $path has an unreviewed Eligibility Gap",
            ),
        )
        key = (model, cell_id)
        key in seen_gaps && throw(
            RunnerError("Scope Manifest at $path repeats an Eligibility Gap"),
        )
        push!(seen_gaps, key)
    end
    sort!(gaps; by = gap -> (String(gap["model"]), Int(gap["cell_id"])))
    return (; name = expected_name, cell_ids, gaps, path = abspath(path))
end

function load_scope_manifests(scope)
    directory = scope_manifest_directory()
    manifests = Dict(
        name => validate_scope_manifest(
            parse_toml(
                joinpath(directory, "$name.toml"),
                "$(titlecase(name)) Scope Manifest",
            ),
            joinpath(directory, "$name.toml"),
            name,
        ) for name in ("core", "smoke")
    )
    core_ids = manifests["core"].cell_ids
    smoke_ids = manifests["smoke"].cell_ids
    all(id -> id in smoke_ids, core_ids) && core_ids != smoke_ids || throw(
        RunnerError(
            "Nested Validation Scopes require Core to be a strict subset of Smoke",
        ),
    )
    return manifests[scope]
end

function comparison_policy()
    path = get(ENV, COMPARISON_POLICY_OVERRIDE, DEFAULT_COMPARISON_POLICY)
    policy = parse_toml(path, "Comparison Policy")
    get(policy, "schema_version", nothing) == 1 || throw(
        RunnerError("Comparison Policy at $path has an incompatible schema"),
    )
    acceptance = get(policy, "acceptance", Dict{String, Any}())
    get(acceptance, "eligible_nonfinite", nothing) == "fail" &&
        get(acceptance, "eligibility_gaps", nothing) ==
        "reviewed_scope_manifest_only" || throw(
        RunnerError(
            "Comparison Policy at $path has incompatible acceptance rules",
        ),
    )
    model = get(get(policy, "model", Dict{String, Any}()), "CASA-C", nothing)
    isnothing(model) &&
        throw(RunnerError("Comparison Policy at $path has no CASA-C policy"))
    required_rules = (
        "native_julia_initialization",
        "native_julia_boundary",
        "native_julia_historical",
        "fresh_fortran_boundary",
    )
    all(rule -> haskey(model, rule), required_rules) ||
        throw(RunnerError("Comparison Policy at $path is missing CASA-C rules"))
    budget_rtol = get(model, "budget_rtol", nothing)
    budget_rtol isa Real && isfinite(budget_rtol) && budget_rtol >= 0 || throw(
        RunnerError(
            "Comparison Policy at $path has invalid CASA-C budget rtol",
        ),
    )
    tolerance = Dict{String, Any}(
        rule => Dict(
            "atol" => Float64(model[rule]["atol"]),
            "rtol" => Float64(model[rule]["rtol"]),
        ) for rule in required_rules[1:3]
    )
    fresh = model["fresh_fortran_boundary"]
    fresh_rtol = get(fresh, "rtol", nothing)
    fresh_rtol isa Real && isfinite(fresh_rtol) && fresh_rtol >= 0 || throw(
        RunnerError(
            "Comparison Policy at $path has invalid fresh-Fortran rtol",
        ),
    )
    stages = ("prespin", "accelerated_spin", "normal_spin", "historical")
    stage_variables = nothing
    tolerance["fresh_fortran_boundary"] = Dict(
        stage => begin
            values = get(fresh, stage, nothing)
            values isa AbstractDict && !isempty(values) || throw(
                RunnerError(
                    "Comparison Policy at $path is missing fresh-Fortran $stage rules",
                ),
            )
            names = Set(String.(keys(values)))
            isnothing(stage_variables) ? (stage_variables = names) :
            names == stage_variables || throw(
                RunnerError(
                    "Comparison Policy at $path has inconsistent fresh-Fortran variables",
                ),
            )
            Dict(
                String(name) => begin
                    atol = values[name]
                    atol isa Real && isfinite(atol) && atol >= 0 ||
                        throw(
                            RunnerError(
                                "Comparison Policy at $path has an invalid tolerance",
                            ),
                        )
                    Dict(
                        "atol" => Float64(atol),
                        "rtol" => Float64(fresh_rtol),
                    )
                end for name in keys(values)
            )
        end for stage in stages
    )
    for rule in required_rules[1:3]
        rule_values = tolerance[rule]
        all(value -> isfinite(value) && value >= 0, values(rule_values)) ||
            throw(
                RunnerError(
                    "Comparison Policy at $path has an invalid tolerance",
                ),
            )
    end
    return (;
        policy,
        model,
        tolerance,
        budget_rtol = Float64(budget_rtol),
        path = abspath(path),
    )
end

model_eligibility_gaps(scope, model) =
    filter(gap -> gap["model"] == model, scope.gaps)

function eligible_cell_ids(scope, model)
    gap_ids =
        Set(Int(gap["cell_id"]) for gap in model_eligibility_gaps(scope, model))
    return filter(id -> id ∉ gap_ids, scope.cell_ids)
end

function initial_report(configuration, output_root, scope, policy)
    cell_ids = scope.cell_ids
    eligibility_gaps = model_eligibility_gaps(scope, "CASA-C")
    eligible_ids = eligible_cell_ids(scope, "CASA-C")
    return Dict(
        "schema_version" => 1,
        "scope" => Dict(
            "name" => configuration.scope,
            "cell_count" => length(cell_ids),
            "cell_ids" => cell_ids,
            "manifest" => scope.path,
            "manifest_sha256" => sha256sum(scope.path),
        ),
        "comparison_policy" => Dict(
            "id" => String(policy.policy["policy_id"]),
            "model" => "CASA-C",
            "path" => policy.path,
            "sha256" => sha256sum(policy.path),
            "acceptance" => policy.policy["acceptance"],
            "budget_rtol" => policy.budget_rtol,
            "applied_rules" => sort!(collect(String.(keys(policy.model)))),
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
                    "eligible_cells" => length(eligible_ids),
                    "compared_cells" => 0,
                    "eligibility_gaps" => eligibility_gaps,
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
    configuration.scope in ("core", "smoke") || throw(
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
    return reference
end

function validate_finite_reference_values!(
    value,
    location,
    reference_cell_ids,
    eligible_positions,
)
    if value isa AbstractDict
        for name in sort!(collect(String.(keys(value))))
            name == "sample_days" && continue
            validate_finite_reference_values!(
                value[name],
                "$location.$name",
                reference_cell_ids,
                eligible_positions,
            )
        end
    elseif value isa AbstractVector &&
           all(item -> item isa Real, value) &&
           length(value) % length(reference_cell_ids) == 0
        for position in eligible_positions
            for index in position:length(reference_cell_ids):length(value)
                isfinite(value[index]) && continue
                cell_id = reference_cell_ids[position]
                throw(
                    RunnerError(
                        "Pinned CASA-C reference has an eligible nonfinite reference value for CASA-C cell $cell_id at $location",
                    ),
                )
            end
        end
    end
    return nothing
end

function validate_eligible_reference_values(reference, scope)
    reference_cell_ids = try
        Int.(reference["cell_ids"])
    catch
        throw(RunnerError("Pinned CASA-C reference has invalid cell IDs"))
    end
    !isempty(reference_cell_ids) &&
        length(reference_cell_ids) == length(unique(reference_cell_ids)) ||
        throw(RunnerError("Pinned CASA-C reference has invalid cell IDs"))
    eligible_ids = eligible_cell_ids(scope, "CASA-C")
    positions = Int[]
    for cell_id in eligible_ids
        position = findfirst(==(cell_id), reference_cell_ids)
        isnothing(position) &&
            throw(RunnerError("Pinned CASA-C reference has no cell $cell_id"))
        push!(positions, position)
    end
    configuration = get(
        get(reference, "configuration", Dict{String, Any}()),
        "carbon_only",
        Dict{String, Any}(),
    )
    native = get(configuration, "native_julia", Dict{String, Any}())
    fresh = get(configuration, "fresh_fortran", Dict{String, Any}())
    validate_finite_reference_values!(
        native,
        "carbon_only.native_julia",
        reference_cell_ids,
        positions,
    )
    validate_finite_reference_values!(
        fresh,
        "carbon_only.fresh_fortran",
        reference_cell_ids,
        positions,
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
            get(passive, "verified", get(passive_carbon, "verified", false)) &&
            get(passive, "unaffected_verified", false) &&
            get(passive, "checkpoint_roundtrip_verified", false),
        "checkpoint_roundtrip" => all(
            getproperty.(result.stages, :checkpoint_roundtrip_verified),
        ),
    )
    return (; passed = all(values(checks)), checks)
end

function stage_casa(scope, pinned_reference, policy)
    collection = TestbedReferenceCellComparisons.selected_cell_collection(
        scope.name,
        eligible_cell_ids(scope, "CASA-C"),
    )
    TestbedSelectedCASAWorkflow.workflow_reference(
        :carbon_only,
        collection;
        path = pinned_reference,
        comparison_policy = policy.tolerance,
    )
    return collection
end

function run_casa!(
    report,
    output_root,
    configuration,
    pinned_reference,
    collection,
    policy,
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
        comparison_policy = policy.tolerance,
        budget_rtol = policy.budget_rtol,
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
    scope = try
        load_scope_manifests(configuration.scope)
    catch error
        error isa RunnerError || rethrow()
        println(stderr, "Validation Runner: ", error.message)
        return 2
    end
    policy = try
        comparison_policy()
    catch error
        error isa RunnerError || rethrow()
        println(stderr, "Validation Runner: ", error.message)
        return 2
    end
    report = initial_report(configuration, output_root, scope, policy)
    pinned_reference = reference_path()
    started = time_ns()
    try
        reference = validate_reference_file(pinned_reference)
        validate_eligible_reference_values(reference, scope)
        collection = try
            stage_casa(scope, pinned_reference, policy)
        catch error
            throw(
                RunnerError(
                    "Pinned CASA-C inputs are incompatible: $(sprint(showerror, error))",
                ),
            )
        end
        passed = run_casa!(
            report,
            output_root,
            configuration,
            pinned_reference,
            collection,
            policy,
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
