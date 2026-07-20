if !isdefined(@__MODULE__, :TestbedCASACNReconstruction)
    include(joinpath(@__DIR__, "casa_cn_reconstruction.jl"))
end
if !isdefined(@__MODULE__, :TestbedMIMICSCReconstruction)
    include(joinpath(@__DIR__, "mimics_c_reconstruction.jl"))
end

module TestbedMIMICSCNReconstruction

import TOML
import Test

import NCDatasets

const MATRIX_PATH = joinpath(@__DIR__, "mimics_cn_reconstruction.toml")
const CANDIDATE_SPEC_PATH = joinpath(@__DIR__, "candidate_reconstruction.toml")
const STAGE_SPECS = (
    (name = "prespin", directory = "01-prespin"),
    (name = "spin", directory = "02-spin"),
    (name = "spin_continuation", directory = "03-spin_continuation"),
    (name = "historical", directory = "04-historical"),
)
const CANDIDATE_IDS =
    ("casa_boreal_nfix", "mimics_ko6_fi30", "mimics_cn_prespin_fi30")
const MODEL_IDS = ("casa", "mimics")

casa_cn() = getfield(parentmodule(@__MODULE__), :TestbedCASACNReconstruction)
mimics_c() = getfield(parentmodule(@__MODULE__), :TestbedMIMICSCReconstruction)
casa() = casa_cn().casa()
harness() = casa().harness()
candidates() = casa().candidates()
comparator() = casa().comparator()
sha256sum(path) = casa().sha256sum(path)
file_record(path) = casa().file_record(path)
netcdf_name(model, year; daily = false) =
    mimics_c().netcdf_name(model, year; daily)

function load_matrix(path = MATRIX_PATH)
    matrix = TOML.parsefile(path)
    get(matrix, "schema_version", 0) == 1 ||
        error("Unsupported MIMICS-CN reconstruction matrix schema")
    matrix["issue"] == 25 || error("MIMICS-CN matrix must identify issue 25")
    matrix["points"] == 4263 ||
        error("MIMICS-CN matrix must retain 4,263 points")
    matrix["comparison_atol"] == 0.0 ||
        error("MIMICS-CN comparison must be exact")
    matrix["comparison_rtol"] == 0.0 ||
        error("MIMICS-CN comparison must be exact")
    matrix["stages"]["prespin"]["loops"] == matrix["prespin_loops"] ||
        error("MIMICS-CN prespin matrix is inconsistent")
    for stage in ("spin", "spin_continuation")
        matrix["stages"][stage]["loops"] == matrix["spin_loops"] ||
            error("MIMICS-CN $stage loop count is inconsistent")
        matrix["stages"][stage]["years"] == matrix["spin_years"] ||
            error("MIMICS-CN $stage years are inconsistent")
    end
    matrix["stages"]["historical"]["years"] == matrix["history_years"] ||
        error("MIMICS-CN history matrix is inconsistent")
    Set(model["id"] for model in matrix["postprocessing"]["model"]) ==
    Set(MODEL_IDS) || error("MIMICS-CN matrix must compare CASA and MIMICS")
    comparison = matrix["scientific_comparison"]
    for model in MODEL_IDS
        haskey(comparison, model) ||
            error("MIMICS-CN comparison groups are missing $model")
        all(!isempty(group) for group in values(comparison[model])) ||
            error("MIMICS-CN $model comparison groups cannot be empty")
    end
    blocked = matrix["compiler"]["blocked_candidate"]
    length(blocked) == 1 ||
        error("MIMICS-CN matrix must record the unavailable compiler")
    only(blocked)["status"] == "blocked_unavailable_toolchain" ||
        error("MIMICS-CN source compiler must be explicitly blocked")
    return matrix
end

function case_spec(matrix, id)
    matching = filter(case -> case["id"] == id, matrix["case"])
    length(matching) == 1 || error("Unknown or duplicate MIMICS-CN case: $id")
    return only(matching)
end

function candidate_paths(spec_path = CANDIDATE_SPEC_PATH)
    selected = Dict{String, String}()
    for candidate in TOML.parsefile(spec_path)["candidate"]
        candidate["id"] in CANDIDATE_IDS || continue
        selected[candidate["id"]] = candidate["destination"]
    end
    Set(keys(selected)) == Set(CANDIDATE_IDS) ||
        error("Candidate specification is missing a MIMICS-CN input")
    return selected
end

function retained_daily_years(matrix = load_matrix())
    return casa_cn().retained_daily_years(matrix)
end

annual_fragment(model, year) =
    joinpath("annual_comparison", model, "$year.toml")
daily_fragment(model, year) = joinpath("daily_comparison", model, "$year.toml")

function historical_stage_outputs(matrix = load_matrix())
    years = first(matrix["history_years"]):last(matrix["history_years"])
    retained = retained_daily_years(matrix)
    outputs = ["casa_final.csv", "casa_flux_final.csv", "mimics_final.csv"]
    for model in MODEL_IDS
        append!(outputs, annual_fragment.(model, years))
        append!(outputs, daily_fragment.(model, sort!(collect(retained))))
    end
    return outputs
end

function stage_definition(name, control_path, inputs)
    name == "historical" ||
        return mimics_c().stage_definition(name, control_path, inputs)
    matrix = load_matrix()
    return Dict(
        "name" => name,
        "control" => relpath(control_path, dirname(dirname(control_path))),
        "outputs" => historical_stage_outputs(matrix),
        "input" => inputs,
        "retention" => Dict(
            "annual_fragments" => true,
            "daily_comparison_fragments" => true,
            "raw_daily_outputs" => false,
            "daily_years" => sort!(collect(retained_daily_years(matrix))),
        ),
    )
end

function write_staged_control(source, destination, overrides)
    lines = readlines(source; keep = true)
    diffs = Dict{String, Any}[]
    for (field, after) in overrides
        line = findfirst(==(field), harness().CONTROL_FIELDS)
        isnothing(line) && error("Unknown control field: $field")
        before = harness().control_value(lines[line])
        after_string = string(after)
        before == after_string && continue
        push!(
            diffs,
            Dict(
                "line" => line,
                "field" => string(field),
                "before" => before,
                "after" => after_string,
            ),
        )
        lines[line] = casa().replace_control_value(lines[line], after_string)
    end
    mkpath(dirname(destination))
    write(destination, join(lines))
    control = harness().parse_control(destination)
    control[:points] == 4263 ||
        error("Staged MIMICS-CN control does not use 4,263 points")
    control[:soil_model] == 2 || error("Staged control is not MIMICS")
    control[:cycle] == 2 || error("Staged control is not carbon-nitrogen")
    return Dict(
        "source" => file_record(source),
        "staged" => file_record(destination),
        "diff" => diffs,
    )
end

function common_inputs(
    source_root,
    data_root,
    years,
    casa_parameters,
    mimics_parameters,
)
    matrix = load_matrix()
    inputs = matrix["inputs"]
    workflow_input = harness().workflow_input
    records = [
        workflow_input(joinpath(source_root, inputs["grid"]), "grid.csv"),
        workflow_input(casa_parameters, "casa_parameters.csv"),
        workflow_input(
            joinpath(source_root, inputs["phenology"]),
            "phenology.txt",
        ),
        workflow_input(joinpath(source_root, inputs["soil"]), "soil.csv"),
        workflow_input(mimics_parameters, "mimics_parameters.csv"),
        workflow_input(
            joinpath(source_root, inputs["perturbation"]),
            "perturbation.txt",
        ),
    ]
    driver_root = joinpath(data_root, inputs["driver_directory"])
    for year in years
        filename = "met_$(year)_$(year).nc"
        push!(
            records,
            workflow_input(
                joinpath(driver_root, filename),
                filename;
                mode = "symlink",
            ),
        )
    end
    return records
end

function stage_control_source(matrix, source_root, candidate_root, paths, stage)
    stage == "prespin" && return joinpath(
        candidate_root,
        paths[matrix["stages"][stage]["control_candidate"]],
    )
    return joinpath(source_root, matrix["stages"][stage]["control"])
end

function write_full_workflow(
    source_root,
    data_root,
    candidate_root,
    run_root,
    case_id,
)
    source_root = abspath(source_root)
    data_root = abspath(data_root)
    candidate_root = abspath(candidate_root)
    run_root = abspath(run_root)
    matrix = load_matrix()
    case = case_spec(matrix, case_id)
    paths = candidate_paths()
    configuration = joinpath(run_root, "configuration")
    controls_root = joinpath(configuration, "controls")
    mkpath(controls_root)
    inputs = matrix["inputs"]
    normal_casa = joinpath(source_root, inputs["normal_casa_parameters"])
    normal_mimics = joinpath(source_root, inputs["normal_mimics_parameters"])
    sha256sum(normal_casa) == inputs["normal_casa_parameters_sha256"] ||
        error("MIMICS-CN CASA parameter hash differs from the matrix")
    sha256sum(normal_mimics) == inputs["normal_mimics_parameters_sha256"] ||
        error("MIMICS-CN KO4 parameter hash differs from the matrix")
    prespin_casa =
        joinpath(candidate_root, paths[case["prespin_casa_candidate"]])
    prespin_mimics =
        joinpath(candidate_root, paths[case["prespin_mimics_candidate"]])
    parameter_by_stage = Dict(
        "prespin" => (casa = prespin_casa, mimics = prespin_mimics),
        "spin" => (casa = normal_casa, mimics = normal_mimics),
        "spin_continuation" => (casa = normal_casa, mimics = normal_mimics),
        "historical" => (casa = normal_casa, mimics = normal_mimics),
    )
    common_overrides = Dict(
        :points => 4263,
        :soil_model => 2,
        :cycle => 2,
        :grid_info => "grid.csv",
        :casa_parameters => "casa_parameters.csv",
        :phenology => "phenology.txt",
        :soil_properties => "soil.csv",
        :meteorology => "met_1901_1901.nc",
        :casa_initial => "casa_initial.csv",
        :casa_final => "casa_final.csv",
        :casa_flux_final => "casa_flux_final.csv",
        :casa_netcdf => "casaclm_pool_flux_yyyy.nc",
        :mimics_parameters => "mimics_parameters.csv",
        :mimics_initial => "mimics_initial.csv",
        :mimics_final => "mimics_final.csv",
        :mimics_netcdf => "mimics_pool_flux_yyyy.nc",
        :perturbation => "perturbation.txt",
        :point_output_directory => "./",
    )
    controls = Dict{String, String}()
    control_reports = Dict{String, Any}[]
    for stage_spec in STAGE_SPECS
        stage = stage_spec.name
        source = stage_control_source(
            matrix,
            source_root,
            candidate_root,
            paths,
            stage,
        )
        destination = joinpath(controls_root, "$stage.lst")
        overrides = copy(common_overrides)
        stage in ("spin", "spin_continuation") && (
            overrides[:netcdf_interval] =
                matrix["postprocessing"]["spin_checkpoint_interval"]
        )
        report = write_staged_control(source, destination, overrides)
        report["stage"] = stage
        push!(control_reports, report)
        control = harness().parse_control(destination)
        control[:loops] == matrix["stages"][stage]["loops"] ||
            error("MIMICS-CN $stage loop count differs from the matrix")
        [first(control[:years]), last(control[:years])] ==
        matrix["stages"][stage]["years"] ||
            error("MIMICS-CN $stage years differ from the matrix")
        controls[stage] = destination
    end
    stage_inputs = Dict{String, Any}()
    for stage_spec in STAGE_SPECS
        stage = stage_spec.name
        years = matrix["stages"][stage]["years"]
        parameters = parameter_by_stage[stage]
        stage_inputs[stage] = common_inputs(
            source_root,
            data_root,
            first(years):last(years),
            parameters.casa,
            parameters.mimics,
        )
    end
    for index in 2:length(STAGE_SPECS)
        stage = STAGE_SPECS[index].name
        predecessor = STAGE_SPECS[index - 1].name
        push!(
            stage_inputs[stage],
            harness().workflow_input(
                "stage:$predecessor/casa_final.csv",
                "casa_initial.csv",
            ),
        )
        push!(
            stage_inputs[stage],
            harness().workflow_input(
                "stage:$predecessor/mimics_final.csv",
                "mimics_initial.csv",
            ),
        )
    end
    push!(
        stage_inputs["historical"],
        harness().workflow_input(MATRIX_PATH, "mimics_cn_reconstruction.toml"),
    )
    stages = [
        stage_definition(
            stage.name,
            controls[stage.name],
            stage_inputs[stage.name],
        ) for stage in STAGE_SPECS
    ]
    workflow = Dict(
        "schema_version" => 1,
        "name" => "mimics-cn-archive-reconstruction-$case_id",
        "source_commit" => case["source_commit"],
        "stage" => stages,
    )
    workflow_path = joinpath(configuration, "workflow.toml")
    harness().write_toml_atomic(workflow_path, workflow)
    derivation_report = joinpath(candidate_root, "derivation_report.toml")
    harness().write_toml_atomic(
        joinpath(configuration, "control_diff_report.toml"),
        Dict(
            "schema_version" => 1,
            "case" => case_id,
            "evidence_matrix" => file_record(MATRIX_PATH),
            "candidate_derivation_report" => file_record(derivation_report),
            "candidate_input" => Dict(
                id => file_record(joinpath(candidate_root, paths[id])) for
                id in CANDIDATE_IDS
            ),
            "stage_parameter" => Dict(
                stage => Dict(
                    "casa" => file_record(parameters.casa),
                    "mimics" => file_record(parameters.mimics),
                ) for (stage, parameters) in parameter_by_stage
            ),
            "staged_control" => control_reports,
        ),
    )
    return workflow_path
end

function archive_record(data_root)
    artifacts = filter(
        artifact -> artifact["id"] == "mimics_cn_output",
        harness().load_manifest()["artifact"],
    )
    length(artifacts) == 1 || error("MIMICS-CN archive manifest is ambiguous")
    artifact = only(artifacts)
    return casa().verified_artifact_record(
        joinpath(data_root, artifact["filename"]),
        artifact,
    )
end

function shared_reference_root(case_root)
    return joinpath(dirname(case_root), "reference")
end

function extract_archive_reference(
    data_root,
    case_root,
    filename;
    archive = archive_record(data_root),
)
    reference_root = shared_reference_root(case_root)
    destination = joinpath(reference_root, filename)
    member = joinpath(
        "MIMICS_mod5_GSWP3_KO4_exudate0_cwdN",
        "OUTPUT_CN",
        "HIST",
        filename,
    )
    metadata_path = destination * ".provenance.toml"
    casa().reference_cache_valid(destination, metadata_path, archive, member) &&
        return destination
    mkpath(reference_root)
    temporary = destination * ".tmp"
    isfile(temporary) && rm(temporary; force = true)
    try
        open(temporary, "w") do io
            run(
                pipeline(
                    Cmd(["tar", "-xOf", archive["path"], member]);
                    stdout = io,
                ),
            )
        end
        mv(temporary, destination; force = true)
        harness().write_toml_atomic(
            metadata_path,
            Dict(
                "archive_md5" => archive["md5"],
                "archive_member" => member,
                "bytes" => filesize(destination),
                "md5" => harness().md5sum(destination),
            ),
        )
    finally
        isfile(temporary) && rm(temporary; force = true)
    end
    return destination
end

function model_spec(id, matrix = load_matrix())
    return only(
        filter(model -> model["id"] == id, matrix["postprocessing"]["model"]),
    )
end

daily_reference_name(
    model,
    window,
) = "$(model["prefix"])_pool_flux_$(first(window))_$(last(window))_daily.nc"

function reference_paths(
    data_root,
    case_root;
    archive = archive_record(data_root),
)
    matrix = load_matrix()
    paths = Dict{String, Any}()
    for model in matrix["postprocessing"]["model"]
        paths[model["id"]] = Dict{String, Any}(
            "annual" => extract_archive_reference(
                data_root,
                case_root,
                model["annual_reference"];
                archive,
            ),
            "daily" => Dict{String, String}(),
        )
        for window in matrix["postprocessing"]["daily_windows"]
            key = "$(first(window))-$(last(window))"
            filename = daily_reference_name(model, window)
            paths[model["id"]]["daily"][key] = extract_archive_reference(
                data_root,
                case_root,
                filename;
                archive,
            )
        end
    end
    return paths
end

function required_variables(model, matrix = load_matrix())
    groups = matrix["scientific_comparison"][model]
    return Set(vcat((String.(names) for names in values(groups))...))
end

function comparison_groups(model, records, matrix = load_matrix())
    return Dict(
        group => Dict(
            "variables" => String.(names),
            "failure_count" => sum(
                get(get(records, name, Dict()), "failure_count", 0) for
                name in names
            ),
        ) for (group, names) in matrix["scientific_comparison"][model]
    )
end

function annual_year_record(model, reference_path, candidate_path, year)
    matrix = load_matrix()
    first_year = first(matrix["history_years"])
    records = Dict{String, Any}()
    metadata_mismatches = String[]
    NCDatasets.NCDataset(reference_path) do reference
        NCDatasets.NCDataset(candidate_path) do candidate
            reference_names = Set(String.(keys(reference)))
            candidate_names = Set(String.(keys(candidate)))
            reference_names == candidate_names ||
                push!(metadata_mismatches, "variable names differ in $year")
            issubset(required_variables(model, matrix), reference_names) ||
                error("MIMICS-CN $model archive is missing required variables")
            issubset(required_variables(model, matrix), candidate_names) ||
                error(
                    "MIMICS-CN $model candidate is missing required variables",
                )
            for name in
                sort!(collect(intersect(reference_names, candidate_names)))
                reference_variable = reference[name]
                candidate_variable = candidate[name]
                reference_dimensions = NCDatasets.dimnames(reference_variable)
                candidate_dimensions = NCDatasets.dimnames(candidate_variable)
                reference_dimensions == candidate_dimensions || push!(
                    metadata_mismatches,
                    "$name dimension order differs in $year",
                )
                eltype(reference_variable) == eltype(candidate_variable) ||
                    push!(
                        metadata_mismatches,
                        "$name element type differs in $year",
                    )
                for attribute_name in comparator().CRITICAL_ATTRIBUTES
                    isequal(
                        comparator().attribute(
                            reference_variable,
                            attribute_name,
                        ),
                        comparator().attribute(
                            candidate_variable,
                            attribute_name,
                        ),
                    ) || push!(
                        metadata_mismatches,
                        "$name attribute $attribute_name differs in $year",
                    )
                end
                time_dimension = findfirst(==("time"), candidate_dimensions)
                isnothing(time_dimension) && year != first_year && continue
                candidate_values = if isnothing(time_dimension)
                    indices = ntuple(_ -> Colon(), ndims(candidate_variable))
                    candidate_variable.var[indices...]
                else
                    casa().annual_mean(candidate_variable, time_dimension)
                end
                reference_indices =
                    ntuple(ndims(reference_variable)) do dimension
                        reference_dimensions[dimension] == "time" ?
                        year - first_year + 1 : Colon()
                    end
                reference_values = reference_variable.var[reference_indices...]
                reference_values isa AbstractArray ||
                    (reference_values = [reference_values])
                candidate_values isa AbstractArray ||
                    (candidate_values = [candidate_values])
                result = comparator().compare_values(
                    reference_values,
                    candidate_values;
                    exact = true,
                )
                records[name] = Dict(
                    "failure_count" => result.failure_count,
                    "missing_mismatch_count" =>
                        result.missing_mismatch_count,
                    "nonfinite_count" => result.nonfinite_count,
                    "sign_change_count" => result.sign_change_count,
                    "max_abs_error" => result.max_abs_error,
                    "max_rel_error" => result.max_rel_error,
                    "first_failure" =>
                        isnothing(result.first_failure) ? Int[] :
                        [year; collect(result.first_failure)],
                )
            end
        end
    end
    failed_variables = sort!([
        name for (name, record) in records if record["failure_count"] > 0
    ])
    return Dict(
        "year" => year,
        "metadata_mismatches" => unique(metadata_mismatches),
        "failed_variables" => failed_variables,
        "all_match" =>
            isempty(metadata_mismatches) && isempty(failed_variables),
        "scientific_group" => comparison_groups(model, records, matrix),
        "variable" => records,
    )
end

function daily_year_record(
    model,
    reference_path,
    candidate_path,
    year,
    first_year,
)
    first_day = (year - first_year) * 365 + 1
    report = comparator().compare_netcdf(
        reference_path,
        candidate_path;
        reference_selectors = Dict("time" => first_day:(first_day + 364)),
    )
    record = casa().comparison_record(report)
    missing = setdiff(required_variables(model), Set(keys(record["variable"])))
    isempty(missing) ||
        error("Daily MIMICS-CN $model comparison is missing variables")
    record["year"] = year
    record["scientific_group"] = comparison_groups(model, record["variable"])
    return record
end

function daily_file_complete(path)
    isfile(path) || return false
    try
        return NCDatasets.NCDataset(path) do dataset
            haskey(dataset.dim, "time") && dataset.dim["time"] == 365
        end
    catch
        return false
    end
end

function wait_for_completed_year(paths, next_paths; final_year, finished)
    if final_year
        while !finished[]
            sleep(1)
        end
    else
        while !all(isfile, next_paths) && !finished[]
            sleep(1)
        end
        all(isfile, next_paths) || return false
    end
    return all(daily_file_complete, paths)
end

function stream_historical_outputs!(stage_dir, references, finished, matrix)
    years =
        collect(first(matrix["history_years"]):last(matrix["history_years"]))
    retained = retained_daily_years(matrix)
    for model in MODEL_IDS
        mkpath(joinpath(stage_dir, "annual_comparison", model))
        mkpath(joinpath(stage_dir, "daily_comparison", model))
    end
    for (index, year) in enumerate(years)
        paths = [
            joinpath(stage_dir, netcdf_name(model, year; daily = true)) for
            model in MODEL_IDS
        ]
        next_paths =
            index == length(years) ? String[] :
            [
                joinpath(
                    stage_dir,
                    netcdf_name(model, years[index + 1]; daily = true),
                ) for model in MODEL_IDS
            ]
        while !all(isfile, paths) && !finished[]
            sleep(1)
        end
        all(isfile, paths) || return nothing
        wait_for_completed_year(
            paths,
            next_paths;
            final_year = index == length(years),
            finished,
        ) || return nothing
        for (model, path) in zip(MODEL_IDS, paths)
            annual = annual_year_record(
                model,
                references[model]["annual"],
                path,
                year,
            )
            harness().write_toml_atomic(
                joinpath(stage_dir, annual_fragment(model, year)),
                annual,
            )
            if year in retained
                window = only(
                    filter(
                        range -> first(range) <= year <= last(range),
                        matrix["postprocessing"]["daily_windows"],
                    ),
                )
                key = "$(first(window))-$(last(window))"
                daily = daily_year_record(
                    model,
                    references[model]["daily"][key],
                    path,
                    year,
                    first(window),
                )
                harness().write_toml_atomic(
                    joinpath(stage_dir, daily_fragment(model, year)),
                    daily,
                )
            end
            rm(path; force = true)
        end
    end
    return nothing
end

function historical_retention_hook(references, matrix = load_matrix())
    state = Dict{String, Any}()
    return function (stage, name, stage_dir, event)
        name == "historical" || return nothing
        if event == :before_run
            for filename in readdir(stage_dir)
                occursin(
                    r"^(casaclm|mimics)_pool_flux_\d{4}_daily\.nc$",
                    filename,
                ) || continue
                rm(joinpath(stage_dir, filename); force = true)
            end
            finished = Ref(false)
            state["finished"] = finished
            state["task"] = @async stream_historical_outputs!(
                stage_dir,
                references,
                finished,
                matrix,
            )
        elseif event == :after_run
            state["finished"][] = true
            wait(state["task"])
        end
        return nothing
    end
end

function run_case(source_root, data_root, run_root, case_id)
    source_root = abspath(source_root)
    data_root = abspath(data_root)
    run_root = abspath(run_root)
    matrix = load_matrix()
    case = case_spec(matrix, case_id)
    case_root = joinpath(run_root, case_id)
    candidate_root = joinpath(case_root, "candidates")
    candidates().derive_candidates(source_root, candidate_root)
    workflow = write_full_workflow(
        source_root,
        data_root,
        candidate_root,
        case_root,
        case_id,
    )
    execution_source = casa().ensure_source_revision(
        source_root,
        case["source_commit"],
        case_root,
    )
    executable = abspath(
        harness().ensure_fortran_build(
            execution_source,
            case_root;
            expected_commit = case["source_commit"],
        ),
    )
    archive = archive_record(data_root)
    references = reference_paths(data_root, case_root; archive)
    results = harness().run_stage_workflow(
        executable,
        workflow,
        case_root;
        stage_hook = historical_retention_hook(references, matrix),
    )
    write_case_report(data_root, case_root)
    return results
end

function mimics_restart_diagnostic(mimics_path, casa_path)
    mimics_lines = readlines(mimics_path)
    casa_lines = readlines(casa_path)
    isempty(mimics_lines) && error("Empty MIMICS-CN restart: $mimics_path")
    length(mimics_lines) == length(casa_lines) ||
        error("CASA and MIMICS restart row counts differ")
    header = strip.(split(first(mimics_lines), ','))
    casa_header = strip.(split(first(casa_lines), ','))
    area_column = findfirst(==("casamet%areacell"), casa_header)
    isnothing(area_column) && error("CASA restart has no casamet%areacell")
    columns = Dict(
        "carbon" => findall(
            name ->
                startswith(lowercase(name), "mimicspool%") &&
                !endswith(name, "N"),
            header,
        ),
        "organic_nitrogen" => findall(
            name ->
                startswith(lowercase(name), "mimicspool%") &&
                endswith(name, "N"),
            header,
        ),
    )
    all(!isempty(value) for value in values(columns)) ||
        error("MIMICS-CN restart must contain carbon and nitrogen pools")
    totals =
        Dict(name => zeros(Float64, length(value)) for (name, value) in columns)
    nonfinite = Dict(name => 0 for name in keys(columns))
    for (mimics_line, casa_line) in zip(mimics_lines[2:end], casa_lines[2:end])
        values = split(mimics_line, ','; keepempty = true)
        casa_values = split(casa_line, ','; keepempty = true)
        area = parse(Float64, strip(casa_values[area_column]))
        for (element, element_columns) in columns
            for (index, column) in enumerate(element_columns)
                value = parse(Float64, strip(values[column]))
                nonfinite[element] += !isfinite(value)
                totals[element][index] += value * area * 1.0e-9
            end
        end
    end
    return Dict(
        "path" => abspath(mimics_path),
        "sha256" => sha256sum(mimics_path),
        "area_source" => file_record(casa_path),
        "points" => length(mimics_lines) - 1,
        "nonfinite_count" => nonfinite,
        "total_pg" => Dict(name => sum(value) for (name, value) in totals),
        "pool_pg" => Dict(
            element => Dict(
                header[column] => total for (column, total) in
                zip(columns[element], totals[element])
            ) for element in keys(columns)
        ),
    )
end

function record_unthresholded_nitrogen_assessment!(record)
    record["assessment"] = "reported_without_published_threshold"
    return record
end

function spin_convergence(
    casa_previous,
    casa_final,
    mimics_previous,
    mimics_final,
)
    NCDatasets.NCDataset(casa_previous) do casa_before
        NCDatasets.NCDataset(casa_final) do casa_after
            mineral_nitrogen =
                casa_cn().pool_change(casa_before, casa_after, ("nMineral",))
            NCDatasets.NCDataset(mimics_previous) do mimics_before
                NCDatasets.NCDataset(mimics_final) do mimics_after
                    carbon = casa_cn().pool_change(
                        mimics_before,
                        mimics_after,
                        (
                            "cLITm",
                            "cLITs",
                            "cMICr",
                            "cMICk",
                            "cSOMa",
                            "cSOMc",
                            "cSOMp",
                        ),
                    )
                    organic_nitrogen = casa_cn().pool_change(
                        mimics_before,
                        mimics_after,
                        (
                            "nLITm",
                            "nLITs",
                            "nMICr",
                            "nMICk",
                            "nSOMa",
                            "nSOMc",
                            "nSOMp",
                        ),
                    )
                    record_unthresholded_nitrogen_assessment!(organic_nitrogen)
                    record_unthresholded_nitrogen_assessment!(mineral_nitrogen)
                    carbon["passes_documented_checks"] =
                        carbon["absolute_global_delta_pg"] < 0.01 &&
                        carbon["fraction_below_1_g_m2"] > 0.98 &&
                        carbon["fraction_below_0_1_percent"] > 0.98
                    return Dict(
                        "casa_previous" => file_record(casa_previous),
                        "casa_final" => file_record(casa_final),
                        "mimics_previous" => file_record(mimics_previous),
                        "mimics_final" => file_record(mimics_final),
                        "carbon" => carbon,
                        "organic_nitrogen" => organic_nitrogen,
                        "mineral_nitrogen" => mineral_nitrogen,
                        "nitrogen_assessment_complete" => true,
                        "passes_documented_checks" =>
                            carbon["passes_documented_checks"],
                    )
                end
            end
        end
    end
end

function final_spin_checkpoints()
    return casa_cn().final_spin_checkpoints()
end

function boundary_report(case_root)
    stages_root = joinpath(case_root, "stages")
    boundaries = Dict{String, Any}()
    for stage in STAGE_SPECS
        root = joinpath(stages_root, stage.directory)
        casa_path = joinpath(root, "casa_final.csv")
        mimics_path = joinpath(root, "mimics_final.csv")
        casa_record = casa_cn().restart_diagnostic(casa_path)
        mimics_record = mimics_restart_diagnostic(mimics_path, casa_path)
        casa_record["points"] == 4263 ||
            error("CASA-CN restart boundary does not contain 4,263 points")
        mimics_record["points"] == 4263 ||
            error("MIMICS-CN restart boundary does not contain 4,263 points")
        all(iszero, values(casa_record["nonfinite_count"])) ||
            error("CASA-CN restart contains non-finite pools")
        all(iszero, values(mimics_record["nonfinite_count"])) ||
            error("MIMICS-CN restart contains non-finite pools")
        boundaries[stage.name] =
            Dict("casa" => casa_record, "mimics" => mimics_record)
    end
    previous, final = final_spin_checkpoints()
    convergence = Dict{String, Any}()
    for stage in STAGE_SPECS[2:3]
        root = joinpath(stages_root, stage.directory)
        convergence[stage.name] = spin_convergence(
            joinpath(root, netcdf_name("casa", previous)),
            joinpath(root, netcdf_name("casa", final)),
            joinpath(root, netcdf_name("mimics", previous)),
            joinpath(root, netcdf_name("mimics", final)),
        )
    end
    return Dict(
        "restart_boundary" => boundaries,
        "spin_convergence" => convergence,
    )
end

function annual_comparison(case_root, model)
    matrix = load_matrix()
    historical = joinpath(case_root, "stages", "04-historical")
    years = first(matrix["history_years"]):last(matrix["history_years"])
    combined = casa_cn().combine_annual_records([
        TOML.parsefile(joinpath(historical, annual_fragment(model, year)))
        for year in years
    ])
    records = combined["variable"]
    failed_variables = sort!([
        name for (name, record) in records if record["failure_count"] > 0
    ])
    metadata_mismatches = combined["metadata_mismatches"]
    return Dict(
        "exact_atol" => 0.0,
        "exact_rtol" => 0.0,
        "all_match" =>
            isempty(metadata_mismatches) && isempty(failed_variables),
        "metadata_mismatches" => metadata_mismatches,
        "failed_variables" => failed_variables,
        "scientific_group" => comparison_groups(model, records, matrix),
        "variable" => records,
    )
end

function daily_comparison(case_root, model)
    matrix = load_matrix()
    historical = joinpath(case_root, "stages", "04-historical")
    records = Dict{String, Any}()
    for year in sort!(collect(retained_daily_years(matrix)))
        records[string(year)] =
            TOML.parsefile(joinpath(historical, daily_fragment(model, year)))
    end
    return Dict(
        "exact_atol" => 0.0,
        "exact_rtol" => 0.0,
        "all_match" => all(record["ok"] for record in values(records)),
        "year" => records,
    )
end

function write_case_report(data_root, case_root)
    boundaries = boundary_report(case_root)
    archive = archive_record(data_root)
    annual = Dict(
        model => annual_comparison(case_root, model) for model in MODEL_IDS
    )
    daily =
        Dict(model => daily_comparison(case_root, model) for model in MODEL_IDS)
    convergence_passes = all(
        record["passes_documented_checks"] for
        record in values(boundaries["spin_convergence"])
    )
    nitrogen_assessment_complete = all(
        record["nitrogen_assessment_complete"] &&
            record["organic_nitrogen"]["assessment"] ==
            "reported_without_published_threshold" &&
            record["mineral_nitrogen"]["assessment"] ==
            "reported_without_published_threshold" for
        record in values(boundaries["spin_convergence"])
    )
    control = harness().parse_control(
        joinpath(case_root, "configuration", "controls", "historical.lst"),
    )
    parameter_path = joinpath(
        case_root,
        "stages",
        "04-historical",
        control[:casa_parameters],
    )
    exudation = casa_cn().exudation_audit(parameter_path)
    matches =
        all(record["all_match"] for record in values(annual)) &&
        all(record["all_match"] for record in values(daily)) &&
        convergence_passes &&
        nitrogen_assessment_complete &&
        exudation["all_zero"]
    matrix = load_matrix()
    references = String[]
    for model in matrix["postprocessing"]["model"]
        push!(references, model["annual_reference"])
        for window in matrix["postprocessing"]["daily_windows"]
            push!(
                references,
                "$(model["prefix"])_pool_flux_$(first(window))_$(last(window))_daily.nc",
            )
        end
    end
    reference_root = shared_reference_root(case_root)
    configuration = joinpath(case_root, "configuration")
    report = Dict(
        "schema_version" => 1,
        "case" => basename(case_root),
        "status" => matches ? "matching_setup_pinned" : "mismatch",
        "documented_convergence_checks_pass" => convergence_passes,
        "nitrogen_convergence_assessment_complete" =>
            nitrogen_assessment_complete,
        "nitrogen_convergence_threshold_status" => "no_published_thresholds; changes reported without pass/fail",
        "exudation_zero_verified" => exudation["all_zero"],
        "configuration" => Dict(
            "evidence_matrix" => file_record(MATRIX_PATH),
            "archive_reference" => Dict(
                "archive" => archive,
                "member" => Dict(
                    filename => TOML.parsefile(
                        joinpath(reference_root, filename * ".provenance.toml"),
                    ) for filename in references
                ),
            ),
            "workflow" =>
                file_record(joinpath(configuration, "workflow.toml")),
            "control_diff_report" => file_record(
                joinpath(configuration, "control_diff_report.toml"),
            ),
            "build_metadata" => file_record(
                joinpath(case_root, "build", "build_metadata.toml"),
            ),
            "stage_metadata" => Dict(
                stage.name => file_record(
                    joinpath(
                        case_root,
                        "stages",
                        stage.directory,
                        "stage_metadata.toml",
                    ),
                ) for stage in STAGE_SPECS
            ),
        ),
        "boundaries" => boundaries,
        "exudation" => exudation,
        "annual_comparison" => annual,
        "daily_comparison" => daily,
    )
    path = joinpath(case_root, "reconstruction_report.toml")
    harness().write_toml_atomic(path, report)
    println("MIMICS-CN reconstruction report: $path")
    return path
end

function mismatch_count(report)
    count = sum(
        casa().comparison_mismatch_count(record) for
        record in values(report["annual_comparison"])
    )
    for model in values(report["daily_comparison"]),
        year in values(model["year"])

        count += casa().comparison_mismatch_count(year)
    end
    get(report, "documented_convergence_checks_pass", false) || (count += 1)
    get(report, "exudation_zero_verified", false) || (count += 1)
    return count
end

function run_search(source_root, data_root, run_root)
    matrix = load_matrix()
    attempts = Dict{String, Any}[]
    for compiler in matrix["compiler"]["blocked_candidate"]
        push!(
            attempts,
            Dict(
                "case" => "compiler:" * compiler["id"],
                "status" => compiler["status"],
                "requested_compiler_version" => compiler["version"],
                "blocker" => compiler["reason"],
            ),
        )
    end
    best_case = ""
    best_mismatches = typemax(Int)
    matching_case = ""
    for case in matrix["case"]
        case_id = case["id"]
        try
            run_case(source_root, data_root, run_root, case_id)
            report_path =
                joinpath(run_root, case_id, "reconstruction_report.toml")
            report = TOML.parsefile(report_path)
            build_path =
                joinpath(run_root, case_id, "build", "build_metadata.toml")
            build = TOML.parsefile(build_path)
            mismatches = mismatch_count(report)
            push!(
                attempts,
                Dict(
                    "case" => case_id,
                    "source_commit" => case["source_commit"],
                    "status" => report["status"],
                    "mismatch_count" => mismatches,
                    "report" => abspath(report_path),
                    "report_sha256" => sha256sum(report_path),
                    "build_metadata" => abspath(build_path),
                    "build_metadata_sha256" => sha256sum(build_path),
                    "compiler_version" => build["build"]["compiler_version"],
                ),
            )
            if mismatches < best_mismatches
                best_case = case_id
                best_mismatches = mismatches
            end
            if report["status"] == "matching_setup_pinned"
                matching_case = case_id
                break
            end
        catch error_value
            push!(
                attempts,
                Dict(
                    "case" => case_id,
                    "source_commit" => case["source_commit"],
                    "status" => "blocked",
                    "blocker" => sprint(showerror, error_value),
                ),
            )
        end
    end
    runnable = filter(
        attempt -> attempt["status"] != "blocked_unavailable_toolchain",
        attempts,
    )
    blocked = filter(attempt -> attempt["status"] == "blocked", runnable)
    tested_compilers = unique([
        attempt["compiler_version"] for
        attempt in runnable if haskey(attempt, "compiler_version")
    ])
    status, blocker = if !isempty(matching_case)
        ("matching_setup_pinned", "")
    elseif !isempty(blocked)
        (
            "blocked",
            join(
                ["$(item["case"]): $(item["blocker"])" for item in blocked],
                "; ",
            ),
        )
    else
        (
            "evidence_backed_matrix_exhausted",
            "No evidence-backed setup exactly reconstructs the archive. " *
            "Tested compiler(s): $(join(tested_compilers, "; ")). " *
            "The archive compiler is unrecorded and GNU Fortran 8.1.0 is unavailable.",
        )
    end
    report = Dict(
        "schema_version" => 1,
        "evidence_matrix" => file_record(MATRIX_PATH),
        "status" => status,
        "matching_case" => matching_case,
        "best_case" => best_case,
        "best_mismatch_count" =>
            best_mismatches == typemax(Int) ? -1 : best_mismatches,
        "blocker" => blocker,
        "attempt" => attempts,
    )
    path = joinpath(run_root, "search_report.toml")
    harness().write_toml_atomic(path, report)
    println("MIMICS-CN reconstruction search report: $path")
    return path
end

function self_test()
    matrix = load_matrix()
    Test.@testset "MIMICS-CN reconstruction" begin
        Test.@test matrix["issue"] == 25
        Test.@test matrix["points"] == 4263
        Test.@test matrix["prespin_loops"] == 100
        Test.@test matrix["spin_loops"] == 499
        Test.@test final_spin_checkpoints() == (9960, 9980)
        Test.@test map(stage -> stage.name, STAGE_SPECS) ==
                   ("prespin", "spin", "spin_continuation", "historical")
        Test.@test Set(keys(candidate_paths())) == Set(CANDIDATE_IDS)
        Test.@test "DIN" in required_variables("mimics", matrix)
        Test.@test "cOverflow_r" in required_variables("mimics", matrix)
        Test.@test "nMinUptake" in required_variables("casa", matrix)
        Test.@test "nMinLoss" in required_variables("casa", matrix)
        Test.@test matrix["postprocessing"]["spin_checkpoint_interval"] == 9960
        nitrogen_assessment = record_unthresholded_nitrogen_assessment!(
            Dict{String, Any}("absolute_global_delta_pg" => 0.1),
        )
        Test.@test nitrogen_assessment["assessment"] ==
                   "reported_without_published_threshold"
        Test.@test daily_reference_name(
            model_spec("mimics", matrix),
            [1901, 1905],
        ) == "mimics_pool_flux_1901_1905_daily.nc"
        Test.@test only(matrix["case"])["source_commit"] ==
                   "82c57f8aa1179865d9752b617493ef06f45c3266"
        outputs = historical_stage_outputs(matrix)
        Test.@test annual_fragment("casa", 1901) in outputs
        Test.@test annual_fragment("mimics", 2014) in outputs
        Test.@test daily_fragment("casa", 1905) in outputs
        Test.@test !(daily_fragment("mimics", 1906) in outputs)
        mktempdir() do root
            control = harness().write_smoke_control(
                root;
                points = 4263,
                loops = 499,
                initialization = 3,
                years = (1901, 1920),
                soil_model = 2,
                cycle = 2,
            )
            staged = joinpath(root, "staged.lst")
            write_staged_control(
                control,
                staged,
                Dict(:netcdf_interval => 9960),
            )
            parsed = harness().parse_control(staged)
            Test.@test parsed[:soil_model] == 2
            Test.@test parsed[:cycle] == 2
            Test.@test casa().annual_output_years(parsed) == [1, 9960, 9980]

            casa_restart = joinpath(root, "casa.csv")
            write(
                casa_restart,
                "casamet%areacell,casapool%cplant(LEAF),casapool%nsoilmin\n" *
                "1000000,2,0.1\n2000000,4,0.2\n",
            )
            mimics_restart = joinpath(root, "mimics.csv")
            write(
                mimics_restart,
                "mimicspool%LITm,mimicspool%SOMp,mimicspool%LITmN," *
                "mimicspool%SOMpN\n1,2,0.1,0.2\n2,3,0.2,0.3\n",
            )
            diagnostic = mimics_restart_diagnostic(mimics_restart, casa_restart)
            Test.@test diagnostic["points"] == 2
            Test.@test diagnostic["total_pg"]["carbon"] ≈ 1.3e-2
            Test.@test diagnostic["total_pg"]["organic_nitrogen"] ≈ 1.3e-3
        end
    end
    return true
end

function usage(io = stdout)
    println(
        io,
        "Usage: julia mimics_cn_reconstruction.jl run-case " *
        "<source-repo> <data-root> <run-root> <case-id>",
    )
    println(
        io,
        "       julia mimics_cn_reconstruction.jl report-case " *
        "<data-root> <run-root> <case-id>",
    )
    println(
        io,
        "       julia mimics_cn_reconstruction.jl search " *
        "<source-repo> <data-root> <run-root>",
    )
    println(io, "       julia mimics_cn_reconstruction.jl self-test")
end

function main(args)
    isempty(args) && (usage(stderr); return 2)
    try
        if args[1] == "run-case"
            length(args) == 5 || error("run-case requires four arguments")
            run_case(args[2], args[3], args[4], args[5])
            return 0
        elseif args[1] == "report-case"
            length(args) == 4 || error("report-case requires three arguments")
            write_case_report(args[2], joinpath(args[3], args[4]))
            return 0
        elseif args[1] == "search"
            length(args) == 4 || error("search requires three arguments")
            run_search(args[2], args[3], args[4])
            return 0
        elseif args[1] == "self-test"
            self_test()
            return 0
        end
        usage(stderr)
        return 2
    catch error_value
        println(stderr, "error: ", sprint(showerror, error_value))
        return 1
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end

end
