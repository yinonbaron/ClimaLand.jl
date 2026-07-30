module TestbedValidationRunner

import Pkg
import SHA
import TOML
import NCDatasets

include(joinpath(@__DIR__, "selected_casa_workflow.jl"))
include(joinpath(@__DIR__, "native_casa_cn_reconstruction.jl"))

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
const CASA_CN_BOUNDARY_VARIABLES = union(
    CASA_C_BOUNDARY_VARIABLES,
    Set((
        "casa_plant.n_leaf",
        "casa_plant.n_wood",
        "casa_plant.n_fine_root",
        "casa_soil.n_litter_metabolic",
        "casa_soil.n_litter_structural",
        "casa_soil.n_litter_cwd",
        "casa_soil.n_soil_microbial",
        "casa_soil.n_soil_slow",
        "casa_soil.n_soil_passive",
        "casa_soil.n_mineral",
    )),
)
const CASA_CN_ANNUAL_MEAN_VARIABLES =
    setdiff(CASA_CN_BOUNDARY_VARIABLES, Set(("casa_plant.c_labile",)))
const CASA_CN_ANNUAL_TOTAL_VARIABLES = Set((
    "diagnostic.cgpp",
    "diagnostic.cnpp",
    "diagnostic.cresp",
    "diagnostic.c_litter_metabolic_input",
    "diagnostic.c_litter_structural_input",
    "diagnostic.c_passive_input",
    "diagnostic.n_deposition",
    "diagnostic.n_fixation",
    "diagnostic.n_plant_uptake",
    "diagnostic.n_leaching",
    "diagnostic.n_gaseous_loss",
    "diagnostic.n_litter_mineralization",
    "diagnostic.n_soil_mineralization",
    "diagnostic.n_soil_immobilization",
    "diagnostic.n_net_mineralization",
    "diagnostic.n_litter_metabolic_input",
))
const CASA_CN_DAILY_VARIABLES = union(
    CASA_CN_BOUNDARY_VARIABLES,
    CASA_CN_ANNUAL_TOTAL_VARIABLES,
    Set(("diagnostic.n_litter_structural_input",)),
)
const CASA_CN_FRESH_DAILY_VARIABLES =
    union(CASA_CN_ANNUAL_MEAN_VARIABLES, CASA_CN_ANNUAL_TOTAL_VARIABLES)
const REPORT_FILENAME = "validation_report.toml"
const REFERENCE_OVERRIDE = Dict(
    "CASA-C" => "CLIMALAND_VALIDATION_CASA_C_REFERENCE",
    "CASA-CN" => "CLIMALAND_VALIDATION_CASA_CN_REFERENCE",
)
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

function comparison_policy(model_name = "CASA-C")
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
    model = get(get(policy, "model", Dict{String, Any}()), model_name, nothing)
    isnothing(model) && throw(
        RunnerError("Comparison Policy at $path has no $model_name policy"),
    )
    required_rules = (
        "native_julia_initialization",
        "native_julia_boundary",
        "native_julia_historical",
        "fresh_fortran_boundary",
    )
    all(rule -> haskey(model, rule), required_rules) || throw(
        RunnerError("Comparison Policy at $path is missing $model_name rules"),
    )
    budget_rtol = get(model, "budget_rtol", nothing)
    budget_rtol isa Real && isfinite(budget_rtol) && budget_rtol >= 0 || throw(
        RunnerError(
            "Comparison Policy at $path has invalid $model_name budget rtol",
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
    calibration = parse_toml(calibration_path, "$model_name Calibration")
    get(calibration, "schema_version", nothing) == 1 &&
        get(calibration, "source", nothing) == "fresh_fortran_full_grid" &&
        get(calibration, "cell_count", nothing) == 4263 || throw(
        RunnerError(
            "$model_name Calibration at $calibration_path is incompatible",
        ),
    )
    raw_absolute =
        get(get(calibration, "method", Dict{String, Any}()), "raw_absolute", "")
    occursin("a(r) = max(0", raw_absolute) &&
        !occursin("5e-10", raw_absolute) || throw(
        RunnerError(
            "$model_name Calibration at $calibration_path declares an obsolete absolute floor",
        ),
    )
    calibrated_variables = get(calibration, "variable", Dict{String, Any}())
    boundary_variables =
        model_name == "CASA-C" ? CASA_C_BOUNDARY_VARIABLES :
        CASA_CN_BOUNDARY_VARIABLES
    stages = ("prespin", "accelerated_spin", "normal_spin", "historical")
    tolerance["fresh_fortran_boundary"] = Dict(
        stage => begin
            values = get(calibrated_variables, stage, nothing)
            values isa AbstractDict && !isempty(values) || throw(
                RunnerError(
                    "$model_name Calibration at $calibration_path is missing $stage rules",
                ),
            )
            names = Set(String.(keys(values)))
            names == boundary_variables || throw(
                RunnerError(
                    "$model_name Calibration at $calibration_path has incompatible boundary variables",
                ),
            )
            Dict(
                String(name) => begin
                    get(values[name], "finite_pair_count", nothing) == 4263 || throw(
                        RunnerError(
                            "$model_name Calibration at $calibration_path is not full-grid",
                        ),
                    )
                    derived = get(values[name], "derived_policy", nothing)
                    derived isa AbstractDict || throw(
                        RunnerError(
                            "$model_name Calibration at $calibration_path has no derived policy",
                        ),
                    )
                    get(values[name], "units", nothing) isa String && !haskey(derived, "absolute_floor") ||
                        throw(
                            RunnerError(
                                "$model_name Calibration at $calibration_path has incomplete boundary diagnostics",
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
                            "$model_name Calibration at $calibration_path has an invalid tolerance",
                        ),
                    )
                    Dict("atol" => Float64(atol), "rtol" => Float64(rtol))
                end for name in keys(values)
            )
        end for stage in stages
    )
    if model_name == "CASA-CN"
        for rule in (
            "native_julia_annual",
            "fresh_fortran_annual",
            "fresh_fortran_daily",
            "annual_reducers",
            "fixed_daily_samples",
            "invalid_oracle_variables",
            "invalid_oracle_windows",
        )
            haskey(model, rule) || throw(
                RunnerError(
                    "Comparison Policy at $path is missing $model_name $rule",
                ),
            )
        end
        get(model["fresh_fortran_annual"], "calibration_manifest", nothing) ==
        calibration_name || throw(
            RunnerError(
                "Comparison Policy at $path has incompatible $model_name annual calibration",
            ),
        )
        get(model["fresh_fortran_daily"], "calibration_manifest", nothing) ==
        calibration_name || throw(
            RunnerError(
                "Comparison Policy at $path has incompatible $model_name daily calibration",
            ),
        )
        tolerance["native_julia_annual"] = Dict(
            "atol" => Float64(model["native_julia_annual"]["atol"]),
            "rtol" => Float64(model["native_julia_annual"]["rtol"]),
        )
        annual_variables =
            get(calibration, "annual_variable", Dict{String, Any}())
        isempty(annual_variables) && throw(
            RunnerError(
                "$model_name Calibration at $calibration_path has no annual rules",
            ),
        )
        annual_tolerance = Dict(
            "annual_mean" => Dict{String, Any}(),
            "annual_total" => Dict{String, Any}(),
        )
        for (key, values) in annual_variables
            reducer, name = split(key, '.'; limit = 2)
            reducer in keys(annual_tolerance) || throw(
                RunnerError(
                    "$model_name Calibration at $calibration_path has an invalid annual reducer",
                ),
            )
            get(values, "finite_pair_count", nothing) == 4263 * 114 || throw(
                RunnerError(
                    "$model_name Calibration at $calibration_path is not full-grid annual",
                ),
            )
            derived = get(values, "derived_policy", Dict{String, Any}())
            get(values, "units", nothing) isa String &&
                !haskey(derived, "absolute_floor") || throw(
                RunnerError(
                    "$model_name Calibration at $calibration_path has incomplete annual diagnostics",
                ),
            )
            atol = get(derived, "atol", nothing)
            rtol = get(derived, "rtol", nothing)
            atol isa Real &&
                rtol isa Real &&
                isfinite(atol) &&
                isfinite(rtol) &&
                atol >= 0 &&
                rtol >= 0 &&
                get(derived, "validation_failed_pairs", nothing) == 0 || throw(
                RunnerError(
                    "$model_name Calibration at $calibration_path has an invalid annual tolerance",
                ),
            )
            annual_tolerance[reducer][name] =
                Dict("atol" => Float64(atol), "rtol" => Float64(rtol))
        end
        Set(keys(annual_tolerance["annual_mean"])) ==
        CASA_CN_ANNUAL_MEAN_VARIABLES &&
            Set(keys(annual_tolerance["annual_total"])) ==
            CASA_CN_ANNUAL_TOTAL_VARIABLES || throw(
            RunnerError(
                "$model_name Calibration at $calibration_path has incompatible annual variables",
            ),
        )
        reducers = model["annual_reducers"]
        get(get(reducers, "state_pool", Dict{String, Any}()), "reducers", []) ==
        ["annual_mean", "end_of_year"] &&
            get(get(reducers, "flux", Dict{String, Any}()), "reducers", []) ==
            ["annual_total"] &&
            get(get(reducers, "budget", Dict{String, Any}()), "reducers", []) ==
            ["maximum_absolute_residual"] || throw(
            RunnerError(
                "Comparison Policy at $path has incompatible $model_name annual reducers",
            ),
        )
        samples = model["fixed_daily_samples"]
        get(samples, "years", []) == [1901, 1957, 2014] &&
            get(samples, "months", []) == [1, 4, 7, 10] &&
            get(samples, "days_per_window", nothing) == 7 &&
            get(samples, "sample_count_per_variable_cell", nothing) == 84 ||
            throw(
                RunnerError(
                    "Comparison Policy at $path has incompatible $model_name fixed daily samples",
                ),
            )
        invalid = model["invalid_oracle_variables"]
        Set(keys(invalid)) == Set(("nLitInptStruc",)) &&
            get(invalid["nLitInptStruc"], "scope", nothing) ==
            "fresh_fortran" &&
            get(invalid["nLitInptStruc"], "kind", nothing) ==
            "variable_level" &&
            get(invalid["nLitInptStruc"], "reviewed", false) === true || throw(
            RunnerError(
                "Comparison Policy at $path has incompatible $model_name invalid-oracle variables",
            ),
        )
        window_gap = get(
            model["invalid_oracle_windows"],
            "fresh_fortran_fixed_daily",
            Dict{String, Any}(),
        )
        get(window_gap, "scope", nothing) == "fresh_fortran" &&
            get(window_gap, "kind", nothing) == "time_window" &&
            get(window_gap, "required_years", []) == [1901, 1957, 2014] &&
            get(window_gap, "available_years", []) == [1901, 2014] &&
            get(window_gap, "missing_years", []) == [1957] &&
            get(window_gap, "comparison", nothing) ==
            "missing_window_native_julia_only" &&
            get(window_gap, "reviewed", false) === true || throw(
            RunnerError(
                "Comparison Policy at $path has incompatible $model_name invalid-oracle windows",
            ),
        )
        tolerance["fresh_fortran_annual"] = annual_tolerance
        daily_variables =
            get(calibration, "daily_variable", Dict{String, Any}())
        Set(keys(daily_variables)) ==
        union(CASA_CN_ANNUAL_MEAN_VARIABLES, CASA_CN_ANNUAL_TOTAL_VARIABLES) ||
            throw(
                RunnerError(
                    "$model_name Calibration at $calibration_path has incompatible daily variables",
                ),
            )
        tolerance["fresh_fortran_historical"] = Dict(
            String(name) => begin
                get(values, "finite_pair_count", nothing) == 4263 * 56 || throw(
                    RunnerError(
                        "$model_name Calibration at $calibration_path is not full-grid daily",
                    ),
                )
                derived =
                    get(values, "derived_policy", Dict{String, Any}())
                get(values, "units", nothing) isa String &&
                    !haskey(derived, "absolute_floor") || throw(
                    RunnerError(
                        "$model_name Calibration at $calibration_path has incomplete daily diagnostics",
                    ),
                )
                atol = get(derived, "atol", nothing)
                rtol = get(derived, "rtol", nothing)
                atol isa Real &&
                    rtol isa Real &&
                    isfinite(atol) &&
                    isfinite(rtol) &&
                    atol >= 0 &&
                    rtol >= 0 &&
                    get(derived, "validation_failed_pairs", nothing) == 0 || throw(
                    RunnerError(
                        "$model_name Calibration at $calibration_path has an invalid daily tolerance",
                    ),
                )
                Dict("atol" => Float64(atol), "rtol" => Float64(rtol))
            end for (name, values) in daily_variables
        )
    end
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
    model_name =
        hasproperty(configuration, :models) ? only(configuration.models) :
        "CASA-C"
    cell_ids = scope.cell_ids
    eligibility_gaps = model_eligibility_gaps(scope, model_name)
    eligible_ids = eligible_cell_ids(scope, model_name)
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
            "model" => model_name,
            "path" => policy.path,
            "sha256" => sha256sum(policy.path),
            "acceptance" => policy.document["acceptance"],
            "budget_rtol" => policy.budget_rtol,
            "applied_rules" => sort!(collect(String.(keys(policy.model)))),
            "fresh_fortran_boundary" =>
                policy.tolerance["fresh_fortran_boundary"],
            "fresh_fortran_annual" => get(
                policy.tolerance,
                "fresh_fortran_annual",
                Dict{String, Any}(),
            ),
            "fresh_fortran_historical" => get(
                policy.tolerance,
                "fresh_fortran_historical",
                Dict{String, Any}(),
            ),
            "calibration" => Dict(
                "id" => String(policy.calibration["calibration_id"]),
                "source" => String(policy.calibration["source"]),
                "cell_count" => Int(policy.calibration["cell_count"]),
                "units" => String(policy.calibration["units"]),
                "method" => policy.calibration["method"],
                "path" => policy.calibration_path,
                "sha256" => sha256sum(policy.calibration_path),
            ),
            "annual_reducers" =>
                get(policy.model, "annual_reducers", Dict{String, Any}()),
            "fixed_daily_samples" => get(
                policy.model,
                "fixed_daily_samples",
                Dict{String, Any}(),
            ),
            "invalid_oracle_variables" => get(
                policy.model,
                "invalid_oracle_variables",
                Dict{String, Any}(),
            ),
            "invalid_oracle_windows" => get(
                policy.model,
                "invalid_oracle_windows",
                Dict{String, Any}(),
            ),
        ),
        "reference_mode" => configuration.reference_mode,
        "workers" => configuration.workers,
        "output" => abspath(output_root),
        "outcome" => "failed",
        "seconds" => 0.0,
        "model" => [
            Dict(
                "name" => model_name,
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
    length(configuration.models) == 1 &&
        only(configuration.models) in ("CASA-C", "CASA-CN") || throw(
        RunnerError(
            "only one of CASA-C or CASA-CN is available in this Validation Runner slice; select one explicitly",
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

function reference_path(scope, model = "CASA-C")
    override = REFERENCE_OVERRIDE[model]
    haskey(ENV, override) && return ENV[override], nothing
    scope != "representative" &&
        model == "CASA-C" &&
        return DEFAULT_REFERENCE, nothing
    artifact_name =
        model == "CASA-C" ? "representative_casa_c_reference" :
        "representative_casa_cn_reference"
    directory, hash =
        artifact_directory(artifact_name, "Representative $model reference")
    return joinpath(directory, "complete_casa_workflow.toml"), hash
end

function fixture_manifest_path(scope, model = "CASA-C")
    scope != "representative" &&
        model == "CASA-C" &&
        return SELECTED_CELL_MANIFEST, nothing
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

function validate_reference_file(path, model = "CASA-C")
    isfile(path) || throw(
        RunnerError(
            "Pinned $model reference is missing at $path. Restore the pinned reference; pinned mode never falls back to fresh Fortran.",
        ),
    )
    reference = try
        TOML.parsefile(path)
    catch error
        throw(
            RunnerError(
                "Pinned $model reference is unreadable at $path: $(sprint(showerror, error))",
            ),
        )
    end
    get(reference, "schema_version", nothing) == 1 || throw(
        RunnerError(
            "Pinned $model reference at $path has an incompatible schema",
        ),
    )
    return reference
end

function validate_finite_reference_values(
    value,
    location,
    reference_cell_ids,
    eligible_positions,
    model = "CASA-C",
)
    if value isa AbstractDict
        for name in sort!(collect(String.(keys(value))))
            name == "sample_days" && continue
            validate_finite_reference_values(
                value[name],
                "$location.$name",
                reference_cell_ids,
                eligible_positions,
                model,
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
                        "Pinned $model reference has an eligible nonfinite reference value for $model cell $cell_id at $location",
                    ),
                )
            end
        end
    end
    return nothing
end

function validate_eligible_reference_values(reference, scope, model = "CASA-C")
    reference_cell_ids = try
        Int.(reference["cell_ids"])
    catch
        throw(RunnerError("Pinned $model reference has invalid cell IDs"))
    end
    !isempty(reference_cell_ids) &&
        length(reference_cell_ids) == length(unique(reference_cell_ids)) ||
        throw(RunnerError("Pinned $model reference has invalid cell IDs"))
    eligible_ids = eligible_cell_ids(scope, model)
    positions = Int[]
    for cell_id in eligible_ids
        position = findfirst(==(cell_id), reference_cell_ids)
        isnothing(position) &&
            throw(RunnerError("Pinned $model reference has no cell $cell_id"))
        push!(positions, position)
    end
    configuration_key = model == "CASA-C" ? "carbon_only" : "carbon_nitrogen"
    configuration = get(
        get(reference, "configuration", Dict{String, Any}()),
        configuration_key,
        Dict{String, Any}(),
    )
    native = get(configuration, "native_julia", Dict{String, Any}())
    fresh = get(configuration, "fresh_fortran", Dict{String, Any}())
    if model == "CASA-CN"
        historical = get(native, "historical", Dict{String, Any}())
        Set(keys(historical)) ==
        union(CASA_CN_DAILY_VARIABLES, Set(("sample_days",))) || throw(
            RunnerError(
                "Pinned $model reference has incompatible fixed daily variables",
            ),
        )
        fresh_historical = get(fresh, "historical", Dict{String, Any}())
        Set(keys(fresh_historical)) ==
        union(CASA_CN_FRESH_DAILY_VARIABLES, Set(("sample_days",))) &&
            length(get(fresh_historical, "sample_days", [])) == 56 || throw(
            RunnerError(
                "Pinned $model reference has incompatible fresh-Fortran daily variables",
            ),
        )
    end
    validate_finite_reference_values(
        native,
        "$configuration_key.native_julia",
        reference_cell_ids,
        positions,
        model,
    )
    validate_finite_reference_values(
        fresh,
        "$configuration_key.fresh_fortran",
        reference_cell_ids,
        positions,
        model,
    )
    return nothing
end

function scientific_outcome(report, result, model = "CASA-C")
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
    if model == "CASA-CN"
        nitrogen_budget = get(report, "nitrogen_budget", Dict{String, Any}())
        historical = get(report, "historical_comparison", Dict{String, Any}())
        checks["nitrogen_budget"] = get(nitrogen_budget, "all_close", false)
        checks["annual_reducers_and_daily_samples"] =
            get(historical, "all_match", false)
    end
    return (; passed = all(values(checks)), checks)
end

function stage_casa(
    scope,
    pinned_reference,
    policy,
    fixture_manifest,
    model = "CASA-C",
)
    collection = TestbedReferenceCellComparisons.selected_cell_collection(
        scope.name,
        eligible_cell_ids(scope, model);
        manifest_path = fixture_manifest,
    )
    TestbedSelectedCASAWorkflow.workflow_reference(
        model == "CASA-C" ? :carbon_only : :carbon_nitrogen,
        collection;
        path = pinned_reference,
        comparison_policy = policy.tolerance,
    )
    return collection
end

function summarize_budget(budget, units)
    summary = Dict{String, Any}(budget)
    reports = collect(values(get(budget, "stage", Dict{String, Any}())))
    haskey(budget, "workflow") && push!(reports, budget["workflow"])
    residual = "residual_$units"
    summary["maximum_absolute_residual_$units"] =
        maximum(abs(get(report, residual, Inf)) for report in reports)
    summary["reducer"] = "maximum_absolute_residual"
    return summary
end

function compare_fresh_fortran_daily(
    pinned_reference,
    historical_output,
    collection,
    tolerance,
    workers,
)
    reference = TOML.parsefile(pinned_reference)
    expected =
        reference["configuration"]["carbon_nitrogen"]["fresh_fortran"]["historical"]
    sample_days = Int.(expected["sample_days"])
    variables = Dict(
        name => values for (name, values) in expected if name != "sample_days"
    )
    actual = NCDatasets.NCDataset(historical_output) do output
        Dict(
            name => vec(
                Array(output[replace(name, "." => "__")][:, sample_days]),
            ) for name in keys(variables)
        )
    end
    cell_ids = Int.(reference["cell_ids"])
    report = TestbedSelectedCASAWorkflow.compare_snapshot(
        actual,
        variables,
        tolerance,
        collection,
        (; by_id = Dict(id => index for (index, id) in enumerate(cell_ids))),
        TestbedReferenceCellComparisons.ConcurrencyBudget(workers),
    )
    report["sample_days"] = sample_days
    report["source"] = "fresh_fortran"
    return report
end

function run_casa!(
    report,
    output_root,
    configuration,
    pinned_reference,
    collection,
    policy,
    model = "CASA-C",
)
    started = time_ns()
    result = TestbedSelectedCASAWorkflow.run_selected_case(
        joinpath(output_root, model);
        configuration = model == "CASA-C" ? :carbon_only : :carbon_nitrogen,
        collection,
        concurrency_budget = TestbedReferenceCellComparisons.ConcurrencyBudget(
            configuration.workers,
        ),
        reference_path = pinned_reference,
        comparison_policy = policy.tolerance,
        budget_rtol = policy.budget_rtol,
        diagnostics = model == "CASA-CN" ?
                      setup ->
            TestbedNativeCASACNReconstruction.casa_cn_diagnostics(
                setup.normal.model.casa_soil.parameters,
            ) : nothing,
    )
    seconds = (time_ns() - started) / 1e9
    scientific_report = TOML.parsefile(result.report)
    outcome = scientific_outcome(scientific_report, result, model)
    fresh_daily = Dict{String, Any}()
    if model == "CASA-CN"
        fresh_daily = compare_fresh_fortran_daily(
            pinned_reference,
            joinpath(
                output_root,
                model,
                "stages",
                "historical",
                "historical.nc",
            ),
            collection,
            policy.tolerance["fresh_fortran_historical"],
            configuration.workers,
        )
        checks = copy(outcome.checks)
        checks["fresh_fortran_daily"] = fresh_daily["all_match"]
        outcome =
            (; passed = outcome.passed && fresh_daily["all_match"], checks)
    end
    model_report = only(report["model"])
    model_report["coverage"]["compared_cells"] =
        model_report["coverage"]["eligible_cells"]
    model_report["outcome"] = outcome.passed ? "passed" : "failed"
    model_report["seconds"] = seconds
    model_report["comparison_report"] = abspath(result.report)
    model_report["comparison"] = outcome.checks
    model_report["budget"] = Dict(
        "carbon" => summarize_budget(
            get(scientific_report, "carbon_budget", Dict{String, Any}()),
            "kg_c",
        ),
    )
    if model == "CASA-CN"
        model_report["budget"]["nitrogen"] = summarize_budget(
            get(scientific_report, "nitrogen_budget", Dict{String, Any}()),
            "kg_n",
        )
        historical =
            get(scientific_report, "historical_comparison", Dict{String, Any}())
        model_report["historical"] = Dict(
            "annual" => get(historical, "annual", Dict{String, Any}()),
            "fixed_daily_samples" =>
                get(historical, "selected_dates", Dict{String, Any}()),
            "fresh_fortran_daily" => fresh_daily,
        )
    end
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
    model = only(configuration.models)
    policy = try
        comparison_policy(model)
    catch error
        error isa RunnerError || rethrow()
        println(stderr, "Validation Runner: ", error.message)
        return 2
    end
    report = initial_report(configuration, output_root, scope, policy)
    started = time_ns()
    try
        pinned_reference, reference_artifact =
            reference_path(configuration.scope, model)
        reference = validate_reference_file(pinned_reference, model)
        validate_eligible_reference_values(reference, scope, model)
        fixture_manifest, forcing_artifact =
            fixture_manifest_path(configuration.scope, model)
        validate_fixture_scope_provenance(fixture_manifest, scope)
        collection = try
            stage_casa(scope, pinned_reference, policy, fixture_manifest, model)
        catch error
            throw(
                RunnerError(
                    "Pinned $model inputs are incompatible: $(sprint(showerror, error))",
                ),
            )
            daily_hashes = get(
                get(configuration, "provenance", Dict{String, Any}()),
                "fresh_fortran_daily_sha256",
                Dict{String, Any}(),
            )
            Set(keys(daily_hashes)) == Set(("1901", "2014")) && all(
                hash isa String && length(hash) == 64 && all(isxdigit, hash) for hash in values(daily_hashes)
            ) || throw(
                RunnerError(
                    "Pinned $model reference has invalid fresh-Fortran daily provenance",
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
            model,
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
    policy = comparison_policy(only(configuration.models))
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
