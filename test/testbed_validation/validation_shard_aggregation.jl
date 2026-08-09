module TestbedValidationShardAggregation

import SHA
import TOML

const MODELS = ("CORPSE", "MIMICS-C", "MIMICS-CN", "CASA-C", "CASA-CN")
const REPORT_FILENAME = "validation_report.toml"
const COMPARISON_SCHEMA = "representative-pinned-comparison-v1"
const SHARD_STRATEGY = "scope-order-round-robin-v1"
const DEFAULT_SCOPE_PATH =
    joinpath(@__DIR__, "validation", "scopes", "representative.toml")
const SUM_KEYS = Set((
    "cell_count",
    "compared_values",
    "failed_values",
    "failure_count",
    "values",
))
const PATH_KEYS = Set((
    "comparison_report",
    "historical_output",
    "manifest",
    "output",
    "path",
))

struct AggregationError <: Exception
    message::String
end

Base.showerror(io::IO, error::AggregationError) = print(io, error.message)

fail(message) = throw(AggregationError(message))

function valid_integer(value)
    return value isa Integer && !(value isa Bool)
end

function canonical_scope(path)
    document = try
        TOML.parsefile(path)
    catch error
        fail("canonical scope is unreadable: $(sprint(showerror, error))")
    end
    get(document, "schema_version", nothing) == 1 ||
        fail("canonical scope schema is incompatible")
    get(document, "name", nothing) == "representative" ||
        fail("canonical scope is not Representative")
    ids = get(document, "cell_ids", nothing)
    ids isa AbstractVector && all(valid_integer, ids) ||
        fail("canonical scope cell IDs are invalid")
    length(ids) == length(unique(ids)) ||
        fail("canonical scope cell IDs are duplicated")
    gaps = get(document, "eligibility_gaps", Any[])
    gaps isa AbstractVector ||
        fail("canonical scope eligibility gaps are invalid")
    return (;
        document,
        cell_ids = Int.(ids),
        gaps,
        path = abspath(path),
        sha256 = bytes2hex(SHA.sha256(read(path))),
    )
end

function selected_models(value)
    requested =
        value == "all" ? collect(MODELS) : split(value, ','; keepempty = false)
    isempty(requested) && fail("--models must select at least one model")
    invalid = setdiff(requested, MODELS)
    isempty(invalid) || fail("unknown models: $(join(invalid, ", "))")
    return filter(model -> model in requested, collect(MODELS))
end

expected_cells(scope, index, count) = scope.cell_ids[index:count:end]

function expected_gaps(scope, model, cells)
    return [
        deepcopy(gap) for
        gap in scope.gaps if get(gap, "model", nothing) == model &&
        get(gap, "cell_id", nothing) in cells
    ]
end

function canonical_order(records, scope)
    positions = Dict(id => index for (index, id) in enumerate(scope.cell_ids))
    return sort!(
        records;
        by = record -> (
            get(
                positions,
                Int(get(record, "cell_id", typemax(Int))),
                typemax(Int),
            ),
            repr(record),
        ),
    )
end

function stable_identity(value)
    if value isa AbstractDict
        return Dict(
            String(key) => stable_identity(item) for
            (key, item) in value if String(key) ∉ PATH_KEYS
        )
    elseif value isa AbstractVector
        return stable_identity.(value)
    end
    return value
end

function require_same(values, description)
    first_value = first(values)
    all(==(first_value), values) ||
        fail("shard reports have inconsistent $description")
    return deepcopy(first_value)
end

function valid_sha256(value)
    return value isa AbstractString && occursin(r"^[0-9a-f]{64}$", value)
end

function required_table(parent, key, description)
    value = get(parent, key, nothing)
    value isa AbstractDict && !isempty(value) || fail("$description is missing")
    return value
end

function validate_passive_evidence(passive, model, index, cell_count)
    passive isa AbstractDict ||
        fail("$model shard $index lacks passive-restoration evidence")
    multiplier = get(passive, "multiplier", nothing)
    multiplier isa Real &&
        !(multiplier isa Bool) &&
        isfinite(multiplier) &&
        multiplier > 0 ||
        fail("$model shard $index has an invalid passive multiplier")
    all(
        get(passive, key, nothing) === true for key in
        ("verified", "unaffected_verified", "checkpoint_roundtrip_verified")
    ) || fail("$model shard $index has unverified passive restoration")
    elements = model == "CASA-CN" ? ("carbon", "nitrogen") : ("carbon",)
    for element in elements
        record = get(passive, element, nothing)
        record isa AbstractDict && get(record, "verified", nothing) === true ||
            fail("$model shard $index has invalid passive $element evidence")
        before = get(record, "before", nothing)
        after = get(record, "after", nothing)
        before isa AbstractVector &&
            after isa AbstractVector &&
            length(before) == cell_count &&
            length(after) == cell_count &&
            all(value -> value isa Real && isfinite(value), before) &&
            all(value -> value isa Real && isfinite(value), after) ||
            fail("$model shard $index has invalid passive $element vectors")
        after == multiplier .* before ||
            fail("$model shard $index has inconsistent passive $element values")
    end
    return passive
end

function validate_model_science(model_report, model, index)
    required_table(model_report, "comparison", "$model shard $index comparison")
    boundary = required_table(
        model_report,
        "boundary_comparison",
        "$model shard $index boundary evidence",
    )
    budget =
        required_table(model_report, "budget", "$model shard $index budget")
    if model == "CORPSE"
        Set(String.(keys(boundary))) ==
        Set(("prespin", "spin", "spin_continuation", "historical")) ||
            fail("CORPSE shard $index has incomplete boundary evidence")
        reduced = required_table(
            model_report,
            "reduced_historical",
            "CORPSE shard $index reduced history",
        )
        Set((
            "annual_summaries",
            "end_of_year",
            "annual_budgets",
            "fixed_daily_samples",
        )) ⊆ Set(String.(keys(reduced))) ||
            fail("CORPSE shard $index has incomplete reduced history")
        return nothing
    end
    required_table(budget, "carbon", "$model shard $index carbon budget")
    model in ("MIMICS-CN", "CASA-CN") && required_table(
        budget,
        "nitrogen",
        "$model shard $index nitrogen budget",
    )
    historical = required_table(
        model_report,
        "historical",
        "$model shard $index history",
    )
    if model in ("MIMICS-C", "MIMICS-CN")
        Set(("annual", "fixed_daily_samples", "budget_comparison")) ⊆
        Set(String.(keys(historical))) ||
            fail("$model shard $index has incomplete historical evidence")
        expected_boundary_stages =
            model == "MIMICS-C" ? Set(("prespin", "spin", "historical")) :
            Set(("prespin", "spin", "spin_continuation", "historical"))
        Set(String.(keys(boundary))) == expected_boundary_stages ||
            fail("$model shard $index has incomplete boundary evidence")
    else
        Set(("annual", "selected_dates")) ⊆ Set(String.(keys(historical))) ||
            fail("$model shard $index has incomplete historical evidence")
        model == "CASA-CN" &&
            !haskey(historical, "fresh_fortran_daily") &&
            fail("CASA-CN shard $index lacks fresh Fortran daily evidence")
        Set(String.(keys(boundary))) ==
        Set(("prespin", "accelerated_spin", "normal_spin", "historical")) ||
            fail("$model shard $index has incomplete boundary evidence")
        required_table(
            model_report,
            "initialization_comparison",
            "$model shard $index initialization evidence",
        )
        required_table(
            model_report,
            "passive_restoration",
            "$model shard $index passive summary",
        )
    end
    return nothing
end

function validate_shard_evidence(model_report, model, index, assigned)
    evidence = get(model_report, "shard_evidence", nothing)
    evidence isa AbstractDict ||
        fail("$model shard $index lacks detailed shard evidence")
    valid_sha256(get(evidence, "comparison_report_sha256", nothing)) ||
        fail("$model shard $index has an invalid comparison report digest")
    if model == "CORPSE"
        stages = get(evidence, "stage", nothing)
        stages isa AbstractDict &&
            Set(String.(keys(stages))) ==
            Set(("prespin", "spin", "spin_continuation", "historical")) ||
            fail("CORPSE shard $index has incomplete stage evidence")
        expected = Set((
            "checkpoint_sha256",
            "restart_transform_verified",
            "checkpoint_handoff_verified",
            "conservation_verified",
        ))
        for (name, stage) in stages
            stage isa AbstractDict && Set(String.(keys(stage))) == expected ||
                fail("CORPSE shard $index has invalid $name stage evidence")
            valid_sha256(stage["checkpoint_sha256"]) || fail(
                "CORPSE shard $index has an invalid $name checkpoint digest",
            )
            all(
                stage[key] === true for key in (
                    "restart_transform_verified",
                    "checkpoint_handoff_verified",
                    "conservation_verified",
                )
            ) || fail("CORPSE shard $index failed $name state verification")
        end
    elseif model in ("CASA-C", "CASA-CN")
        validate_passive_evidence(
            get(evidence, "passive_restoration", nothing),
            model,
            index,
            length(assigned),
        )
    end
    validate_model_science(model_report, model, index)
    return evidence
end

function validate_report(report, scope, expected_models, shard_count)
    report isa AbstractDict || fail("shard report is not a TOML table")
    valid_integer(get(report, "schema_version", nothing)) &&
        report["schema_version"] == 1 ||
        fail("shard report schema is incompatible")
    get(report, "comparison_schema", nothing) == COMPARISON_SCHEMA ||
        fail("shard report comparison schema is incompatible")
    get(report, "reference_mode", nothing) == "pinned" ||
        fail("shard report reference mode is incompatible")

    report_scope = get(report, "scope", nothing)
    report_scope isa AbstractDict || fail("shard report lacks canonical scope")
    get(report_scope, "name", nothing) == "representative" ||
        fail("shard report has the wrong scope")
    get(report_scope, "manifest_sha256", nothing) == scope.sha256 ||
        fail("shard report has inconsistent scope provenance")
    get(report_scope, "cell_ids", nothing) == scope.cell_ids ||
        fail("shard report has inconsistent canonical cell IDs")
    get(report_scope, "cell_count", nothing) == length(scope.cell_ids) ||
        fail("shard report has inconsistent canonical cell count")

    shard = get(report, "shard", nothing)
    shard isa AbstractDict || fail("validation report lacks shard metadata")
    get(shard, "schema_version", nothing) == 1 ||
        fail("shard metadata schema is incompatible")
    get(shard, "strategy", nothing) == SHARD_STRATEGY ||
        fail("shard strategy is incompatible")
    get(shard, "count", nothing) == shard_count ||
        fail("shard count does not match --shard-count")
    index = get(shard, "index", nothing)
    valid_integer(index) && 1 <= index <= shard_count ||
        fail("shard index is outside 1:$shard_count")
    assigned = expected_cells(scope, index, shard_count)
    get(shard, "cell_ids", nothing) == assigned ||
        fail("shard $index does not match its deterministic assignment")

    raw_models = get(report, "model", nothing)
    raw_models isa AbstractVector && length(raw_models) == 1 ||
        fail("each shard report must contain exactly one model")
    model_report = only(raw_models)
    model_report isa AbstractDict || fail("shard model report is invalid")
    model = get(model_report, "name", nothing)
    model in expected_models ||
        fail("shard report contains unexpected model $(repr(model))")
    get(model_report, "reference_mode", nothing) == "pinned" ||
        fail("$model shard has inconsistent reference mode")
    validate_shard_evidence(model_report, String(model), index, assigned)

    coverage = get(model_report, "coverage", nothing)
    coverage isa AbstractDict || fail("$model shard $index lacks coverage")
    gaps = expected_gaps(scope, model, assigned)
    eligible = length(assigned) - length(gaps)
    get(coverage, "scope_cells", nothing) == length(assigned) ||
        fail("$model shard $index has invalid scope coverage")
    get(coverage, "eligible_cells", nothing) == eligible ||
        fail("$model shard $index has invalid eligible coverage")
    get(coverage, "eligibility_gaps", Any[]) == gaps ||
        fail("$model shard $index has invalid eligibility gaps")
    compared = get(coverage, "compared_cells", nothing)
    valid_integer(compared) ||
        fail("$model shard $index has invalid compared coverage")
    report_outcome = get(report, "outcome", nothing)
    model_outcome = get(model_report, "outcome", nothing)
    report_outcome == model_outcome ||
        fail("$model shard $index has inconsistent outcomes")
    compared == eligible || fail("$model shard $index has incomplete coverage")
    report_outcome in ("passed", "failed") ||
        fail("$model shard $index has an invalid outcome")
    return (; report, model_report, model = String(model), index, assigned)
end

function is_extensive_budget_key(key)
    startswith(key, "start_stock_") ||
        startswith(key, "stop_stock_") ||
        startswith(key, "external_input_") ||
        startswith(key, "external_output_") ||
        occursin("_adjustment_", key) ||
        startswith(key, "residual_")
end

function merge_vectors(values, key, scope, path)
    if key == "cell_ids"
        observed = Set{Int}()
        for vector in values, id in vector
            valid_integer(id) || fail("invalid cell ID at $path")
            id in observed && fail("overlapping cell IDs at $path")
            push!(observed, Int(id))
        end
        return [id for id in scope.cell_ids if id in observed]
    elseif key in ("cell_failures", "eligibility_gaps")
        records = Any[]
        for vector in values
            append!(records, deepcopy(vector))
        end
        ids = [Int(get(record, "cell_id", -1)) for record in records]
        length(ids) == length(unique(ids)) ||
            fail("duplicate cell failure or eligibility gap at $path")
        return canonical_order(records, scope)
    elseif key in ("pfts", "forcing_regimes")
        return sort!(unique(vcat(values...)))
    end
    return require_same(values, "scientific report field $path")
end

function merge_value(values, key, scope, path)
    all(value -> value isa AbstractDict, values) &&
        return merge_dicts(values, scope, path)
    all(value -> value isa AbstractVector, values) &&
        return merge_vectors(values, key, scope, path)
    all(value -> value isa Bool, values) && return all(values)
    if all(value -> value isa Number && !(value isa Bool), values)
        key in SUM_KEYS && return sum(values)
        key == "relative_residual" && return maximum(values)
        (occursin("maximum_", key) || key == "seconds") &&
            return maximum(values)
        is_extensive_budget_key(key) && return sum(values)
    end
    return require_same(values, "scientific report field $path")
end

function merge_dicts(dicts, scope, path = "")
    key_sets = Set.(keys.(dicts))
    all(==(first(key_sets)), key_sets) ||
        fail("incompatible scientific report structure at $path")
    result = Dict{String, Any}()
    for key in sort!(String.(collect(first(key_sets))))
        child_path = isempty(path) ? key : string(path, '.', key)
        result[key] = merge_value(
            [dictionary[key] for dictionary in dicts],
            key,
            scope,
            child_path,
        )
    end
    recompute_budget_record!(result)
    return result
end

function budget_units(record)
    for key in keys(record)
        startswith(key, "start_stock_") && return key[13:end]
    end
    return nothing
end

function recompute_budget_extrema!(record)
    for key in collect(keys(record))
        startswith(key, "maximum_absolute_residual_") || continue
        residual_key = replace(key, "maximum_absolute_" => "")
        residuals = Float64[]
        if haskey(record, "stage")
            for child in values(record["stage"])
                haskey(child, residual_key) &&
                    push!(residuals, abs(Float64(child[residual_key])))
            end
        end
        haskey(record, "workflow") &&
            haskey(record["workflow"], residual_key) &&
            push!(residuals, abs(Float64(record["workflow"][residual_key])))
        isempty(residuals) || (record[key] = maximum(residuals))
    end
    return record
end

function recompute_budget_summary!(record)
    haskey(record, "all_close") || return record
    children = Any[]
    haskey(record, "stage") && append!(children, values(record["stage"]))
    haskey(record, "workflow") && push!(children, record["workflow"])
    isempty(children) || (
        record["all_close"] =
            all(get(child, "close", false) for child in children)
    )
    return record
end

function recompute_budget_record!(record)
    units = budget_units(record)
    if isnothing(units)
        recompute_budget_extrema!(record)
        recompute_budget_summary!(record)
        return record
    end
    start = record["start_stock_$units"]
    stop = record["stop_stock_$units"]
    input = record["external_input_$units"]
    output = record["external_output_$units"]
    adjustment_keys = filter(
        key ->
            occursin("_adjustment_", key) &&
                !startswith(key, "bounded_state_adjustment_") &&
                !startswith(key, "restart_") &&
                !startswith(key, "passive_"),
        collect(keys(record)),
    )
    adjustment =
        isempty(adjustment_keys) ?
        get(record, "bounded_state_adjustment_$units", 0.0) :
        record[only(adjustment_keys)]
    residual = stop - start - (input - output + adjustment)
    scale =
        max(abs(stop - start), abs(input), abs(output), abs(adjustment), 1.0)
    record["residual_$units"] = residual
    record["relative_residual"] = abs(residual) / scale
    rtol = record["rtol"]
    recompute_budget_extrema!(record)
    record["close"] = abs(residual) <= rtol * scale
    return record
end

function recompute_budget_comparisons!(result)
    comparison = get(result, "comparison", nothing)
    budget = get(result, "budget", nothing)
    comparison isa AbstractDict && budget isa AbstractDict || return result
    for (check, element) in
        ("carbon_budget" => "carbon", "nitrogen_budget" => "nitrogen")
        haskey(budget, element) || continue
        comparison[check] = get(budget[element], "all_close", false) === true
    end
    return result
end

function merge_model(shards, scope)
    model = first(shards).model
    model_reports = getproperty.(shards, :model_report)
    reference = require_same(
        stable_identity.(getindex.(model_reports, "reference")),
        "$model reference provenance",
    )
    forcing = require_same(
        stable_identity.(getindex.(model_reports, "forcing")),
        "$model forcing provenance",
    )
    policy = require_same(
        stable_identity.(getindex.(model_reports, "comparison_policy")),
        "$model comparison policy",
    )

    ignored = Set((
        "name",
        "outcome",
        "reference_mode",
        "seconds",
        "coverage",
        "reference",
        "forcing",
        "comparison_policy",
        "comparison_report",
        "shard_evidence",
    ))
    key_sets = [
        setdiff(Set(String.(keys(report))), ignored) for report in model_reports
    ]
    all(==(first(key_sets)), key_sets) ||
        fail("$model shard reports have incompatible standard fields")
    shards_passed = all(
        get(shard.report, "outcome", nothing) == "passed" &&
        get(shard.model_report, "outcome", nothing) == "passed" for
        shard in shards
    )
    result = Dict{String, Any}(
        "name" => model,
        "outcome" => shards_passed ? "passed" : "failed",
        "reference_mode" => "pinned",
        "seconds" => maximum(
            Float64(get(report, "seconds", 0.0)) for report in model_reports
        ),
        "reference" => reference,
        "forcing" => forcing,
        "comparison_policy" => policy,
    )
    gaps = Any[]
    for report in model_reports
        append!(
            gaps,
            deepcopy(get(report["coverage"], "eligibility_gaps", Any[])),
        )
    end
    gaps = canonical_order(gaps, scope)
    result["coverage"] = Dict(
        "scope_cells" => length(scope.cell_ids),
        "eligible_cells" => sum(
            Int(report["coverage"]["eligible_cells"]) for
            report in model_reports
        ),
        "compared_cells" => sum(
            Int(report["coverage"]["compared_cells"]) for
            report in model_reports
        ),
        "eligibility_gaps" => gaps,
    )
    result["shard_evidence"] = [
        Dict(
            "shard_index" => shard.index,
            "cell_ids" => shard.assigned,
            "evidence" => deepcopy(
                get(shard.model_report, "shard_evidence", Dict{String, Any}()),
            ),
        ) for shard in shards
    ]
    merge_keys = sort!(
        collect(setdiff(Set(String.(keys(first(model_reports)))), ignored)),
    )
    for key in merge_keys
        all(report -> haskey(report, key), model_reports) ||
            fail("$model shard reports have incompatible scientific fields")
        result[key] = merge_value(
            [report[key] for report in model_reports],
            key,
            scope,
            string(model, '.', key),
        )
    end
    recompute_budget_comparisons!(result)
    comparisons = get(result, "comparison", Dict{String, Any}())
    comparisons_passed =
        !isempty(comparisons) &&
        all(value === true for value in values(comparisons))
    result["outcome"] =
        shards_passed && comparisons_passed ? "passed" : "failed"
    return result
end

function aggregate_shard_reports(
    reports,
    scope_path = DEFAULT_SCOPE_PATH;
    expected_models = collect(MODELS),
    shard_count = 8,
)
    valid_integer(shard_count) && shard_count > 0 ||
        fail("shard count must be a positive integer")
    models = selected_models(join(expected_models, ','))
    scope = canonical_scope(scope_path)
    grouped = Dict(model => Dict{Int, Any}() for model in models)
    for report in reports
        shard = validate_report(report, scope, models, shard_count)
        haskey(grouped[shard.model], shard.index) &&
            fail("duplicate shard $(shard.index) for $(shard.model)")
        grouped[shard.model][shard.index] = shard
    end
    for model in models
        missing = setdiff(collect(1:shard_count), collect(keys(grouped[model])))
        isempty(missing) ||
            fail("missing shard(s) $(join(missing, ", ")) for $model")
    end
    ordered = Dict(
        model => [grouped[model][index] for index in 1:shard_count] for
        model in models
    )
    for model in models
        require_same(
            stable_identity.(
                getindex.(
                    getproperty.(ordered[model], :model_report),
                    "reference",
                ),
            ),
            "$model reference provenance",
        )
        require_same(
            stable_identity.(
                getindex.(
                    getproperty.(ordered[model], :model_report),
                    "comparison_policy",
                ),
            ),
            "$model comparison policy",
        )
    end
    model_reports = [merge_model(ordered[model], scope) for model in models]
    if length(model_reports) > 1
        forcing_artifacts = [
            get(
                get(report, "forcing", Dict{String, Any}()),
                "artifact",
                nothing,
            ) for report in model_reports
        ]
        all(
            artifact ->
                artifact isa AbstractString &&
                    occursin(r"^[0-9a-f]{40}$", artifact),
            forcing_artifacts,
        ) || fail("model reports lack a shared forcing artifact identity")
        all(==(first(forcing_artifacts)), forcing_artifacts) ||
            fail("model reports have inconsistent forcing provenance")
    end
    seconds =
        maximum(Float64(get(report, "seconds", 0.0)) for report in reports)
    total_seconds =
        sum(Float64(get(report, "seconds", 0.0)) for report in reports)
    return Dict(
        "schema_version" => 1,
        "comparison_schema" => COMPARISON_SCHEMA,
        "reference_mode" => "pinned",
        "outcome" =>
            all(report["outcome"] == "passed" for report in model_reports) ?
            "passed" : "failed",
        "seconds" => seconds,
        "workers" => length(reports),
        "scope" => Dict(
            "name" => "representative",
            "cell_count" => length(scope.cell_ids),
            "cell_ids" => scope.cell_ids,
            "manifest" => scope.path,
            "manifest_sha256" => scope.sha256,
        ),
        "sharding" => Dict(
            "schema_version" => 1,
            "strategy" => SHARD_STRATEGY,
            "shard_count" => shard_count,
            "job_count" => length(reports),
            "maximum_job_seconds" => seconds,
            "total_job_seconds" => total_seconds,
        ),
        "model" => model_reports,
    )
end

function discover_reports(input, output)
    isdir(input) || fail("input directory does not exist: $input")
    output_report = abspath(joinpath(output, REPORT_FILENAME))
    paths = String[]
    for (root, _, files) in walkdir(input)
        REPORT_FILENAME in files || continue
        path = abspath(joinpath(root, REPORT_FILENAME))
        path == output_report || push!(paths, path)
    end
    sort!(paths)
    isempty(paths) && fail("no shard validation reports found under $input")
    return paths
end

function load_reports(paths)
    reports = Any[]
    for path in paths
        report = try
            TOML.parsefile(path)
        catch error
            fail("unreadable shard report $path: $(sprint(showerror, error))")
        end
        push!(reports, report)
    end
    return reports
end

function write_report(output, report)
    mkpath(output)
    path = joinpath(output, REPORT_FILENAME)
    temporary = string(path, ".tmp")
    open(temporary, "w") do io
        TOML.print(io, report; sorted = true)
    end
    mv(temporary, path; force = true)
    return path
end
function write_model_evidence!(output, aggregate)
    for model_report in aggregate["model"]
        model = model_report["name"]
        directory = joinpath(output, "models", model)
        mkpath(directory)
        path = joinpath(directory, "comparison_report.toml")
        temporary = string(path, ".tmp")
        omitted =
            Set(("comparison_report", "comparison_report_sha256", "seconds"))
        evidence = Dict{String, Any}(
            "schema_version" => 1,
            "comparison_schema" => COMPARISON_SCHEMA,
            "model" => model,
            "scope" => aggregate["scope"],
            "outcome" => model_report["outcome"],
        )
        for key in
            sort!(collect(setdiff(Set(String.(keys(model_report))), omitted)))
            key in ("name", "outcome") && continue
            evidence[key] = deepcopy(model_report[key])
        end
        open(temporary, "w") do io
            TOML.print(io, evidence; sorted = true)
        end
        mv(temporary, path; force = true)
        model_report["comparison_report"] = abspath(path)
        model_report["comparison_report_sha256"] =
            bytes2hex(SHA.sha256(read(path)))
    end
    return aggregate
end

function parse_args(args)
    values = Dict{String, String}()
    index = 1
    while index <= length(args)
        option = args[index]
        option in ("--input", "--output", "--shard-count", "--models") ||
            fail("unknown argument: $option")
        index < length(args) || fail("$option requires a value")
        haskey(values, option) && fail("$option was provided more than once")
        values[option] = args[index + 1]
        index += 2
    end
    for option in ("--input", "--output", "--shard-count", "--models")
        haskey(values, option) || fail("missing required argument $option")
    end
    count = tryparse(Int, values["--shard-count"])
    isnothing(count) && fail("--shard-count must be a positive integer")
    count > 0 || fail("--shard-count must be a positive integer")
    return (;
        input = abspath(values["--input"]),
        output = abspath(values["--output"]),
        shard_count = count,
        models = selected_models(values["--models"]),
    )
end

function failure_report(message)
    return Dict(
        "schema_version" => 1,
        "comparison_schema" => COMPARISON_SCHEMA,
        "reference_mode" => "pinned",
        "outcome" => "failed",
        "seconds" => 0.0,
        "error" => message,
    )
end

function output_from_args(args)
    index = findfirst(==("--output"), args)
    isnothing(index) || index == length(args) ? nothing :
    abspath(args[index + 1])
end

function main(args = ARGS)
    fallback_output = output_from_args(args)
    try
        configuration = parse_args(args)
        reports = load_reports(
            discover_reports(configuration.input, configuration.output),
        )
        aggregate = aggregate_shard_reports(
            reports,
            DEFAULT_SCOPE_PATH;
            expected_models = configuration.models,
            shard_count = configuration.shard_count,
        )
        write_model_evidence!(configuration.output, aggregate)
        aggregate["output"] = configuration.output
        path = write_report(configuration.output, aggregate)
        println(
            "Validation shard aggregation: $(aggregate["outcome"]) | report=$path",
        )
        return aggregate["outcome"] == "passed" ? 0 : 1
    catch error
        message =
            error isa AggregationError ? error.message :
            "unexpected aggregation failure: $(sprint(showerror, error))"
        if !isnothing(fallback_output)
            path = write_report(fallback_output, failure_report(message))
            println(
                stderr,
                "Validation shard aggregation: failed | report=$path",
            )
        end
        println(stderr, "Validation shard aggregation: $message")
        return 1
    end
end

end
