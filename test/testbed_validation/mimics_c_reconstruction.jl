if !isdefined(@__MODULE__, :TestbedCASACReconstruction)
    include(joinpath(@__DIR__, "casa_c_reconstruction.jl"))
end

module TestbedMIMICSCReconstruction

import TOML
import Test

import NCDatasets

# ============================================================================
# Evidence Matrix and Shared Harness
# ============================================================================

const MATRIX_PATH = joinpath(@__DIR__, "mimics_c_reconstruction.toml")
const CANDIDATE_SPEC_PATH = joinpath(@__DIR__, "candidate_reconstruction.toml")
const STAGE_SPECS = (
    (
        name = "prespin",
        control_id = "mimics_c_prespin",
        directory = "01-prespin",
    ),
    (name = "spin", control_id = "mimics_c_spin", directory = "02-spin"),
    (
        name = "historical",
        control_id = "mimics_c_history",
        directory = "03-historical",
    ),
)
const CONTROL_IDS = map(stage -> stage.control_id, STAGE_SPECS)
const HISTORICAL_STAGE_DIRECTORY = last(STAGE_SPECS).directory

casa() = getfield(parentmodule(@__MODULE__), :TestbedCASACReconstruction)
harness() = casa().harness()
candidates() = casa().candidates()
comparator() = casa().comparator()
sha256sum(path) = casa().sha256sum(path)
file_record(path) = casa().file_record(path)

"""
    load_matrix(path = MATRIX_PATH)

Load and validate the bounded MIMICS-C evidence matrix.
"""
function load_matrix(path = MATRIX_PATH)
    matrix = TOML.parsefile(path)
    get(matrix, "schema_version", 0) == 1 ||
        error("Unsupported MIMICS-C reconstruction matrix schema")
    matrix["points"] == 4263 ||
        error("MIMICS-C matrix must retain 4,263 points")
    matrix["comparison_atol"] == 0.0 ||
        error("MIMICS-C comparison must be exact")
    matrix["comparison_rtol"] == 0.0 ||
        error("MIMICS-C comparison must be exact")
    matrix["stages"]["prespin"]["loops"] == matrix["prespin_loops"] ||
        error("MIMICS-C prespin matrix is inconsistent")
    matrix["stages"]["spin"]["loops"] == matrix["spin_loops"] ||
        error("MIMICS-C spin matrix is inconsistent")
    matrix["stages"]["spin"]["years"] == matrix["spin_years"] ||
        error("MIMICS-C spin years are inconsistent")
    matrix["stages"]["historical"]["years"] == matrix["history_years"] ||
        error("MIMICS-C history matrix is inconsistent")
    models = matrix["postprocessing"]["model"]
    Set(model["id"] for model in models) == Set(("casa", "mimics")) ||
        error("MIMICS-C matrix must compare CASA and MIMICS output")
    blocked_compilers = matrix["compiler"]["blocked_candidate"]
    length(blocked_compilers) == 1 ||
        error("MIMICS-C matrix must record the unavailable source compiler")
    only(blocked_compilers)["status"] == "blocked_unavailable_toolchain" ||
        error("MIMICS-C source compiler must be explicitly blocked")
    return matrix
end

function case_spec(matrix, id)
    matching = filter(case -> case["id"] == id, matrix["case"])
    length(matching) == 1 || error("Unknown or duplicate MIMICS-C case: $id")
    return only(matching)
end

function candidate_control_paths(spec_path = CANDIDATE_SPEC_PATH)
    spec = TOML.parsefile(spec_path)
    selected = Dict{String, String}()
    for candidate in spec["candidate"]
        candidate["id"] in CONTROL_IDS || continue
        selected[candidate["id"]] = candidate["destination"]
    end
    Set(keys(selected)) == Set(CONTROL_IDS) || error(
        "Candidate specification does not define the complete MIMICS-C chain",
    )
    return selected
end

# ============================================================================
# Workflow Construction and Execution
# ============================================================================

netcdf_name(prefix, year; daily = false) =
    "$(prefix)_pool_flux_$(lpad(year, 4, '0'))$(daily ? "_daily" : "").nc"

function annual_output_years(control)
    casa().annual_output_years(control)
end

function stage_definition(name, control_path, inputs)
    control = harness().parse_control(control_path)
    outputs = [
        control[:casa_final],
        control[:casa_flux_final],
        control[:mimics_final],
    ]
    years = if control[:initialization] == 2
        first(control[:years]):last(control[:years])
    else
        annual_output_years(control)
    end
    for prefix in ("casaclm", "mimics")
        append!(
            outputs,
            netcdf_name.(
                prefix,
                years;
                daily = control[:initialization] == 2 &&
                    control[:daily_output] == 1,
            ),
        )
    end
    if control[:initialization] == 0
        push!(outputs, control[:casa_netcdf], control[:mimics_netcdf])
    end
    return Dict(
        "name" => name,
        "control" => relpath(control_path, dirname(dirname(control_path))),
        "outputs" => outputs,
        "input" => inputs,
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
        if before != after_string
            push!(
                diffs,
                Dict(
                    "line" => line,
                    "field" => string(field),
                    "before" => before,
                    "after" => after_string,
                ),
            )
            lines[line] =
                casa().replace_control_value(lines[line], after_string)
        end
    end
    mkpath(dirname(destination))
    write(destination, join(lines))
    control = harness().parse_control(destination)
    control[:points] == 4263 ||
        error("Staged MIMICS-C control does not use 4,263 points")
    control[:soil_model] == 2 || error("Staged control is not MIMICS")
    control[:cycle] == 1 || error("Staged control is not carbon-only")
    return Dict(
        "source" => abspath(source),
        "source_sha256" => sha256sum(source),
        "staged" => abspath(destination),
        "staged_sha256" => sha256sum(destination),
        "diff" => diffs,
    )
end

function common_inputs(source_root, data_root, years)
    source_root = abspath(source_root)
    data_root = abspath(data_root)
    matrix = load_matrix()
    inputs = matrix["inputs"]
    workflow_input = harness().workflow_input
    records = [
        workflow_input(joinpath(source_root, inputs["grid"]), "grid.csv"),
        workflow_input(
            joinpath(source_root, inputs["casa_parameters"]),
            "casa_parameters.csv",
        ),
        workflow_input(
            joinpath(source_root, inputs["phenology"]),
            "phenology.txt",
        ),
        workflow_input(joinpath(source_root, inputs["soil"]), "soil.csv"),
        workflow_input(
            joinpath(source_root, inputs["mimics_parameters"]),
            "mimics_parameters.csv",
        ),
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

"""
    write_full_workflow(source_root, data_root, candidate_root, run_root, case_id)

Materialize the three-stage carbon-only workflow for one evidence-backed case.
"""
function write_full_workflow(
    source_root,
    data_root,
    candidate_root,
    run_root,
    case_id,
)
    matrix = load_matrix()
    case = case_spec(matrix, case_id)
    control_candidates = candidate_control_paths()
    candidate_spec = TOML.parsefile(CANDIDATE_SPEC_PATH)
    configuration = joinpath(run_root, "configuration")
    controls = joinpath(configuration, "controls")
    mkpath(controls)
    mimics_parameter_path =
        joinpath(source_root, matrix["inputs"]["mimics_parameters"])
    sha256sum(mimics_parameter_path) ==
    matrix["inputs"]["mimics_parameters_sha256"] ||
        error("MIMICS-C KO4 parameter hash differs from the evidence matrix")
    reports = Dict{String, Any}[]
    common_overrides = Dict(
        :points => 4263,
        :soil_model => 2,
        :cycle => 1,
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
    controls_by_stage = Dict{String, String}()
    for stage_spec in STAGE_SPECS
        name = stage_spec.name
        candidate_id = stage_spec.control_id
        stage_matrix = matrix["stages"][name]
        candidate_id == stage_matrix["control_candidate"] ||
            error("MIMICS-C $name control matrix is inconsistent")
        source = joinpath(candidate_root, control_candidates[candidate_id])
        destination = joinpath(controls, "$name.lst")
        report = write_staged_control(source, destination, common_overrides)
        candidate = only(
            filter(
                item -> item["id"] == candidate_id,
                candidate_spec["candidate"],
            ),
        )
        committed_control = joinpath(source_root, candidate["source"])
        report["committed_mimics_cn_control"] = file_record(committed_control)
        report["complete_diff_from_committed_mimics_cn"] =
            casa().complete_control_diff(committed_control, destination)
        push!(reports, report)
        control = harness().parse_control(destination)
        control[:loops] == stage_matrix["loops"] ||
            error("MIMICS-C $name loop count differs from the evidence matrix")
        [first(control[:years]), last(control[:years])] ==
        stage_matrix["years"] ||
            error("MIMICS-C $name years differ from the evidence matrix")
        controls_by_stage[name] = destination
    end

    stage_years(name) = begin
        years = matrix["stages"][name]["years"]
        first(years):last(years)
    end
    stage_inputs = Dict(
        stage.name =>
            common_inputs(source_root, data_root, stage_years(stage.name))
        for stage in STAGE_SPECS
    )
    for index in 2:length(STAGE_SPECS)
        name = STAGE_SPECS[index].name
        predecessor = STAGE_SPECS[index - 1].name
        push!(
            stage_inputs[name],
            harness().workflow_input(
                "stage:$predecessor/casa_final.csv",
                "casa_initial.csv",
            ),
        )
        push!(
            stage_inputs[name],
            harness().workflow_input(
                "stage:$predecessor/mimics_final.csv",
                "mimics_initial.csv",
            ),
        )
    end
    stages = [
        stage_definition(
            stage.name,
            controls_by_stage[stage.name],
            stage_inputs[stage.name],
        ) for stage in STAGE_SPECS
    ]
    workflow = Dict(
        "schema_version" => 1,
        "name" => "mimics-c-archive-reconstruction-$case_id",
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
            "candidate_derivation_report" => abspath(derivation_report),
            "candidate_derivation_report_sha256" =>
                sha256sum(derivation_report),
            "evidence_matrix" => abspath(MATRIX_PATH),
            "evidence_matrix_sha256" => sha256sum(MATRIX_PATH),
            "mimics_parameter" => file_record(mimics_parameter_path),
            "staged_control" => reports,
        ),
    )
    return workflow_path
end

"""
    run_case(source_root, data_root, run_root, case_id)

Run one pinned reconstruction case and write its scientific comparison report.
"""
function run_case(source_root, data_root, run_root, case_id)
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
    results = harness().run_stage_workflow(executable, workflow, case_root)
    write_case_report(data_root, case_root)
    return results
end

# ============================================================================
# Restart and Convergence Diagnostics
# ============================================================================

"""
    mimics_restart_diagnostic(mimics_path, casa_path)

Summarize MIMICS restart carbon using grid-cell areas from the paired CASA restart.
"""
function mimics_restart_diagnostic(mimics_path, casa_path)
    mimics_lines = readlines(mimics_path)
    casa_lines = readlines(casa_path)
    isempty(mimics_lines) && error("Empty MIMICS restart: $mimics_path")
    length(mimics_lines) == length(casa_lines) ||
        error("CASA and MIMICS restart row counts differ")
    mimics_header = strip.(split(first(mimics_lines), ','))
    casa_header = strip.(split(first(casa_lines), ','))
    area_column = findfirst(==("casamet%areacell"), casa_header)
    isnothing(area_column) && error("CASA restart has no casamet%areacell")
    carbon_columns = findall(
        name ->
            startswith(lowercase(name), "mimicspool%") &&
                !endswith(lowercase(name), "n"),
        mimics_header,
    )
    isempty(carbon_columns) && error("MIMICS restart has no carbon pools")
    pool_totals = zeros(Float64, length(carbon_columns))
    nonfinite_count = 0
    for (mimics_line, casa_line) in zip(mimics_lines[2:end], casa_lines[2:end])
        values = split(mimics_line, ','; keepempty = true)
        casa_values = split(casa_line, ','; keepempty = true)
        area = parse(Float64, strip(casa_values[area_column]))
        for (index, column) in enumerate(carbon_columns)
            value = parse(Float64, strip(values[column]))
            nonfinite_count += !isfinite(value)
            pool_totals[index] += value * area * 1.0e-9
        end
    end
    return Dict(
        "path" => abspath(mimics_path),
        "sha256" => sha256sum(mimics_path),
        "area_source" => file_record(casa_path),
        "points" => length(mimics_lines) - 1,
        "nonfinite_count" => nonfinite_count,
        "total_carbon_pg" => sum(pool_totals),
        "pool_carbon_pg" => Dict(
            mimics_header[column] => total for
            (column, total) in zip(carbon_columns, pool_totals)
        ),
    )
end

"""
    spin_convergence(previous_path, final_path)

Evaluate the documented seven-pool MIMICS convergence checks between cycle endpoints.
"""
function spin_convergence(previous_path, final_path)
    pool_names = ("cLITm", "cLITs", "cMICr", "cMICk", "cSOMa", "cSOMc", "cSOMp")
    NCDatasets.NCDataset(previous_path) do previous
        NCDatasets.NCDataset(final_path) do final
            previous_soc = sum(previous[name][:, :, end] for name in pool_names)
            final_soc = sum(final[name][:, :, end] for name in pool_names)
            landarea = final["landarea"][:, :]
            active = final["cellMissing"][:, :] .== 0
            global_delta_pg = 0.0
            below_one = 0
            below_fraction = 0
            points = 0
            for index in eachindex(previous_soc, final_soc, landarea, active)
                active[index] || continue
                values =
                    (previous_soc[index], final_soc[index], landarea[index])
                any(ismissing, values) && continue
                before, after, area = values
                difference = abs(Float64(after) - Float64(before))
                global_delta_pg +=
                    (Float64(after) - Float64(before)) * Float64(area) * 1.0e-9
                below_one += difference < 1.0
                below_fraction +=
                    difference == 0 ||
                    (before != 0 && difference / abs(Float64(before)) < 0.001)
                points += 1
            end
            fraction_below_one = below_one / points
            fraction_below_fraction = below_fraction / points
            return Dict(
                "previous" => file_record(previous_path),
                "final" => file_record(final_path),
                "pool_variables" => collect(pool_names),
                "active_points" => points,
                "absolute_global_delta_pg" => abs(global_delta_pg),
                "fraction_below_1_g_m2" => fraction_below_one,
                "fraction_below_0_1_percent" => fraction_below_fraction,
                "passes_documented_checks" =>
                    abs(global_delta_pg) < 0.01 &&
                    fraction_below_one > 0.98 &&
                    fraction_below_fraction > 0.98,
            )
        end
    end
end

"""
    boundary_report(case_root)

Record paired restart diagnostics and convergence evidence for every stage boundary.
"""
function boundary_report(case_root)
    stages = joinpath(case_root, "stages")
    boundaries = Dict{String, Any}()
    for stage_spec in STAGE_SPECS
        name = stage_spec.name
        directory = stage_spec.directory
        stage = joinpath(stages, directory)
        casa_path = joinpath(stage, "casa_final.csv")
        mimics_path = joinpath(stage, "mimics_final.csv")
        casa_record = casa().restart_diagnostic(casa_path)
        mimics_record = mimics_restart_diagnostic(mimics_path, casa_path)
        casa_record["points"] == 4263 ||
            error("CASA restart boundary does not contain 4,263 points")
        mimics_record["points"] == 4263 ||
            error("MIMICS restart boundary does not contain 4,263 points")
        casa_record["nonfinite_count"] == 0 ||
            error("CASA restart boundary contains non-finite carbon")
        mimics_record["nonfinite_count"] == 0 ||
            error("MIMICS restart boundary contains non-finite carbon")
        boundaries[name] =
            Dict("casa" => casa_record, "mimics" => mimics_record)
    end
    previous_checkpoint, final_checkpoint = final_spin_checkpoints()
    spin_stage = joinpath(stages, STAGE_SPECS[2].directory)
    convergence = Dict(
        "spin" => spin_convergence(
            joinpath(spin_stage, netcdf_name("mimics", previous_checkpoint)),
            joinpath(spin_stage, netcdf_name("mimics", final_checkpoint)),
        ),
    )
    return Dict(
        "restart_boundary" => boundaries,
        "spin_convergence" => convergence,
    )
end

# ============================================================================
# Archive References and Scientific Comparisons
# ============================================================================

function archive_record(data_root)
    artifacts = filter(
        artifact -> artifact["id"] == "mimics_c_output",
        harness().load_manifest()["artifact"],
    )
    length(artifacts) == 1 || error("MIMICS-C archive manifest is ambiguous")
    artifact = only(artifacts)
    path = joinpath(data_root, artifact["filename"])
    isfile(path) || error("Missing MIMICS-C archive: $path")
    filesize(path) == artifact["bytes"] ||
        error("MIMICS-C archive size does not match the manifest: $path")
    digest = harness().md5sum(path)
    digest == artifact["md5"] ||
        error("MIMICS-C archive MD5 does not match the manifest: $path")
    return Dict(
        "path" => abspath(path),
        "filename" => artifact["filename"],
        "bytes" => artifact["bytes"],
        "md5" => digest,
        "url" => artifact["url"],
        "source" => artifact["source"],
    )
end

function extract_archive_reference(
    data_root,
    case_root,
    filename;
    archive = archive_record(data_root),
)
    reference_root = joinpath(case_root, "reference")
    destination = joinpath(reference_root, filename)
    member = joinpath("MIMICS_mod5_Conly_KO4", "OUTPUT_C", "HIST", filename)
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

model_spec(id) = only(
    filter(
        model -> model["id"] == id,
        load_matrix()["postprocessing"]["model"],
    ),
)

"""
    annual_mean_values(raw, time_dimension; fill_value = nothing)

Reduce one daily year with the value and fill semantics used by the archive check.
"""
function annual_mean_values(raw, time_dimension; fill_value = nothing)
    averaged =
        dropdims(
            sum(Float64.(raw); dims = time_dimension);
            dims = time_dimension,
        ) ./ size(raw, time_dimension)
    output = if eltype(raw) <: Integer
        round.(eltype(raw), averaged)
    else
        eltype(raw).(averaged)
    end
    if !isnothing(fill_value)
        missing_mask = selectdim(raw, time_dimension, 1) .== fill_value
        output[missing_mask] .= fill_value
    end
    return output
end

"""
    daily_comparison(data_root, case_root, model_id; archive)

Compare both retained five-year daily windows exactly for one model stream.
"""
function daily_comparison(
    data_root,
    case_root,
    model_id;
    archive = archive_record(data_root),
)
    model = model_spec(model_id)
    historical = joinpath(case_root, "stages", HISTORICAL_STAGE_DIRECTORY)
    comparisons = Dict{String, Any}()
    for window in load_matrix()["postprocessing"]["daily_windows"]
        years = first(window):last(window)
        reference = extract_archive_reference(
            data_root,
            case_root,
            "$(model["prefix"])_pool_flux_$(first(years))_$(last(years))_daily.nc";
            archive,
        )
        for year in years
            first_day = (year - first(years)) * 365 + 1
            report = comparator().compare_netcdf(
                reference,
                joinpath(
                    historical,
                    netcdf_name(model["prefix"], year; daily = true),
                );
                reference_selectors = Dict(
                    "time" => first_day:(first_day + 364),
                ),
            )
            comparisons[string(year)] = casa().comparison_record(report)
        end
    end
    return Dict(
        "exact_atol" => 0.0,
        "exact_rtol" => 0.0,
        "all_match" => all(record["ok"] for record in values(comparisons)),
        "year" => comparisons,
    )
end

"""
    annual_comparison(data_root, case_root, model_id; archive)

Compare 1901--2014 annual means exactly for one model stream.
"""
function annual_comparison(
    data_root,
    case_root,
    model_id;
    archive = archive_record(data_root),
)
    matrix = load_matrix()
    model = model_spec(model_id)
    reference_path = extract_archive_reference(
        data_root,
        case_root,
        model["annual_reference"];
        archive,
    )
    historical = joinpath(case_root, "stages", HISTORICAL_STAGE_DIRECTORY)
    history_years = matrix["stages"]["historical"]["years"]
    records = Dict{String, Any}()
    metadata_mismatches = String[]
    NCDatasets.NCDataset(reference_path) do reference
        reference_names = Set(String.(keys(reference)))
        for year in first(history_years):last(history_years)
            candidate_path = joinpath(
                historical,
                netcdf_name(model["prefix"], year; daily = true),
            )
            NCDatasets.NCDataset(candidate_path) do candidate
                candidate_names = Set(String.(keys(candidate)))
                reference_names == candidate_names ||
                    push!(metadata_mismatches, "variable names differ in $year")
                for name in
                    sort!(collect(intersect(reference_names, candidate_names)))
                    reference_variable = reference[name]
                    candidate_variable = candidate[name]
                    candidate_dimensions =
                        NCDatasets.dimnames(candidate_variable)
                    reference_dimensions =
                        NCDatasets.dimnames(reference_variable)
                    candidate_dimensions == reference_dimensions || push!(
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
                    isnothing(time_dimension) &&
                        year != first(history_years) &&
                        continue
                    candidate_values = if isnothing(time_dimension)
                        indices =
                            ntuple(_ -> Colon(), ndims(candidate_variable))
                        candidate_variable.var[indices...]
                    else
                        indices =
                            ntuple(_ -> Colon(), ndims(candidate_variable))
                        annual_mean_values(
                            candidate_variable.var[indices...],
                            time_dimension;
                            fill_value = haskey(
                                candidate_variable.attrib,
                                "_FillValue",
                            ) ? candidate_variable.attrib["_FillValue"] :
                                         nothing,
                        )
                    end
                    reference_indices =
                        ntuple(ndims(reference_variable)) do dimension
                            reference_dimensions[dimension] == "time" ?
                            year - first(history_years) + 1 : Colon()
                        end
                    reference_values =
                        reference_variable.var[reference_indices...]
                    reference_values isa AbstractArray ||
                        (reference_values = [reference_values])
                    candidate_values isa AbstractArray ||
                        (candidate_values = [candidate_values])
                    result = comparator().compare_values(
                        reference_values,
                        candidate_values;
                        exact = true,
                    )
                    record = get!(records, name) do
                        Dict(
                            "failure_count" => 0,
                            "missing_mismatch_count" => 0,
                            "nonfinite_count" => 0,
                            "sign_change_count" => 0,
                            "max_abs_error" => 0.0,
                            "max_rel_error" => 0.0,
                            "first_failure" => Int[],
                        )
                    end
                    casa().accumulate_result!(record, result, year)
                end
            end
        end
    end
    failed_variables = sort!([
        name for (name, record) in records if record["failure_count"] > 0
    ])
    return Dict(
        "exact_atol" => 0.0,
        "exact_rtol" => 0.0,
        "all_match" =>
            isempty(metadata_mismatches) && isempty(failed_variables),
        "metadata_mismatches" => unique(metadata_mismatches),
        "failed_variables" => failed_variables,
        "variable" => records,
    )
end

"""
    archive_annual_reduction_validation(data_root, case_root; archive)

Verify that the in-process annual reduction exactly reproduces archived NCO output.
"""
function archive_annual_reduction_validation(
    data_root,
    case_root;
    archive = archive_record(data_root),
)
    matrix = load_matrix()
    models = Dict{String, Any}()
    total_failures = 0
    for model in matrix["postprocessing"]["model"]
        annual_path = extract_archive_reference(
            data_root,
            case_root,
            model["annual_reference"];
            archive,
        )
        years = Dict{String, Any}()
        NCDatasets.NCDataset(annual_path) do annual
            for window in matrix["postprocessing"]["daily_windows"]
                first_year, last_year = window
                daily_path = extract_archive_reference(
                    data_root,
                    case_root,
                    "$(model["prefix"])_pool_flux_$(first_year)_$(last_year)_daily.nc";
                    archive,
                )
                NCDatasets.NCDataset(daily_path) do daily
                    common_names =
                        intersect(String.(keys(annual)), String.(keys(daily)))
                    for year in first_year:last_year
                        failure_count = 0
                        checked_variables = 0
                        for name in common_names
                            daily_variable = daily[name]
                            annual_variable = annual[name]
                            daily_dimensions =
                                NCDatasets.dimnames(daily_variable)
                            time_dimension =
                                findfirst(==("time"), daily_dimensions)
                            isnothing(time_dimension) && continue
                            first_day = (year - first_year) * 365 + 1
                            daily_indices =
                                ntuple(ndims(daily_variable)) do dimension
                                    dimension == time_dimension ?
                                    (first_day:(first_day + 364)) : Colon()
                                end
                            reduced = annual_mean_values(
                                daily_variable.var[daily_indices...],
                                time_dimension;
                                fill_value = haskey(
                                    daily_variable.attrib,
                                    "_FillValue",
                                ) ? daily_variable.attrib["_FillValue"] :
                                             nothing,
                            )
                            annual_dimensions =
                                NCDatasets.dimnames(annual_variable)
                            annual_indices =
                                ntuple(ndims(annual_variable)) do dimension
                                    annual_dimensions[dimension] == "time" ?
                                    year - first(matrix["history_years"]) + 1 :
                                    Colon()
                                end
                            reference = annual_variable.var[annual_indices...]
                            reference isa AbstractArray ||
                                (reference = [reference])
                            reduced isa AbstractArray || (reduced = [reduced])
                            result = comparator().compare_values(
                                reference,
                                reduced;
                                exact = true,
                            )
                            failure_count += result.failure_count
                            checked_variables += 1
                        end
                        years[string(year)] = Dict(
                            "checked_variables" => checked_variables,
                            "failure_count" => failure_count,
                        )
                        total_failures += failure_count
                    end
                end
            end
        end
        models[model["id"]] = Dict("year" => years)
    end
    return Dict(
        "archive_pipeline" => "NCO 4.7.5 ncra followed by ncrcat",
        "candidate_reduction" => "Float64 sum divided by 365 and cast to source type",
        "validated_windows" => matrix["postprocessing"]["daily_windows"],
        "failure_count" => total_failures,
        "all_match" => total_failures == 0,
        "model" => models,
    )
end

# ============================================================================
# Reports and Evidence Search
# ============================================================================

"""
    write_case_report(data_root, case_root)

Write the convergence, restart, provenance, and comparison report for one case.
"""
function write_case_report(data_root, case_root)
    boundaries = boundary_report(case_root)
    archive = archive_record(data_root)
    annual = Dict(
        id => annual_comparison(data_root, case_root, id; archive) for
        id in ("casa", "mimics")
    )
    daily = Dict(
        id => daily_comparison(data_root, case_root, id; archive) for
        id in ("casa", "mimics")
    )
    reduction_validation =
        archive_annual_reduction_validation(data_root, case_root; archive)
    convergence_passes = all(
        record["passes_documented_checks"] for
        record in values(boundaries["spin_convergence"])
    )
    matches =
        all(record["all_match"] for record in values(annual)) &&
        all(record["all_match"] for record in values(daily)) &&
        reduction_validation["all_match"] &&
        convergence_passes
    configuration = joinpath(case_root, "configuration")
    build_metadata = joinpath(case_root, "build", "build_metadata.toml")
    matrix = load_matrix()
    reference_filenames = String[]
    for model in matrix["postprocessing"]["model"]
        push!(reference_filenames, model["annual_reference"])
        for window in matrix["postprocessing"]["daily_windows"]
            push!(
                reference_filenames,
                "$(model["prefix"])_pool_flux_$(first(window))_$(last(window))_daily.nc",
            )
        end
    end
    report = Dict(
        "schema_version" => 1,
        "case" => basename(case_root),
        "status" => matches ? "matching_setup_pinned" : "mismatch",
        "documented_convergence_checks_pass" => convergence_passes,
        "configuration" => Dict(
            "evidence_matrix" => file_record(MATRIX_PATH),
            "archive_reference" => Dict(
                "archive" => archive,
                "member" => Dict(
                    filename => TOML.parsefile(
                        joinpath(
                            case_root,
                            "reference",
                            filename * ".provenance.toml",
                        ),
                    ) for filename in reference_filenames
                ),
            ),
            "workflow" =>
                file_record(joinpath(configuration, "workflow.toml")),
            "control_diff_report" => file_record(
                joinpath(configuration, "control_diff_report.toml"),
            ),
            "build_metadata" => file_record(build_metadata),
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
        "annual_reduction_validation" => reduction_validation,
        "annual_comparison" => annual,
        "daily_comparison" => daily,
    )
    path = joinpath(case_root, "reconstruction_report.toml")
    harness().write_toml_atomic(path, report)
    println("MIMICS-C reconstruction report: $path")
    return path
end

function comparison_mismatch_count(report)
    count = length(get(report, "metadata_mismatches", Any[]))
    for record in values(get(report, "variable", Dict()))
        count += record["failure_count"]
    end
    return count
end

function mismatch_count(report)
    count = sum(
        comparison_mismatch_count(model) for
        model in values(report["annual_comparison"])
    )
    for model in values(report["daily_comparison"]),
        year in values(model["year"])

        count += comparison_mismatch_count(year)
    end
    get(report, "documented_convergence_checks_pass", false) || (count += 1)
    return count
end

"""
    run_search(source_root, data_root, run_root)

Run the bounded evidence matrix and publish the best exact-comparison outcome.
"""
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
    best_mismatch_count = typemax(Int)
    matched_case = ""
    for case in matrix["case"]
        case_id = case["id"]
        try
            run_case(source_root, data_root, run_root, case_id)
            report_path =
                joinpath(run_root, case_id, "reconstruction_report.toml")
            report = TOML.parsefile(report_path)
            build_metadata_path =
                joinpath(run_root, case_id, "build", "build_metadata.toml")
            build_metadata = TOML.parsefile(build_metadata_path)
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
                    "build_metadata" => abspath(build_metadata_path),
                    "build_metadata_sha256" => sha256sum(build_metadata_path),
                    "compiler_version" =>
                        build_metadata["build"]["compiler_version"],
                ),
            )
            if mismatches < best_mismatch_count
                best_case = case_id
                best_mismatch_count = mismatches
            end
            if report["status"] == "matching_setup_pinned"
                matched_case = case_id
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
    tested_compilers = unique([
        attempt["compiler_version"] for
        attempt in attempts if haskey(attempt, "compiler_version")
    ])
    blocked_cases = filter(attempt -> attempt["status"] == "blocked", attempts)
    outcome = if !isempty(matched_case)
        (status = "matching_setup_pinned", blocker = "")
    elseif !isempty(blocked_cases)
        (
            status = "blocked",
            blocker = join(
                [
                    "$(attempt["case"]): $(attempt["blocker"])" for
                    attempt in blocked_cases
                ],
                "; ",
            ),
        )
    else
        blocked_compilers = filter(
            attempt -> attempt["status"] == "blocked_unavailable_toolchain",
            attempts,
        )
        compiler_blocker = join(
            [
                "$(attempt["requested_compiler_version"]): $(attempt["blocker"])"
                for attempt in blocked_compilers
            ],
            "; ",
        )
        (
            status = "evidence_backed_matrix_exhausted",
            blocker = "No runnable evidence-backed source case exactly reconstructs " *
                      "the archive. The archive compiler is not recorded; tested " *
                      "compiler(s): $(join(tested_compilers, "; ")). " *
                      "Blocked documented compiler candidate(s): $compiler_blocker",
        )
    end
    search_report = Dict(
        "schema_version" => 1,
        "evidence_matrix" => file_record(MATRIX_PATH),
        "status" => outcome.status,
        "matching_case" => matched_case,
        "best_case" => best_case,
        "best_mismatch_count" =>
            best_mismatch_count == typemax(Int) ? -1 : best_mismatch_count,
        "blocker" => outcome.blocker,
        "attempt" => attempts,
    )
    path = joinpath(run_root, "search_report.toml")
    harness().write_toml_atomic(path, search_report)
    println("MIMICS-C reconstruction search report: $path")
    return path
end

# ============================================================================
# Self-Test and Command-Line Interface
# ============================================================================

function final_spin_checkpoints()
    matrix = load_matrix()
    cycle_years = length(first(matrix["spin_years"]):last(matrix["spin_years"]))
    final_year = matrix["spin_loops"] * cycle_years
    return final_year - cycle_years, final_year
end

"""
    self_test()

Exercise the reconstruction matrix, output contract, and restart diagnostics.
"""
function self_test()
    matrix = load_matrix()
    Test.@testset "MIMICS-C reconstruction" begin
        Test.@test matrix["points"] == 4263
        Test.@test matrix["prespin_loops"] == 100
        Test.@test matrix["spin_loops"] == 499
        Test.@test matrix["history_years"] == [1901, 2014]
        Test.@test final_spin_checkpoints() == (9960, 9980)
        Test.@test CONTROL_IDS ==
                   ("mimics_c_prespin", "mimics_c_spin", "mimics_c_history")
        Test.@test map(stage -> stage.name, STAGE_SPECS) ==
                   ("prespin", "spin", "historical")
        Test.@test HISTORICAL_STAGE_DIRECTORY == "03-historical"
        Test.@test !haskey(matrix["stages"], "spin_continuation")
        Test.@test length(matrix["case"]) == 1
        Test.@test haskey(matrix["excluded"], "post_archive_q10")
        Test.@test haskey(matrix["excluded"], "post_archive_spin_continuation")
        Test.@test haskey(matrix["excluded"], "history_continuations")
        Test.@test Set(keys(candidate_control_paths())) == Set(CONTROL_IDS)
        Test.@test matrix["inputs"]["mimics_parameters"] ==
                   "GRID_CN/MIMICS_mod5_GSWP3_KO4_push/" *
                   "pftlookup_LIDET-MIM-REV_CN_desorb2xKO4_micCN_FI30.csv"
        Test.@test matrix["inputs"]["mimics_parameters_sha256"] ==
                   "251435a0d914f72e8b498b2661f0067663418ccfcc3389f21cce7ceaff4d9dbf"
        Test.@test only(matrix["compiler"]["blocked_candidate"])["version"] ==
                   "GNU Fortran 8.1.0"
        daily_values = reshape(Float32[1, 3, 2, 4], 2, 2)
        Test.@test annual_mean_values(daily_values, 2) == Float32[1.5, 3.5]
        daily_values_64 = Float64.(daily_values)
        Test.@test annual_mean_values(daily_values_64, 2) == [1.5, 3.5]
        mktempdir() do root
            source = harness().write_smoke_control(
                root;
                points = 4263,
                loops = 499,
                initialization = 3,
                years = (1901, 1920),
                soil_model = 2,
                cycle = 1,
            )
            stage = stage_definition("spin", source, Dict{String, Any}[])
            Test.@test length(stage["outputs"]) == 19963
            Test.@test "casa_final.csv" in stage["outputs"]
            Test.@test "unused_mimics_final.csv" in stage["outputs"]
            Test.@test netcdf_name("mimics", 1901; daily = true) ==
                       "mimics_pool_flux_1901_daily.nc"
            prespin_control = harness().write_smoke_control(
                root;
                points = 4263,
                loops = 100,
                initialization = 0,
                years = (1901, 1901),
                soil_model = 2,
                cycle = 1,
            )
            prespin_stage = stage_definition(
                "prespin",
                prespin_control,
                Dict{String, Any}[],
            )
            Test.@test "casaclm_pool_flux_yyyy.nc" in prespin_stage["outputs"]
            Test.@test "unused_mimics_yyyy.nc" in prespin_stage["outputs"]

            casa_restart = joinpath(root, "casa_restart.csv")
            write(
                casa_restart,
                "casamet%areacell,casapool%cplant(LEAF)\n" *
                "1000000,2\n2000000,4\n",
            )
            mimics_restart = joinpath(root, "mimics_restart.csv")
            write(
                mimics_restart,
                "mimicspool%LITm,mimicspool%LITs,mimicspool%MICr," *
                "mimicspool%MICk,mimicspool%SOMa,mimicspool%SOMc," *
                "mimicspool%SOMp\n1,2,3,4,5,6,7\n2,3,4,5,6,7,8\n",
            )
            diagnostic = mimics_restart_diagnostic(mimics_restart, casa_restart)
            Test.@test diagnostic["points"] == 2
            Test.@test diagnostic["nonfinite_count"] == 0
            Test.@test diagnostic["total_carbon_pg"] ≈ 9.8e-2
        end
    end
    return true
end

function usage(io = stdout)
    println(
        io,
        "Usage: julia mimics_c_reconstruction.jl run-case " *
        "<source-repo> <data-root> <run-root> <case-id>",
    )
    println(
        io,
        "       julia mimics_c_reconstruction.jl report-case " *
        "<data-root> <run-root> <case-id>",
    )
    println(
        io,
        "       julia mimics_c_reconstruction.jl search " *
        "<source-repo> <data-root> <run-root>",
    )
    println(io, "       julia mimics_c_reconstruction.jl self-test")
end

"""
    main(args)

Dispatch the reconstruction command-line interface and return a process exit code.
"""
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
