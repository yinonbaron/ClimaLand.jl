if !isdefined(@__MODULE__, :TestbedReferenceHarness)
    include(joinpath(@__DIR__, "reference_harness.jl"))
end
if !isdefined(@__MODULE__, :TestbedCandidateReconstruction)
    include(joinpath(@__DIR__, "candidate_reconstruction.jl"))
end
if !isdefined(@__MODULE__, :TestbedNetCDFCompare)
    include(joinpath(@__DIR__, "netcdf_compare.jl"))
end

module TestbedCASACReconstruction

import SHA
import Statistics
import TOML
import Test

import NCDatasets

const MATRIX_PATH = joinpath(@__DIR__, "casa_c_reconstruction.toml")
const CANDIDATE_SPEC_PATH = joinpath(@__DIR__, "candidate_reconstruction.toml")
const CONTROL_IDS =
    ("casa_c_prespin", "casa_c_adspin", "casa_c_spin", "casa_c_history")

harness() = getfield(parentmodule(@__MODULE__), :TestbedReferenceHarness)
candidates() =
    getfield(parentmodule(@__MODULE__), :TestbedCandidateReconstruction)
comparator() = getfield(parentmodule(@__MODULE__), :TestbedNetCDFCompare)
sha256sum(path) = bytes2hex(SHA.sha256(read(path)))
file_record(path) = Dict("path" => abspath(path), "sha256" => sha256sum(path))

function load_matrix(path = MATRIX_PATH)
    matrix = TOML.parsefile(path)
    get(matrix, "schema_version", 0) == 1 ||
        error("Unsupported CASA-C reconstruction matrix schema")
    matrix["points"] == 4263 || error("CASA-C matrix must retain 4,263 points")
    matrix["passive_carbon_multiplier"] == 10 || error(
        "CASA-C matrix must retain the documented passive-pool ×10 restoration",
    )
    matrix["comparison_atol"] == 0.0 || error("CASA-C comparison must be exact")
    matrix["comparison_rtol"] == 0.0 || error("CASA-C comparison must be exact")
    matrix["stages"]["prespin"]["loops"] == matrix["prespin_loops"] ||
        error("CASA-C prespin matrix is inconsistent")
    for stage in ("accelerated_spin", "normal_spin")
        matrix["stages"][stage]["loops"] == matrix["spin_loops"] ||
            error("CASA-C $stage matrix is inconsistent")
        matrix["stages"][stage]["years"] == matrix["spin_years"] ||
            error("CASA-C $stage years are inconsistent")
    end
    matrix["stages"]["historical"]["years"] == matrix["history_years"] ||
        error("CASA-C history matrix is inconsistent")
    matrix["transformation"]["passive_restoration"]["multiplier"] ==
    matrix["passive_carbon_multiplier"] ||
        error("CASA-C passive restoration matrix is inconsistent")
    statistics = matrix["statistical_comparison"]
    0 < statistics["global_sum_rtol"] < 1 ||
        error("CASA-C global-stock relative tolerance is invalid")
    0 < statistics["grid_absolute_relative_quantile"] < 1 ||
        error("CASA-C grid-stock quantile is invalid")
    0 < statistics["grid_absolute_relative_rtol"] < 1 ||
        error("CASA-C grid-stock relative tolerance is invalid")
    isempty(statistics["stock_variables"]) &&
        error("CASA-C statistical comparison has no stock variables")
    return matrix
end

function case_spec(matrix, id)
    matching = filter(case -> case["id"] == id, matrix["case"])
    length(matching) == 1 || error("Unknown or duplicate CASA-C case: $id")
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
        "Candidate specification does not define the complete CASA-C chain",
    )
    return selected
end

function replace_control_value(line, after)
    newline = endswith(line, '\n') ? "\n" : ""
    parts = split(chomp(line), '!'; limit = 2)
    leading = something(match(r"^\s*", parts[1])).match
    suffix = length(parts) == 2 ? "!" * parts[2] : ""
    return leading *
           string(after) *
           (isempty(suffix) ? "" : " " * suffix) *
           newline
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
            lines[line] = replace_control_value(lines[line], after_string)
        end
    end
    mkpath(dirname(destination))
    write(destination, join(lines))
    control = harness().parse_control(destination)
    control[:points] == 4263 ||
        error("Staged control does not use 4,263 points")
    control[:soil_model] == 1 || error("Staged control is not CASA")
    control[:cycle] == 1 || error("Staged control is not carbon-only")
    return Dict(
        "source" => abspath(source),
        "source_sha256" => sha256sum(source),
        "staged" => abspath(destination),
        "staged_sha256" => sha256sum(destination),
        "diff" => diffs,
    )
end

function complete_control_diff(source, destination)
    source_lines = readlines(source)
    destination_lines = readlines(destination)
    value(line) = strip(first(split(line, '!'; limit = 2)))
    return [
        Dict(
            "line" => line,
            "field" => string(field),
            "before" => value(source_lines[line]),
            "after" => value(destination_lines[line]),
        ) for (line, field) in enumerate(harness().CONTROL_FIELDS) if
        value(source_lines[line]) != value(destination_lines[line])
    ]
end

function annual_output_years(control)
    years_per_loop = length(first(control[:years]):last(control[:years]))
    total = control[:loops] * years_per_loop
    interval = control[:netcdf_interval]
    return sort!(unique!([1; collect(interval:interval:total); total]))
end

netcdf_name(year; daily = false) =
    "casaclm_pool_flux_$(lpad(year, 4, '0'))$(daily ? "_daily" : "").nc"

function common_inputs(source_root, data_root, years, casa_parameters)
    source_root = abspath(source_root)
    data_root = abspath(data_root)
    casa_parameters = abspath(casa_parameters)
    input_matrix = load_matrix()["inputs"]
    workflow_input = harness().workflow_input
    inputs = [
        workflow_input(joinpath(source_root, input_matrix["grid"]), "grid.csv"),
        workflow_input(casa_parameters, "casa_parameters.csv"),
        workflow_input(
            joinpath(source_root, input_matrix["phenology"]),
            "phenology.txt",
        ),
        workflow_input(joinpath(source_root, input_matrix["soil"]), "soil.csv"),
        workflow_input(
            joinpath(source_root, input_matrix["perturbation"]),
            "perturbation.txt",
        ),
    ]
    driver_root = joinpath(data_root, input_matrix["driver_directory"])
    for year in years
        filename = "met_$(year)_$(year).nc"
        push!(
            inputs,
            workflow_input(
                joinpath(driver_root, filename),
                filename;
                mode = "symlink",
            ),
        )
    end
    return inputs
end

function stage_definition(name, control_path, inputs)
    control = harness().parse_control(control_path)
    outputs = [control[:casa_final], control[:casa_flux_final]]
    if control[:initialization] != 2
        append!(outputs, netcdf_name.(annual_output_years(control)))
        control[:initialization] == 0 && push!(outputs, control[:casa_netcdf])
    else
        append!(
            outputs,
            netcdf_name.(
                first(control[:years]):last(control[:years]);
                daily = control[:daily_output] == 1,
            ),
        )
    end
    return Dict(
        "name" => name,
        "control" => relpath(control_path, dirname(dirname(control_path))),
        "outputs" => outputs,
        "input" => inputs,
    )
end

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
    normal_parameters =
        joinpath(source_root, matrix["inputs"]["normal_parameters"])
    accelerated_parameters =
        joinpath(source_root, matrix["inputs"]["accelerated_parameters"])
    reports = Dict{String, Any}[]

    common_overrides = Dict(
        :points => 4263,
        :soil_model => 1,
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
        :perturbation => "perturbation.txt",
        :point_output_directory => "./",
    )
    controls_by_stage = Dict{String, String}()
    for (name, candidate_id) in zip(
        ("prespin", "accelerated_spin", "normal_spin", "historical"),
        CONTROL_IDS,
    )
        stage_matrix = matrix["stages"][name]
        candidate_id == stage_matrix["control_candidate"] ||
            error("CASA-C $name control matrix is inconsistent")
        source = joinpath(candidate_root, control_candidates[candidate_id])
        destination = joinpath(controls, "$name.lst")
        staged_report =
            write_staged_control(source, destination, common_overrides)
        candidate = only(
            filter(
                candidate -> candidate["id"] == candidate_id,
                candidate_spec["candidate"],
            ),
        )
        committed_control = joinpath(source_root, candidate["source"])
        staged_report["committed_casa_cn_control"] =
            file_record(committed_control)
        staged_report["complete_diff_from_committed_casa_cn"] =
            complete_control_diff(committed_control, destination)
        push!(reports, staged_report)
        control = harness().parse_control(destination)
        control[:loops] == stage_matrix["loops"] ||
            error("CASA-C $name loop count differs from the evidence matrix")
        [first(control[:years]), last(control[:years])] ==
        stage_matrix["years"] ||
            error("CASA-C $name years differ from the evidence matrix")
        controls_by_stage[name] = destination
    end

    stage_years(name) = begin
        years = matrix["stages"][name]["years"]
        first(years):last(years)
    end
    prespin_inputs = common_inputs(
        source_root,
        data_root,
        stage_years("prespin"),
        normal_parameters,
    )
    accelerated_inputs = common_inputs(
        source_root,
        data_root,
        stage_years("accelerated_spin"),
        accelerated_parameters,
    )
    push!(
        accelerated_inputs,
        harness().workflow_input(
            "stage:prespin/casa_final.csv",
            "casa_initial.csv",
        ),
    )
    normal_inputs = common_inputs(
        source_root,
        data_root,
        stage_years("normal_spin"),
        normal_parameters,
    )
    push!(
        normal_inputs,
        harness().workflow_input(
            "stage:accelerated_spin/casa_final.csv",
            "casa_initial.csv";
            transform = "casa_passive_carbon_x10",
        ),
    )
    historical_inputs = common_inputs(
        source_root,
        data_root,
        stage_years("historical"),
        normal_parameters,
    )
    push!(
        historical_inputs,
        harness().workflow_input(
            "stage:normal_spin/casa_final.csv",
            "casa_initial.csv",
        ),
    )

    stages = [
        stage_definition(
            "prespin",
            controls_by_stage["prespin"],
            prespin_inputs,
        ),
        stage_definition(
            "accelerated_spin",
            controls_by_stage["accelerated_spin"],
            accelerated_inputs,
        ),
        stage_definition(
            "normal_spin",
            controls_by_stage["normal_spin"],
            normal_inputs,
        ),
        stage_definition(
            "historical",
            controls_by_stage["historical"],
            historical_inputs,
        ),
    ]
    workflow = Dict(
        "schema_version" => 1,
        "name" => "casa-c-archive-reconstruction-$case_id",
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
            "staged_control" => reports,
        ),
    )
    return workflow_path
end

function ensure_source_revision(source_root, commit, run_root)
    harness().source_commit(source_root) == commit &&
        return abspath(source_root)
    destination = joinpath(run_root, "sources", commit)
    if !isdir(destination)
        mkpath(dirname(destination))
        run(
            `git clone --quiet --no-checkout --no-hardlinks $source_root $destination`,
        )
        run(Cmd(`git checkout --quiet --detach $commit`; dir = destination))
    end
    harness().source_commit(destination) == commit ||
        error("Failed to materialize source revision $commit")
    return destination
end

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
    execution_source =
        ensure_source_revision(source_root, case["source_commit"], case_root)
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

function restart_diagnostic(path)
    lines = readlines(path)
    isempty(lines) && error("Empty restart: $path")
    header = strip.(split(first(lines), ','))
    area_column = findfirst(==("casamet%areacell"), header)
    isnothing(area_column) && error("Restart has no casamet%areacell: $path")
    carbon_columns =
        findall(name -> startswith(lowercase(name), "casapool%c"), header)
    isempty(carbon_columns) && error("Restart has no CASA carbon pools: $path")
    pool_totals = zeros(Float64, length(carbon_columns))
    nonfinite_count = 0
    for line in lines[2:end]
        values = split(line, ','; keepempty = true)
        area = parse(Float64, strip(values[area_column]))
        for (index, column) in enumerate(carbon_columns)
            value = parse(Float64, strip(values[column]))
            nonfinite_count += !isfinite(value)
            pool_totals[index] += value * area * 1.0e-9
        end
    end
    return Dict(
        "path" => abspath(path),
        "sha256" => sha256sum(path),
        "points" => length(lines) - 1,
        "nonfinite_count" => nonfinite_count,
        "total_carbon_pg" => sum(pool_totals),
        "pool_carbon_pg" => Dict(
            header[column] => total for
            (column, total) in zip(carbon_columns, pool_totals)
        ),
    )
end

function passive_restoration_report(source, destination)
    source_lines = readlines(source)
    destination_lines = readlines(destination)
    length(source_lines) == length(destination_lines) ||
        error("Passive restoration changed the restart row count")
    isempty(source_lines) && error("Passive restoration source is empty")
    source_header = split(first(source_lines), ','; keepempty = true)
    destination_header = split(first(destination_lines), ','; keepempty = true)
    source_header == destination_header ||
        error("Passive restoration changed the restart header")
    passive_columns =
        findall(value -> strip(value) == "casapool%csoil(PASS)", source_header)
    length(passive_columns) == 1 ||
        error("Passive restoration requires exactly one passive-carbon column")
    passive_column = only(passive_columns)
    mismatches = 0
    for (source_line, destination_line) in
        zip(source_lines[2:end], destination_lines[2:end])
        source_values = split(source_line, ','; keepempty = true)
        destination_values = split(destination_line, ','; keepempty = true)
        length(source_values) == length(destination_values) ||
            error("Passive restoration changed a restart column count")
        for column in eachindex(source_values, destination_values)
            expected =
                column == passive_column ?
                harness().multiply_decimal_by_ten(source_values[column]) :
                source_values[column]
            mismatches += expected != destination_values[column]
        end
    end
    return Dict(
        "source" => file_record(source),
        "destination" => file_record(destination),
        "points" => length(source_lines) - 1,
        "field" => strip(source_header[passive_column]),
        "multiplier" => load_matrix()["passive_carbon_multiplier"],
        "mismatch_count" => mismatches,
        "verified" => mismatches == 0,
    )
end

function spin_convergence(previous_path, final_path)
    NCDatasets.NCDataset(previous_path) do previous
        NCDatasets.NCDataset(final_path) do final
            previous_soc =
                previous["csoilmic"][:, :, end] .+
                previous["csoilslow"][:, :, end] .+
                previous["csoilpass"][:, :, end]
            final_soc =
                final["csoilmic"][:, :, end] .+ final["csoilslow"][:, :, end] .+
                final["csoilpass"][:, :, end]
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
                "previous" => abspath(previous_path),
                "previous_sha256" => sha256sum(previous_path),
                "final" => abspath(final_path),
                "final_sha256" => sha256sum(final_path),
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

function final_spin_checkpoints()
    matrix = load_matrix()
    cycle_years = length(first(matrix["spin_years"]):last(matrix["spin_years"]))
    final_year = matrix["spin_loops"] * cycle_years
    return final_year - cycle_years, final_year
end

function boundary_report(case_root)
    stages = joinpath(case_root, "stages")
    prespin = joinpath(stages, "01-prespin")
    accelerated = joinpath(stages, "02-accelerated_spin")
    normal = joinpath(stages, "03-normal_spin")
    historical = joinpath(stages, "04-historical")
    previous_checkpoint, final_checkpoint = final_spin_checkpoints()
    boundaries = Dict(
        "prespin" =>
            restart_diagnostic(joinpath(prespin, "casa_final.csv")),
        "accelerated_spin" =>
            restart_diagnostic(joinpath(accelerated, "casa_final.csv")),
        "passive_restoration_input" =>
            restart_diagnostic(joinpath(normal, "casa_initial.csv")),
        "normal_spin" =>
            restart_diagnostic(joinpath(normal, "casa_final.csv")),
        "historical" =>
            restart_diagnostic(joinpath(historical, "casa_final.csv")),
    )
    for diagnostic in values(boundaries)
        diagnostic["points"] == 4263 ||
            error("Restart boundary does not contain 4,263 points")
        diagnostic["nonfinite_count"] == 0 ||
            error("Restart boundary contains non-finite carbon")
    end
    return Dict(
        "restart_boundary" => boundaries,
        "passive_restoration" => passive_restoration_report(
            joinpath(accelerated, "casa_final.csv"),
            joinpath(normal, "casa_initial.csv"),
        ),
        "spin_convergence" => Dict(
            "accelerated_spin" => spin_convergence(
                joinpath(accelerated, netcdf_name(previous_checkpoint)),
                joinpath(accelerated, netcdf_name(final_checkpoint)),
            ),
            "normal_spin" => spin_convergence(
                joinpath(normal, netcdf_name(previous_checkpoint)),
                joinpath(normal, netcdf_name(final_checkpoint)),
            ),
        ),
    )
end

function verified_artifact_record(path, artifact)
    isfile(path) || error("Missing CASA-C archive: $path")
    filesize(path) == artifact["bytes"] ||
        error("CASA-C archive size does not match the manifest: $path")
    digest = harness().md5sum(path)
    digest == artifact["md5"] ||
        error("CASA-C archive MD5 does not match the manifest: $path")
    return Dict(
        "path" => abspath(path),
        "filename" => artifact["filename"],
        "bytes" => artifact["bytes"],
        "md5" => digest,
        "url" => artifact["url"],
        "source" => artifact["source"],
    )
end

function archive_record(data_root)
    artifacts = filter(
        artifact -> artifact["id"] == "casa_c_output",
        harness().load_manifest()["artifact"],
    )
    length(artifacts) == 1 || error("CASA-C archive manifest is ambiguous")
    artifact = only(artifacts)
    return verified_artifact_record(
        joinpath(data_root, artifact["filename"]),
        artifact,
    )
end

function reference_cache_valid(destination, metadata_path, archive, member)
    isfile(destination) && isfile(metadata_path) || return false
    metadata = try
        TOML.parsefile(metadata_path)
    catch
        return false
    end
    get(metadata, "archive_md5", "") == archive["md5"] || return false
    get(metadata, "archive_member", "") == member || return false
    get(metadata, "bytes", -1) == filesize(destination) || return false
    get(metadata, "md5", "") == harness().md5sum(destination) || return false
    return true
end

function extract_archive_reference(
    data_root,
    case_root,
    filename;
    archive = archive_record(data_root),
)
    reference_root = joinpath(case_root, "reference")
    destination = joinpath(reference_root, filename)
    member = joinpath("CASACNP_mod5_GSWP3_Conly", "OUTPUT_C", "HIST", filename)
    metadata_path = destination * ".provenance.toml"
    reference_cache_valid(destination, metadata_path, archive, member) &&
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

function comparison_record(report)
    return Dict(
        "ok" => report.ok,
        "metadata_mismatches" => report.metadata_mismatches,
        "failed_variables" => report.failed_variables,
        "variable" => Dict(
            name => Dict(
                "failure_count" => result.failure_count,
                "missing_mismatch_count" => result.missing_mismatch_count,
                "nonfinite_count" => result.nonfinite_count,
                "sign_change_count" => result.sign_change_count,
                "max_abs_error" => result.max_abs_error,
                "max_rel_error" => result.max_rel_error,
                "first_failure" =>
                    isnothing(result.first_failure) ? Int[] :
                    collect(result.first_failure),
            ) for (name, result) in report.results
        ),
    )
end

function daily_comparison(
    data_root,
    case_root;
    archive = archive_record(data_root),
)
    historical = joinpath(case_root, "stages", "04-historical")
    references = Dict{UnitRange{Int}, String}()
    for window in load_matrix()["postprocessing"]["daily_windows"]
        years = first(window):last(window)
        references[years] = extract_archive_reference(
            data_root,
            case_root,
            "casaclm_pool_flux_$(first(years))_$(last(years))_daily.nc",
            ;
            archive,
        )
    end
    comparisons = Dict{String, Any}()
    for (years, reference) in references, year in years
        first_day = (year - first(years)) * 365 + 1
        report = comparator().compare_netcdf(
            reference,
            joinpath(historical, netcdf_name(year; daily = true));
            reference_selectors = Dict("time" => first_day:(first_day + 364)),
        )
        comparisons[string(year)] = comparison_record(report)
    end
    return Dict(
        "exact_atol" => 0.0,
        "exact_rtol" => 0.0,
        "all_match" => all(record["ok"] for record in values(comparisons)),
        "year" => comparisons,
    )
end

function annual_mean(variable, time_dimension)
    indices = ntuple(_ -> Colon(), ndims(variable))
    raw = variable.var[indices...]
    fill_value =
        haskey(variable.attrib, "_FillValue") ? variable.attrib["_FillValue"] :
        nothing
    valid = isnothing(fill_value) ? trues(size(raw)) : raw .!= fill_value
    valid_count =
        dropdims(sum(valid; dims = time_dimension); dims = time_dimension)
    averaged =
        dropdims(
            sum(ifelse.(valid, Float64.(raw), 0.0); dims = time_dimension);
            dims = time_dimension,
        ) ./ max.(valid_count, 1)
    output = if eltype(raw) <: Integer
        round.(eltype(raw), averaged)
    else
        eltype(raw).(averaged)
    end
    isnothing(fill_value) || (output[iszero.(valid_count)] .= fill_value)
    return output
end

function accumulate_result!(record, result, year)
    record["failure_count"] += result.failure_count
    record["missing_mismatch_count"] += result.missing_mismatch_count
    record["nonfinite_count"] += result.nonfinite_count
    record["sign_change_count"] += result.sign_change_count
    record["max_abs_error"] = max(record["max_abs_error"], result.max_abs_error)
    record["max_rel_error"] = max(record["max_rel_error"], result.max_rel_error)
    if isempty(record["first_failure"]) && !isnothing(result.first_failure)
        record["first_failure"] = [year; collect(result.first_failure)]
    end
    return record
end

function stock_statistics(
    reference_values,
    candidate_values,
    annual_global_sums,
    settings,
)
    length(reference_values) == length(candidate_values) ||
        error("Stock comparison lengths differ")
    nonzero_reference = .!iszero.(reference_values)
    absolute_relative_errors =
        abs.(
            (
                candidate_values[nonzero_reference] .-
                reference_values[nonzero_reference]
            ) ./ reference_values[nonzero_reference],
        )
    isempty(absolute_relative_errors) &&
        error("Stock comparison has no nonzero reference values")
    quantile = settings["grid_absolute_relative_quantile"]
    grid_statistic = Statistics.quantile(absolute_relative_errors, quantile)
    grid_rtol = settings["grid_absolute_relative_rtol"]
    global_rtol = settings["global_sum_rtol"]
    global_relative_errors = map(
        record -> record["absolute_relative_error"],
        values(annual_global_sums),
    )
    global_passes =
        all(record["passes"] for record in values(annual_global_sums))
    zero_reference = .!nonzero_reference
    return Dict(
        "all_pass" => global_passes && grid_statistic <= grid_rtol,
        "global_sum" => Dict(
            "rtol" => global_rtol,
            "passes" => global_passes,
            "maximum_absolute_relative_error" =>
                maximum(global_relative_errors),
            "year" => annual_global_sums,
        ),
        "grid_cell_year" => Dict(
            "quantile" => quantile,
            "absolute_relative_error" => grid_statistic,
            "rtol" => grid_rtol,
            "passes" => grid_statistic <= grid_rtol,
            "count" => length(reference_values),
            "defined_relative_error_count" =>
                length(absolute_relative_errors),
            "exact_defined_count" =>
                count(iszero, absolute_relative_errors),
            "zero_reference_count" => count(zero_reference),
            "zero_reference_candidate_nonzero_count" => count(
                value -> !iszero(value),
                candidate_values[zero_reference],
            ),
        ),
    )
end

function annual_comparison(
    data_root,
    case_root;
    archive = archive_record(data_root),
)
    matrix = load_matrix()
    reference_path = extract_archive_reference(
        data_root,
        case_root,
        matrix["postprocessing"]["annual_reference"],
        ;
        archive,
    )
    historical = joinpath(case_root, "stages", "04-historical")
    history_years = matrix["stages"]["historical"]["years"]
    statistical_settings = matrix["statistical_comparison"]
    stock_variables = Set(String.(statistical_settings["stock_variables"]))
    reference_stock_values = Float64[]
    candidate_stock_values = Float64[]
    annual_global_sums = Dict{String, Any}()
    records = Dict{String, Any}()
    metadata_mismatches = String[]
    NCDatasets.NCDataset(reference_path) do reference
        reference_names = Set(String.(keys(reference)))
        issubset(stock_variables, reference_names) ||
            error("Archive is missing configured carbon-stock variables")
        land_mask = reference["cellMissing"].var[:, :] .== 0
        land_area = Float64.(reference["landarea"].var[:, :])[land_mask]
        for year in first(history_years):last(history_years)
            candidate_path =
                joinpath(historical, netcdf_name(year; daily = true))
            NCDatasets.NCDataset(candidate_path) do candidate
                candidate_names = Set(String.(keys(candidate)))
                if reference_names != candidate_names
                    push!(metadata_mismatches, "variable names differ in $year")
                end
                issubset(stock_variables, candidate_names) || error(
                    "Candidate is missing configured carbon-stock variables in $year",
                )
                reference_stock_total = zeros(Float64, size(land_mask))
                candidate_stock_total = zeros(Float64, size(land_mask))
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
                    isnothing(time_dimension) && year != 1901 && continue
                    candidate_values = if isnothing(time_dimension)
                        indices =
                            ntuple(_ -> Colon(), ndims(candidate_variable))
                        candidate_variable.var[indices...]
                    else
                        annual_mean(candidate_variable, time_dimension)
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
                    if name in stock_variables
                        reference_stock_total .+= Float64.(reference_values)
                        candidate_stock_total .+= Float64.(candidate_values)
                    end
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
                    accumulate_result!(record, result, year)
                end
                reference_active = reference_stock_total[land_mask]
                candidate_active = candidate_stock_total[land_mask]
                append!(reference_stock_values, reference_active)
                append!(candidate_stock_values, candidate_active)
                reference_global_pg =
                    sum(reference_active .* land_area) * 1.0e-9
                candidate_global_pg =
                    sum(candidate_active .* land_area) * 1.0e-9
                annual_global_sums[string(year)] = Dict(
                    "reference_pg_c" => reference_global_pg,
                    "candidate_pg_c" => candidate_global_pg,
                    "absolute_relative_error" =>
                        abs(candidate_global_pg - reference_global_pg) /
                        abs(reference_global_pg),
                    "passes" => isapprox(
                        candidate_global_pg,
                        reference_global_pg;
                        rtol = statistical_settings["global_sum_rtol"],
                        atol = 0.0,
                    ),
                )
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
        "stock_statistics" => stock_statistics(
            reference_stock_values,
            candidate_stock_values,
            annual_global_sums,
            statistical_settings,
        ),
    )
end

function write_case_report(data_root, case_root)
    boundaries = boundary_report(case_root)
    archive = archive_record(data_root)
    annual = annual_comparison(data_root, case_root; archive)
    daily = daily_comparison(data_root, case_root; archive)
    convergence_passes = all(
        record["passes_documented_checks"] for
        record in values(boundaries["spin_convergence"])
    )
    restoration_verified = boundaries["passive_restoration"]["verified"]
    matches =
        annual["all_match"] &&
        daily["all_match"] &&
        convergence_passes &&
        restoration_verified
    configuration = joinpath(case_root, "configuration")
    build_metadata = joinpath(case_root, "build", "build_metadata.toml")
    matrix = load_matrix()
    reference_filenames = vcat(
        [matrix["postprocessing"]["annual_reference"]],
        [
            "casaclm_pool_flux_$(first(window))_$(last(window))_daily.nc"
            for window in matrix["postprocessing"]["daily_windows"]
        ],
    )
    report = Dict(
        "schema_version" => 1,
        "case" => basename(case_root),
        "status" => matches ? "matching_setup_pinned" : "mismatch",
        "statistical_reproduction_passes" =>
            annual["stock_statistics"]["all_pass"],
        "documented_convergence_checks_pass" => convergence_passes,
        "passive_restoration_verified" => restoration_verified,
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
                name => file_record(
                    joinpath(
                        case_root,
                        "stages",
                        directory,
                        "stage_metadata.toml",
                    ),
                ) for (name, directory) in (
                    "prespin" => "01-prespin",
                    "accelerated_spin" => "02-accelerated_spin",
                    "normal_spin" => "03-normal_spin",
                    "historical" => "04-historical",
                )
            ),
        ),
        "boundaries" => boundaries,
        "annual_comparison" => annual,
        "daily_comparison" => daily,
    )
    path = joinpath(case_root, "reconstruction_report.toml")
    harness().write_toml_atomic(path, report)
    println("CASA-C reconstruction report: $path")
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
    count = comparison_mismatch_count(report["annual_comparison"])
    for year in values(report["daily_comparison"]["year"])
        count += comparison_mismatch_count(year)
    end
    get(report, "documented_convergence_checks_pass", false) || (count += 1)
    get(report, "passive_restoration_verified", false) || (count += 1)
    return count
end

function search_outcome(attempts, matched_case, tested_compilers)
    isempty(matched_case) ||
        return (status = "matching_setup_pinned", blocker = "")
    blocked = filter(attempt -> attempt["status"] == "blocked", attempts)
    if !isempty(blocked)
        return (
            status = "blocked",
            blocker = join(
                [
                    "$(attempt["case"]): $(attempt["blocker"])" for
                    attempt in blocked
                ],
                "; ",
            ),
        )
    end
    return (
        status = "evidence_backed_matrix_exhausted",
        blocker = "No evidence-backed source case exactly reconstructs the archive. " *
                  "The archive compiler is not recorded; tested compiler(s): " *
                  (
                      isempty(tested_compilers) ? "none" :
                      join(tested_compilers, "; ")
                  ),
    )
end

function run_search(source_root, data_root, run_root)
    attempts = Dict{String, Any}[]
    best_case = ""
    best_mismatch_count = typemax(Int)
    matched_case = ""
    for case in load_matrix()["case"]
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
    outcome = search_outcome(attempts, matched_case, tested_compilers)
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
    println("CASA-C reconstruction search report: $path")
    return path
end

function self_test()
    matrix = load_matrix()
    Test.@testset "CASA-C reconstruction" begin
        Test.@test matrix["points"] == 4263
        Test.@test matrix["prespin_loops"] == 100
        Test.@test matrix["spin_loops"] == 499
        Test.@test matrix["history_years"] == [1901, 2014]
        Test.@test final_spin_checkpoints() == (9960, 9980)
        Test.@test length(matrix["case"]) == 1
        Test.@test haskey(matrix["excluded"], "pinned_current")
        Test.@test Set(keys(candidate_control_paths())) == Set(CONTROL_IDS)
        statistical_settings = matrix["statistical_comparison"]
        Test.@test statistical_settings["global_sum_rtol"] == 2.0e-6
        Test.@test statistical_settings["grid_absolute_relative_quantile"] ==
                   0.99
        Test.@test statistical_settings["grid_absolute_relative_rtol"] == 1.0e-3
        synthetic_reference = [100.0, 100.0, 0.0]
        synthetic_candidate = [100.05, 99.95, 1.0]
        synthetic_global = Dict(
            "1901" =>
                Dict("absolute_relative_error" => 1.0e-3, "passes" => true),
        )
        synthetic_settings = Dict(
            "global_sum_rtol" => 2.0e-3,
            "grid_absolute_relative_quantile" => 0.99,
            "grid_absolute_relative_rtol" => 1.0e-3,
        )
        synthetic_statistics = stock_statistics(
            synthetic_reference,
            synthetic_candidate,
            synthetic_global,
            synthetic_settings,
        )
        Test.@test synthetic_statistics["all_pass"]
        Test.@test synthetic_statistics["grid_cell_year"]["absolute_relative_error"] ≈
                   5.0e-4
        Test.@test synthetic_statistics["grid_cell_year"]["zero_reference_candidate_nonzero_count"] ==
                   1
        strict_settings = copy(synthetic_settings)
        strict_settings["grid_absolute_relative_rtol"] = 1.0e-4
        Test.@test !stock_statistics(
            synthetic_reference,
            synthetic_candidate,
            synthetic_global,
            strict_settings,
        )["all_pass"]
        mktempdir() do root
            source = joinpath(root, "source.lst")
            harness().write_smoke_control(
                root;
                points = 4263,
                loops = 499,
                initialization = 3,
                years = (1901, 1920),
                cycle = 1,
            )
            mv(joinpath(root, "fcasacnp_clm_testbed.lst"), source)
            staged = joinpath(root, "staged.lst")
            report = write_staged_control(
                source,
                staged,
                Dict(
                    :casa_netcdf => "casaclm_pool_flux_yyyy.nc",
                    :netcdf_interval => 10,
                ),
            )
            control = harness().parse_control(staged)
            Test.@test control[:points] == 4263
            Test.@test control[:cycle] == 1
            Test.@test first(annual_output_years(control)) == 1
            Test.@test last(annual_output_years(control)) == 9980
            Test.@test length(annual_output_years(control)) == 999
            Test.@test report["staged_sha256"] == sha256sum(staged)
            Test.@test !isempty(complete_control_diff(source, staged))
            stage = stage_definition("spin", staged, Dict{String, Any}[])
            Test.@test length(stage["outputs"]) == 1001
            Test.@test !("casaclm_pool_flux_yyyy.nc" in stage["outputs"])

            restart = joinpath(root, "restart.csv")
            write(
                restart,
                "casamet%areacell,casapool%cplant(LEAF)," *
                "casapool%csoil(PASS)\n" *
                "1000000,2,3\n2000000,4,5\n",
            )
            diagnostic = restart_diagnostic(restart)
            Test.@test diagnostic["points"] == 2
            Test.@test diagnostic["nonfinite_count"] == 0
            Test.@test diagnostic["total_carbon_pg"] ≈ 2.3e-2
            restored = joinpath(root, "restored.csv")
            harness().restore_casa_passive_carbon(restart, restored)
            restoration = passive_restoration_report(restart, restored)
            Test.@test restoration["verified"]
            Test.@test restoration["mismatch_count"] == 0

            recovery_root = joinpath(root, "recovery")
            mkpath(recovery_root)
            output = joinpath(recovery_root, "expected.nc")
            write(output, "complete output")
            recovery_metadata = joinpath(recovery_root, "stage_metadata.toml")
            execution_fingerprint = "matching-execution"
            harness().write_toml_atomic(
                recovery_metadata,
                Dict(
                    "status" => "failed",
                    "error" => "Stage 'spin' did not create: obsolete.nc",
                    "execution_fingerprint" => execution_fingerprint,
                    "outputs" => Dict(
                        "expected.nc" => Dict(
                            "bytes" => filesize(output),
                            "md5" => harness().md5sum(output),
                        ),
                    ),
                ),
            )
            Test.@test !isnothing(
                harness().recoverable_output_contract_stage(
                    recovery_metadata,
                    "spin",
                    recovery_root,
                    ["expected.nc"],
                    execution_fingerprint,
                ),
            )
            Test.@test isnothing(
                harness().recoverable_output_contract_stage(
                    recovery_metadata,
                    "spin",
                    recovery_root,
                    ["expected.nc"],
                    "different-execution",
                ),
            )

            artifact = joinpath(root, "archive.tar.gz")
            write(artifact, "test archive")
            artifact_manifest = Dict(
                "filename" => basename(artifact),
                "bytes" => filesize(artifact),
                "md5" => harness().md5sum(artifact),
                "url" => "https://example.invalid/archive",
                "source" => "test",
            )
            Test.@test verified_artifact_record(artifact, artifact_manifest)["md5"] ==
                       artifact_manifest["md5"]
            write(artifact, "corrupt")
            Test.@test_throws ErrorException verified_artifact_record(
                artifact,
                artifact_manifest,
            )

            blocked = search_outcome(
                [
                    Dict(
                        "case" => "candidate",
                        "status" => "blocked",
                        "blocker" => "missing input",
                    ),
                ],
                "",
                String[],
            )
            Test.@test blocked.status == "blocked"
            exhausted = search_outcome(
                [Dict("case" => "candidate", "status" => "mismatch")],
                "",
                ["compiler"],
            )
            Test.@test exhausted.status == "evidence_backed_matrix_exhausted"
        end
    end
    return true
end

function usage(io = stdout)
    println(
        io,
        "Usage: julia casa_c_reconstruction.jl run-case " *
        "<source-repo> <data-root> <run-root> <case-id>",
    )
    println(
        io,
        "       julia casa_c_reconstruction.jl report-case " *
        "<data-root> <run-root> <case-id>",
    )
    println(
        io,
        "       julia casa_c_reconstruction.jl search " *
        "<source-repo> <data-root> <run-root>",
    )
    println(io, "       julia casa_c_reconstruction.jl self-test")
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
