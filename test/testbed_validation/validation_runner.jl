module TestbedValidationRunner

import Pkg
import SHA
import TOML

include(joinpath(@__DIR__, "selected_casa_workflow.jl"))

# ============================================================================
# Command-line interface
# ============================================================================

const SCOPES = ("core", "smoke", "representative", "broad", "global")
const DEPRECATED_SCOPE_ALIASES =
    Dict("ordinary" => "core", "extended" => "smoke")
const AVAILABLE_SCOPE_METADATA = Dict(
    "core" => (; cell_count = 11, selection_key = "core_cell_ids"),
    "smoke" => (; cell_count = 37, selection_key = "extended_cell_ids"),
    "representative" => (; cell_count = 80, selection_key = nothing),
)
const MODELS = ("CORPSE", "MIMICS-C", "MIMICS-CN", "CASA-C", "CASA-CN")
const REFERENCE_MODES = ("pinned", "fresh")
const CASA_C_BOUNDARY_VARIABLES = Set((
    "casa_plant.c_labile",
    "casa_plant.c_leaf",
    "casa_plant.c_wood",
    "casa_plant.c_fine_root",
    "casa_soil.c_litter_metabolic",
    "casa_soil.c_litter_structural",
    "casa_soil.c_litter_cwd",
    "casa_soil.c_soil_microbial",
    "casa_soil.c_soil_slow",
    "casa_soil.c_soil_passive",
),)
const REPORT_FILENAME = "validation_report.toml"
const REFERENCE_OVERRIDE = "CLIMALAND_VALIDATION_CASA_C_REFERENCE"
const TIMEOUT_OVERRIDE = "CLIMALAND_VALIDATION_TIMEOUT_SECONDS"
const CHILD_PROCESS = "CLIMALAND_VALIDATION_RUNNER_CHILD"
const DEFAULT_TIMEOUT_SECONDS = 7200.0
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
const VALIDATION_ARTIFACTS = joinpath(@__DIR__, "validation", "Artifacts.toml")

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

sha256sum(path) = open(path) do io
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
    metadata = AVAILABLE_SCOPE_METADATA[expected_name]
    length(cell_ids) == metadata.cell_count || throw(
        RunnerError(
            "$(titlecase(expected_name)) Scope must contain $(metadata.cell_count) cells, found $(length(cell_ids))",
        ),
    )
    if !isnothing(metadata.selection_key)
        selected_cells = TOML.parsefile(SELECTED_CELL_MANIFEST)["selection"]
        cell_ids == Int.(selected_cells[metadata.selection_key]) || throw(
            RunnerError(
                "$(titlecase(expected_name)) Scope does not preserve the selected-cell collection",
            ),
        )
    end
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
    expected_source =
        expected_name == "representative" ?
        joinpath(DEFAULT_SCOPE_MANIFEST_DIRECTORY, "smoke.toml") :
        SELECTED_CELL_MANIFEST
    source_sha == sha256sum(expected_source) || throw(
        RunnerError(
            "Scope Manifest at $path does not match the selected-cell provenance",
        ),
    )
    gaps = collect(get(manifest, "eligibility_gaps", Any[]))
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
    directory = DEFAULT_SCOPE_MANIFEST_DIRECTORY
    manifests = Dict(
        name => validate_scope_manifest(
            parse_toml(
                joinpath(directory, "$name.toml"),
                "$(titlecase(name)) Scope Manifest",
            ),
            joinpath(directory, "$name.toml"),
            name,
        ) for name in ("core", "smoke", "representative")
    )
    core_ids = manifests["core"].cell_ids
    smoke_ids = manifests["smoke"].cell_ids
    all(id -> id in smoke_ids, core_ids) && core_ids != smoke_ids || throw(
        RunnerError(
            "Nested Validation Scopes require Core to be a strict subset of Smoke",
        ),
    )
    representative_ids = manifests["representative"].cell_ids
    all(id -> id in representative_ids, smoke_ids) &&
    smoke_ids != representative_ids || throw(
        RunnerError(
            "Nested Validation Scopes require Smoke to be a strict subset of Representative",
        ),
    )
    return manifests[scope]
end

function comparison_policy()
    path = DEFAULT_COMPARISON_POLICY
    policy = parse_toml(path, "Comparison Policy")
    get(policy, "schema_version", nothing) == 2 || throw(
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
    calibration_name = get(fresh, "calibration_manifest", nothing)
    calibration_name isa String &&
    basename(calibration_name) == calibration_name || throw(
        RunnerError(
            "Comparison Policy at $path has an invalid calibration manifest",
        ),
    )
    calibration_path = joinpath(dirname(path), calibration_name)
    calibration = parse_toml(calibration_path, "CASA-C Calibration")
    get(calibration, "schema_version", nothing) == 1 &&
    get(calibration, "source", nothing) == "fresh_fortran_full_grid" &&
    get(calibration, "cell_count", nothing) == 4263 || throw(
        RunnerError("CASA-C Calibration at $calibration_path is incompatible"),
    )
    calibrated_variables = get(calibration, "variable", Dict{String, Any}())
    stages = ("prespin", "accelerated_spin", "normal_spin", "historical")
    tolerance["fresh_fortran_boundary"] = Dict(
        stage => begin
            values = get(calibrated_variables, stage, nothing)
            values isa AbstractDict && !isempty(values) || throw(
                RunnerError(
                    "CASA-C Calibration at $calibration_path is missing $stage rules",
                ),
            )
            names = Set(String.(keys(values)))
            names == CASA_C_BOUNDARY_VARIABLES || throw(
                RunnerError(
                    "CASA-C Calibration at $calibration_path has incompatible boundary variables",
                ),
            )
            Dict(
                String(name) => begin
                    get(values[name], "finite_pair_count", nothing) == 4263 || throw(
                        RunnerError(
                            "CASA-C Calibration at $calibration_path is not full-grid",
                        ),
                    )
                    derived = get(values[name], "derived_policy", nothing)
                    derived isa AbstractDict || throw(
                        RunnerError(
                            "CASA-C Calibration at $calibration_path has no derived policy",
                        ),
                    )
                    atol = get(derived, "atol", nothing)
                    rtol = get(derived, "rtol", nothing)
                    atol isa Real &&
                    isfinite(atol) &&
                    atol >= 0 &&
                    rtol isa Real &&
                    isfinite(rtol) &&
                    rtol >= 0 &&
                    get(derived, "validation_failed_pairs", nothing) == 0 || throw(
                        RunnerError(
                            "CASA-C Calibration at $calibration_path has an invalid tolerance",
                        ),
                    )
                    Dict("atol" => Float64(atol), "rtol" => Float64(rtol))
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
        document = policy,
        model,
        tolerance,
        budget_rtol = Float64(budget_rtol),
        path = abspath(path),
        calibration,
        calibration_path = abspath(calibration_path),
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
            "id" => String(policy.document["policy_id"]),
            "model" => "CASA-C",
            "path" => policy.path,
            "sha256" => sha256sum(policy.path),
            "acceptance" => policy.document["acceptance"],
            "budget_rtol" => policy.budget_rtol,
            "applied_rules" => sort!(collect(String.(keys(policy.model)))),
            "fresh_fortran_boundary" =>
                policy.tolerance["fresh_fortran_boundary"],
            "calibration" => Dict(
                "id" => String(policy.calibration["calibration_id"]),
                "source" => String(policy.calibration["source"]),
                "cell_count" => Int(policy.calibration["cell_count"]),
                "units" => String(policy.calibration["units"]),
                "method" => policy.calibration["method"],
                "path" => policy.calibration_path,
                "sha256" => sha256sum(policy.calibration_path),
            ),
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
# Pinned CASA-C comparison
# ============================================================================

function validate_available(configuration)
    configuration.scope in ("core", "smoke", "representative") || throw(
        RunnerError(
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

function artifact_directory(name, description)
    hash = try
        Pkg.Artifacts.artifact_hash(name, VALIDATION_ARTIFACTS)
    catch error
        throw(
            RunnerError(
                "$description artifact binding is unreadable: $(sprint(showerror, error))",
            ),
        )
    end
    isnothing(hash) &&
        throw(RunnerError("$description artifact binding is missing"))
    Pkg.Artifacts.artifact_exists(hash) || throw(
        RunnerError(
            "$description artifact $hash is unavailable locally. Install the pinned artifact; pinned mode never computes it.",
        ),
    )
    return Pkg.Artifacts.artifact_path(hash), string(hash)
end

function reference_path(scope)
    haskey(ENV, REFERENCE_OVERRIDE) && return ENV[REFERENCE_OVERRIDE], nothing
    scope != "representative" && return DEFAULT_REFERENCE, nothing
    directory, hash = artifact_directory(
        "representative_casa_c_reference",
        "Representative CASA-C reference",
    )
    return joinpath(directory, "complete_casa_workflow.toml"), hash
end

function fixture_manifest_path(scope)
    scope != "representative" && return SELECTED_CELL_MANIFEST, nothing
    directory, hash =
        artifact_directory("representative_forcing", "Representative forcing")
    return joinpath(directory, "fixture.toml"), hash
end

function validate_fixture_scope_provenance(path, scope)
    scope.name == "representative" || return nothing
    fixture = parse_toml(path, "Representative forcing manifest")
    selection = get(fixture, "selection", Dict{String, Any}())
    get(selection, "scope_manifest_sha256", nothing) == sha256sum(scope.path) ||
        throw(
            RunnerError(
                "Representative forcing manifest does not match the frozen Scope Manifest",
            ),
        )
    return nothing
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

function validate_finite_reference_values(
    value,
    location,
    reference_cell_ids,
    eligible_positions,
)
    if value isa AbstractDict
        for name in sort!(collect(String.(keys(value))))
            name == "sample_days" && continue
            validate_finite_reference_values(
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
    validate_finite_reference_values(
        native,
        "carbon_only.native_julia",
        reference_cell_ids,
        positions,
    )
    validate_finite_reference_values(
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

function stage_casa(scope, pinned_reference, policy, fixture_manifest)
    collection = TestbedReferenceCellComparisons.selected_cell_collection(
        scope.name,
        eligible_cell_ids(scope, "CASA-C");
        manifest_path = fixture_manifest,
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
    started = time_ns()
    try
        pinned_reference, reference_artifact =
            reference_path(configuration.scope)
        reference = validate_reference_file(pinned_reference)
        validate_eligible_reference_values(reference, scope)
        fixture_manifest, forcing_artifact =
            fixture_manifest_path(configuration.scope)
        validate_fixture_scope_provenance(fixture_manifest, scope)
        collection = try
            stage_casa(scope, pinned_reference, policy, fixture_manifest)
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
        model_report = only(report["model"])
        model_report["forcing"] = Dict(
            "manifest" => abspath(fixture_manifest),
            "manifest_sha256" => sha256sum(fixture_manifest),
        )
        isnothing(forcing_artifact) ||
            (model_report["forcing"]["artifact"] = forcing_artifact)
        isnothing(reference_artifact) ||
            (model_report["reference"]["artifact"] = reference_artifact)
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

function timeout_seconds()
    value = get(ENV, TIMEOUT_OVERRIDE, string(DEFAULT_TIMEOUT_SECONDS))
    seconds = try
        parse(Float64, value)
    catch
        throw(
            RunnerError(
                "$TIMEOUT_OVERRIDE must be a positive number no greater than $(Int(DEFAULT_TIMEOUT_SECONDS))",
            ),
        )
    end
    0 < seconds <= DEFAULT_TIMEOUT_SECONDS || throw(
        RunnerError(
            "$TIMEOUT_OVERRIDE must be a positive number no greater than $(Int(DEFAULT_TIMEOUT_SECONDS))",
        ),
    )
    return seconds
end

function child_arguments(args)
    configuration = parse_args(args)
    configuration.help && return collect(args), nothing
    if isnothing(configuration.output)
        output_root = mktempdir(; cleanup = false)
        return [collect(args); "--output"; output_root], output_root
    end
    return collect(args), abspath(configuration.output)
end

function write_timeout_report(args, output_root, limit_seconds)
    configuration = parse_args(args)
    scope = load_scope_manifests(configuration.scope)
    policy = comparison_policy()
    report = initial_report(configuration, output_root, scope, policy)
    message = "hard timeout after $(round(limit_seconds; digits = 3)) seconds"
    report["outcome"] = "timed_out"
    report["seconds"] = limit_seconds
    report["error"] = message
    report["timeout"] =
        Dict("expired" => true, "limit_seconds" => limit_seconds)
    model_report = only(report["model"])
    model_report["outcome"] = "timed_out"
    model_report["seconds"] = limit_seconds
    path = write_report(output_root, report)
    println(stderr, "Validation Runner: ", message)
    print_summary(stderr, report, path)
    return nothing
end

function run_with_deadline(args = ARGS)
    child_args, output_root = try
        child_arguments(args)
    catch error
        error isa RunnerError || rethrow()
        println(stderr, "Validation Runner: ", error.message)
        return 2
    end
    isnothing(output_root) && return main(child_args)
    limit_seconds = try
        timeout_seconds()
    catch error
        error isa RunnerError || rethrow()
        println(stderr, "Validation Runner: ", error.message)
        return 2
    end
    project = dirname(Base.active_project())
    command = addenv(
        `$(Base.julia_cmd()) --startup-file=no --project=$project $(@__FILE__) $child_args`,
        CHILD_PROCESS => "1",
    )
    process = run(pipeline(ignorestatus(command); stdout, stderr); wait = false)
    status = timedwait(
        () -> process_exited(process),
        limit_seconds;
        pollint = min(0.1, limit_seconds / 10),
    )
    if status == :timed_out
        kill(process)
        wait(process)
        try
            write_timeout_report(child_args, output_root, limit_seconds)
        catch error
            println(
                stderr,
                "Validation Runner: timed out and could not write its report: ",
                sprint(showerror, error),
            )
        end
        return 124
    end
    wait(process)
    return process.exitcode
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    child = get(ENV, TestbedValidationRunner.CHILD_PROCESS, "0") == "1"
    exit(
        child ? TestbedValidationRunner.main() :
        TestbedValidationRunner.run_with_deadline(),
    )
end
