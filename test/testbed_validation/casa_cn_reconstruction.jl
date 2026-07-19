if !isdefined(@__MODULE__, :TestbedCASACReconstruction)
    include(joinpath(@__DIR__, "casa_c_reconstruction.jl"))
end

module TestbedCASACNReconstruction

import TOML
import Test

import NCDatasets

const MATRIX_PATH = joinpath(@__DIR__, "casa_cn_reconstruction.toml")
const CANDIDATE_SPEC_PATH = joinpath(@__DIR__, "candidate_reconstruction.toml")
const STAGE_SPECS = (
    (name = "prespin", directory = "01-prespin"),
    (name = "accelerated_spin", directory = "02-accelerated_spin"),
    (name = "normal_spin", directory = "03-normal_spin"),
    (name = "historical", directory = "04-historical"),
)
const CANDIDATE_IDS = ("casa_boreal_nfix", "mimics_ko6_fi30", "casa_cn_prespin")
const SCIENTIFIC_GROUPS = (
    "plant_states",
    "organic_pools",
    "mineral_nitrogen",
    "major_fluxes",
    "cwd_nitrogen",
)

casa() = getfield(parentmodule(@__MODULE__), :TestbedCASACReconstruction)
harness() = casa().harness()
candidates() = casa().candidates()
comparator() = casa().comparator()
sha256sum(path) = casa().sha256sum(path)
file_record(path) = casa().file_record(path)
netcdf_name(year; daily = false) = casa().netcdf_name(year; daily)

function load_matrix(path = MATRIX_PATH)
    matrix = TOML.parsefile(path)
    get(matrix, "schema_version", 0) == 1 ||
        error("Unsupported CASA-CN reconstruction matrix schema")
    matrix["issue"] == 24 || error("CASA-CN matrix must identify issue 24")
    matrix["points"] == 4263 || error("CASA-CN matrix must retain 4,263 points")
    matrix["passive_carbon_multiplier"] == 10 ||
        error("CASA-CN matrix must retain passive-pool ×10 restoration")
    matrix["comparison_atol"] == 0.0 ||
        error("CASA-CN comparison must be exact")
    matrix["comparison_rtol"] == 0.0 ||
        error("CASA-CN comparison must be exact")
    matrix["stages"]["prespin"]["loops"] == matrix["prespin_loops"] ||
        error("CASA-CN prespin matrix is inconsistent")
    for stage in ("accelerated_spin", "normal_spin")
        matrix["stages"][stage]["loops"] == matrix["spin_loops"] ||
            error("CASA-CN $stage matrix is inconsistent")
        matrix["stages"][stage]["years"] == matrix["spin_years"] ||
            error("CASA-CN $stage years are inconsistent")
    end
    matrix["stages"]["historical"]["years"] == matrix["history_years"] ||
        error("CASA-CN history matrix is inconsistent")
    transformation = matrix["transformation"]["passive_restoration"]
    transformation["carbon_multiplier"] ==
    matrix["passive_carbon_multiplier"] ||
        error("CASA-CN passive restoration matrix is inconsistent")
    transformation["nitrogen_multiplier"] ==
    matrix["passive_carbon_multiplier"] ||
        error("CASA-CN passive carbon and nitrogen restoration must match")
    comparison = matrix["scientific_comparison"]
    required_groups = Set(SCIENTIFIC_GROUPS)
    issubset(required_groups, Set(keys(comparison))) ||
        error("CASA-CN scientific comparison groups are incomplete")
    all(!isempty(comparison[group]) for group in required_groups) ||
        error("CASA-CN scientific comparison groups cannot be empty")
    blocked = matrix["compiler"]["blocked_candidate"]
    length(blocked) == 1 ||
        error("CASA-CN matrix must record the unavailable source compiler")
    only(blocked)["status"] == "blocked_unavailable_toolchain" ||
        error("CASA-CN source compiler must be explicitly blocked")
    return matrix
end

function case_spec(matrix, id)
    matching = filter(case -> case["id"] == id, matrix["case"])
    length(matching) == 1 || error("Unknown or duplicate CASA-CN case: $id")
    return only(matching)
end

function candidate_paths(spec_path = CANDIDATE_SPEC_PATH)
    selected = Dict{String, String}()
    for candidate in TOML.parsefile(spec_path)["candidate"]
        candidate["id"] in CANDIDATE_IDS || continue
        selected[candidate["id"]] = candidate["destination"]
    end
    Set(keys(selected)) == Set(CANDIDATE_IDS) ||
        error("Candidate specification is missing a CASA-CN input")
    return selected
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
        error("Staged CASA-CN control does not use 4,263 points")
    control[:soil_model] == 1 || error("Staged control is not CASA")
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
    inputs = load_matrix()["inputs"]
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

function retained_daily_years(matrix = load_matrix())
    return Set(
        vcat(
            (
                collect(first(window):last(window)) for
                window in matrix["postprocessing"]["daily_windows"]
            )...,
        ),
    )
end

annual_fragment(year) = joinpath("annual_comparison", "$year.toml")

function historical_stage_outputs(matrix = load_matrix())
    years = first(matrix["history_years"]):last(matrix["history_years"])
    retained = retained_daily_years(matrix)
    return vcat(
        ["casa_final.csv", "casa_flux_final.csv"],
        annual_fragment.(years),
        [netcdf_name(year; daily = true) for year in years if year in retained],
    )
end

function stage_definition(name, control_path, inputs)
    name == "historical" ||
        return casa().stage_definition(name, control_path, inputs)
    matrix = load_matrix()
    return Dict(
        "name" => name,
        "control" => relpath(control_path, dirname(dirname(control_path))),
        "outputs" => historical_stage_outputs(matrix),
        "input" => inputs,
        "retention" => Dict(
            "annual_fragments" => true,
            "annual_reduction" => "mean of non-fill daily values",
            "daily_years" => sort!(collect(retained_daily_years(matrix))),
        ),
    )
end

function stage_control_source(
    matrix,
    source_root,
    candidate_root,
    candidate_path_map,
    stage,
)
    if stage == "prespin"
        return joinpath(candidate_root, candidate_path_map["casa_cn_prespin"])
    end
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
    candidate_path_map = candidate_paths()
    configuration = joinpath(run_root, "configuration")
    controls_root = joinpath(configuration, "controls")
    mkpath(controls_root)
    inputs = matrix["inputs"]
    normal_parameters = joinpath(source_root, inputs["normal_parameters"])
    accelerated_parameters =
        joinpath(source_root, inputs["accelerated_parameters"])
    sha256sum(normal_parameters) == inputs["normal_parameters_sha256"] ||
        error("CASA-CN normal parameter hash differs from the matrix")
    sha256sum(accelerated_parameters) ==
    inputs["accelerated_parameters_sha256"] ||
        error("CASA-CN accelerated parameter hash differs from the matrix")
    prespin_parameters = joinpath(
        candidate_root,
        candidate_path_map[inputs["prespin_casa_candidate"]],
    )
    mimics_parameters = joinpath(
        candidate_root,
        candidate_path_map[inputs["prespin_mimics_candidate"]],
    )
    parameter_by_stage = Dict(
        "prespin" => prespin_parameters,
        "accelerated_spin" => accelerated_parameters,
        "normal_spin" => normal_parameters,
        "historical" => normal_parameters,
    )
    common_overrides = Dict(
        :points => 4263,
        :soil_model => 1,
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
            candidate_path_map,
            stage,
        )
        destination = joinpath(controls_root, "$stage.lst")
        overrides = copy(common_overrides)
        stage == "normal_spin" && (
            overrides[:netcdf_interval] =
                matrix["postprocessing"]["spin_checkpoint_interval"]
        )
        report = write_staged_control(source, destination, overrides)
        report["stage"] = stage
        push!(control_reports, report)
        control = harness().parse_control(destination)
        control[:loops] == matrix["stages"][stage]["loops"] ||
            error("CASA-CN $stage loop count differs from the matrix")
        [first(control[:years]), last(control[:years])] ==
        matrix["stages"][stage]["years"] ||
            error("CASA-CN $stage years differ from the matrix")
        controls[stage] = destination
    end
    stage_inputs = Dict{String, Any}()
    for stage_spec in STAGE_SPECS
        stage = stage_spec.name
        years = matrix["stages"][stage]["years"]
        stage_inputs[stage] = common_inputs(
            source_root,
            data_root,
            first(years):last(years),
            parameter_by_stage[stage],
            mimics_parameters,
        )
    end
    push!(
        stage_inputs["accelerated_spin"],
        harness().workflow_input(
            "stage:prespin/casa_final.csv",
            "casa_initial.csv",
        ),
    )
    push!(
        stage_inputs["normal_spin"],
        harness().workflow_input(
            "stage:accelerated_spin/casa_final.csv",
            "casa_initial.csv";
            transform = "casa_passive_carbon_nitrogen_x10",
        ),
    )
    push!(
        stage_inputs["historical"],
        harness().workflow_input(
            "stage:normal_spin/casa_final.csv",
            "casa_initial.csv",
        ),
    )
    push!(
        stage_inputs["historical"],
        harness().workflow_input(MATRIX_PATH, "casa_cn_reconstruction.toml"),
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
        "name" => "casa-cn-archive-reconstruction-$case_id",
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
                id => file_record(
                    joinpath(candidate_root, candidate_path_map[id]),
                ) for id in CANDIDATE_IDS
            ),
            "stage_parameter" => Dict(
                stage => file_record(path) for
                (stage, path) in parameter_by_stage
            ),
            "mimics_parameter" => file_record(mimics_parameters),
            "staged_control" => control_reports,
        ),
    )
    return workflow_path
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
    annual_reference = extract_archive_reference(
        data_root,
        case_root,
        matrix["postprocessing"]["annual_reference"];
        archive,
    )
    results = harness().run_stage_workflow(
        executable,
        workflow,
        case_root;
        stage_hook = historical_retention_hook(annual_reference, matrix),
    )
    write_case_report(data_root, case_root)
    return results
end

function restart_diagnostic(path)
    lines = readlines(path)
    isempty(lines) && error("Empty CASA-CN restart: $path")
    header = strip.(split(first(lines), ','))
    area_column = findfirst(==("casamet%areacell"), header)
    isnothing(area_column) && error("Restart has no casamet%areacell")
    columns = Dict(
        "carbon" => findall(
            name -> startswith(lowercase(name), "casapool%c"),
            header,
        ),
        "nitrogen" => findall(
            name -> startswith(lowercase(name), "casapool%n"),
            header,
        ),
    )
    all(!isempty(value) for value in values(columns)) ||
        error("CASA-CN restart must contain carbon and nitrogen pools")
    totals =
        Dict(name => zeros(Float64, length(value)) for (name, value) in columns)
    nonfinite = Dict(name => 0 for name in keys(columns))
    for line in lines[2:end]
        values = split(line, ','; keepempty = true)
        area = parse(Float64, strip(values[area_column]))
        for (element, element_columns) in columns
            for (index, column) in enumerate(element_columns)
                value = parse(Float64, strip(values[column]))
                nonfinite[element] += !isfinite(value)
                totals[element][index] += value * area * 1.0e-9
            end
        end
    end
    return Dict(
        "path" => abspath(path),
        "sha256" => sha256sum(path),
        "points" => length(lines) - 1,
        "nonfinite_count" => nonfinite,
        "total_pg" =>
            Dict(element => sum(value) for (element, value) in totals),
        "pool_pg" => Dict(
            element => Dict(
                header[column] => total for (column, total) in
                zip(columns[element], totals[element])
            ) for element in keys(columns)
        ),
    )
end

function passive_restoration_report(source, destination)
    source_lines = readlines(source)
    destination_lines = readlines(destination)
    length(source_lines) == length(destination_lines) ||
        error("Passive restoration changed the restart row count")
    source_header = strip.(split(first(source_lines), ','; keepempty = true))
    destination_header =
        strip.(split(first(destination_lines), ','; keepempty = true))
    source_header == destination_header ||
        error("Passive restoration changed the restart header")
    matrix = load_matrix()
    rule = matrix["transformation"]["passive_restoration"]
    carbon_column = findall(==(rule["carbon_field"]), source_header)
    nitrogen_column = findall(==(rule["nitrogen_field"]), source_header)
    length(carbon_column) == 1 ||
        error("Passive restoration requires one passive-carbon column")
    length(nitrogen_column) == 1 ||
        error("Passive restoration requires one passive-nitrogen column")
    passive_carbon = only(carbon_column)
    passive_nitrogen = only(nitrogen_column)
    carbon_mismatches = 0
    nitrogen_mismatches = 0
    unaffected_mismatches = 0
    for (before_line, after_line) in
        zip(source_lines[2:end], destination_lines[2:end])
        before = split(before_line, ','; keepempty = true)
        after = split(after_line, ','; keepempty = true)
        length(before) == length(after) ||
            error("Passive restoration changed a restart column count")
        for column in eachindex(before, after)
            if column == passive_carbon
                expected = harness().multiply_decimal_by_ten(before[column])
                carbon_mismatches += expected != after[column]
            elseif column == passive_nitrogen
                expected = harness().multiply_decimal_by_ten(before[column])
                nitrogen_mismatches += expected != after[column]
            else
                unaffected_mismatches += before[column] != after[column]
            end
        end
    end
    verified =
        carbon_mismatches == 0 &&
        nitrogen_mismatches == 0 &&
        unaffected_mismatches == 0
    return Dict(
        "source" => file_record(source),
        "destination" => file_record(destination),
        "points" => length(source_lines) - 1,
        "passive_carbon" => Dict(
            "field" => rule["carbon_field"],
            "multiplier" => rule["carbon_multiplier"],
            "mismatch_count" => carbon_mismatches,
        ),
        "passive_nitrogen" => Dict(
            "field" => rule["nitrogen_field"],
            "multiplier" => rule["nitrogen_multiplier"],
            "mismatch_count" => nitrogen_mismatches,
        ),
        "unaffected_columns" => Dict(
            "rule" => rule["unaffected_columns_rule"],
            "mismatch_count" => unaffected_mismatches,
        ),
        "verified" => verified,
    )
end

function pool_change(previous, final, pool_names)
    before_total = sum(previous[name][:, :, end] for name in pool_names)
    after_total = sum(final[name][:, :, end] for name in pool_names)
    landarea = final["landarea"][:, :]
    active = final["cellMissing"][:, :] .== 0
    global_delta = 0.0
    below_one = 0
    below_fraction = 0
    points = 0
    for index in eachindex(before_total, after_total, landarea, active)
        active[index] || continue
        values = (before_total[index], after_total[index], landarea[index])
        any(ismissing, values) && continue
        before, after, area = Float64.(values)
        difference = abs(after - before)
        global_delta += (after - before) * area * 1.0e-9
        below_one += difference < 1.0
        below_fraction +=
            difference == 0 || (before != 0 && difference / abs(before) < 0.001)
        points += 1
    end
    return Dict(
        "pool_variables" => collect(pool_names),
        "active_points" => points,
        "absolute_global_delta_pg" => abs(global_delta),
        "fraction_below_1_g_m2" => below_one / points,
        "fraction_below_0_1_percent" => below_fraction / points,
    )
end

function spin_convergence(previous_path, final_path)
    NCDatasets.NCDataset(previous_path) do previous
        NCDatasets.NCDataset(final_path) do final
            carbon = pool_change(
                previous,
                final,
                ("csoilmic", "csoilslow", "csoilpass"),
            )
            nitrogen = pool_change(
                previous,
                final,
                ("nsoilmic", "nsoilslow", "nsoilpass", "nMineral"),
            )
            carbon["passes_documented_checks"] =
                carbon["absolute_global_delta_pg"] < 0.01 &&
                carbon["fraction_below_1_g_m2"] > 0.98 &&
                carbon["fraction_below_0_1_percent"] > 0.98
            return Dict(
                "previous" => file_record(previous_path),
                "final" => file_record(final_path),
                "carbon" => carbon,
                "nitrogen" => nitrogen,
                "passes_documented_checks" =>
                    carbon["passes_documented_checks"],
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
    stages_root = joinpath(case_root, "stages")
    boundaries = Dict{String, Any}()
    for stage in STAGE_SPECS
        diagnostic = restart_diagnostic(
            joinpath(stages_root, stage.directory, "casa_final.csv"),
        )
        diagnostic["points"] == 4263 ||
            error("CASA-CN restart boundary does not contain 4,263 points")
        all(iszero, values(diagnostic["nonfinite_count"])) ||
            error("CASA-CN restart boundary contains non-finite pools")
        boundaries[stage.name] = diagnostic
    end
    previous_checkpoint, final_checkpoint = final_spin_checkpoints()
    convergence = Dict{String, Any}()
    for stage in STAGE_SPECS[2:3]
        root = joinpath(stages_root, stage.directory)
        convergence[stage.name] = spin_convergence(
            joinpath(root, netcdf_name(previous_checkpoint)),
            joinpath(root, netcdf_name(final_checkpoint)),
        )
    end
    accelerated = joinpath(stages_root, STAGE_SPECS[2].directory)
    normal = joinpath(stages_root, STAGE_SPECS[3].directory)
    return Dict(
        "restart_boundary" => boundaries,
        "passive_restoration" => passive_restoration_report(
            joinpath(accelerated, "casa_final.csv"),
            joinpath(normal, "casa_initial.csv"),
        ),
        "spin_convergence" => convergence,
    )
end

function exudation_audit(path)
    rows = [split(line, ','; keepempty = true) for line in readlines(path)]
    header_row = findfirst(row -> "fracRootExudate" in strip.(row), rows)
    isnothing(header_row) &&
        error("CASA parameter table has no exudation field")
    header = strip.(rows[header_row])
    column = findfirst(==("fracRootExudate"), header)
    values = Float64[]
    for row in rows[(header_row + 2):end]
        isempty(strip(first(row))) && continue
        pft = tryparse(Int, strip(first(row)))
        isnothing(pft) && continue
        push!(values, parse(Float64, strip(row[column])))
    end
    length(values) == 18 || error("CASA parameter table must define 18 PFTs")
    return Dict(
        "parameter" => file_record(path),
        "field" => "fracRootExudate",
        "pft_count" => length(values),
        "minimum" => minimum(values),
        "maximum" => maximum(values),
        "all_zero" => all(iszero, values),
    )
end

function archive_record(data_root)
    artifacts = filter(
        artifact -> artifact["id"] == "casa_cn_output",
        harness().load_manifest()["artifact"],
    )
    length(artifacts) == 1 || error("CASA-CN archive manifest is ambiguous")
    artifact = only(artifacts)
    return casa().verified_artifact_record(
        joinpath(data_root, artifact["filename"]),
        artifact,
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
    member = joinpath(
        "CASACNP_mod5_GSWP3_exudate0_cwdN",
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

function required_variables(matrix = load_matrix())
    comparison = matrix["scientific_comparison"]
    return Set(
        vcat((String.(comparison[group]) for group in SCIENTIFIC_GROUPS)...),
    )
end

function comparison_groups(records, matrix = load_matrix())
    output = Dict{String, Any}()
    for group in SCIENTIFIC_GROUPS
        names = String.(matrix["scientific_comparison"][group])
        output[group] = Dict(
            "variables" => names,
            "failure_count" => sum(
                get(get(records, name, Dict()), "failure_count", 0) for
                name in names
            ),
        )
    end
    return output
end

function annual_year_record(reference_path, candidate_path, year)
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
            issubset(required_variables(matrix), reference_names) ||
                error("CASA-CN archive is missing required variables")
            issubset(required_variables(matrix), candidate_names) || error(
                "CASA-CN candidate is missing required variables in $year",
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
                    candidate_variable.var[ntuple(
                        _ -> Colon(),
                        ndims(candidate_variable),
                    )...,]
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
        "variable" => records,
    )
end

function combine_annual_records(year_records)
    records = Dict{String, Any}()
    metadata_mismatches = String[]
    for year_record in year_records
        append!(metadata_mismatches, year_record["metadata_mismatches"])
        for (name, incoming) in year_record["variable"]
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
            for field in (
                "failure_count",
                "missing_mismatch_count",
                "nonfinite_count",
                "sign_change_count",
            )
                record[field] += incoming[field]
            end
            record["max_abs_error"] =
                max(record["max_abs_error"], incoming["max_abs_error"])
            record["max_rel_error"] =
                max(record["max_rel_error"], incoming["max_rel_error"])
            if isempty(record["first_failure"]) &&
               !isempty(incoming["first_failure"])
                record["first_failure"] = incoming["first_failure"]
            end
        end
    end
    return Dict(
        "metadata_mismatches" => unique(metadata_mismatches),
        "variable" => records,
    )
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

function wait_for_completed_year(
    daily_path,
    next_path;
    final_year,
    finished,
    poll_seconds = 1,
)
    if final_year
        while !finished[]
            sleep(poll_seconds)
        end
    else
        while !isfile(next_path) && !finished[]
            sleep(poll_seconds)
        end
        isfile(next_path) || return false
    end
    return daily_file_complete(daily_path)
end

function stream_historical_outputs!(
    stage_dir,
    reference_path,
    finished,
    matrix = load_matrix(),
)
    years =
        collect(first(matrix["history_years"]):last(matrix["history_years"]))
    retained = retained_daily_years(matrix)
    fragments = joinpath(stage_dir, "annual_comparison")
    mkpath(fragments)
    for (index, year) in enumerate(years)
        daily_path = joinpath(stage_dir, netcdf_name(year; daily = true))
        next_path =
            index == length(years) ? "" :
            joinpath(stage_dir, netcdf_name(years[index + 1]; daily = true))
        while !isfile(daily_path) && !finished[]
            sleep(1)
        end
        isfile(daily_path) || return nothing
        wait_for_completed_year(
            daily_path,
            next_path;
            final_year = index == length(years),
            finished,
        ) || return nothing
        record = annual_year_record(reference_path, daily_path, year)
        harness().write_toml_atomic(
            joinpath(stage_dir, annual_fragment(year)),
            record,
        )
        year in retained || rm(daily_path; force = true)
    end
    return nothing
end

function historical_retention_hook(reference_path, matrix = load_matrix())
    state = Dict{String, Any}()
    return function (stage, name, stage_dir, event)
        name == "historical" || return nothing
        if event == :before_run
            for filename in readdir(stage_dir)
                occursin(r"^casaclm_pool_flux_\d{4}_daily\.nc$", filename) ||
                    continue
                rm(joinpath(stage_dir, filename); force = true)
            end
            finished = Ref(false)
            state["finished"] = finished
            state["task"] = @async stream_historical_outputs!(
                stage_dir,
                reference_path,
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

function daily_comparison(
    data_root,
    case_root;
    archive = archive_record(data_root),
)
    historical = joinpath(case_root, "stages", "04-historical")
    comparisons = Dict{String, Any}()
    for window in load_matrix()["postprocessing"]["daily_windows"]
        years = first(window):last(window)
        reference = extract_archive_reference(
            data_root,
            case_root,
            "casaclm_pool_flux_$(first(years))_$(last(years))_daily.nc";
            archive,
        )
        for year in years
            first_day = (year - first(years)) * 365 + 1
            report = comparator().compare_netcdf(
                reference,
                joinpath(historical, netcdf_name(year; daily = true));
                reference_selectors = Dict(
                    "time" => first_day:(first_day + 364),
                ),
            )
            record = casa().comparison_record(report)
            missing =
                setdiff(required_variables(), Set(keys(record["variable"])))
            isempty(missing) || error(
                "Daily CASA-CN comparison is missing: $(join(missing, ", "))",
            )
            record["scientific_group"] = comparison_groups(record["variable"])
            comparisons[string(year)] = record
        end
    end
    return Dict(
        "exact_atol" => 0.0,
        "exact_rtol" => 0.0,
        "all_match" => all(record["ok"] for record in values(comparisons)),
        "year" => comparisons,
    )
end

function annual_comparison(
    data_root,
    case_root;
    archive = archive_record(data_root),
)
    matrix = load_matrix()
    historical = joinpath(case_root, "stages", "04-historical")
    years = first(matrix["history_years"]):last(matrix["history_years"])
    combined = combine_annual_records([
        TOML.parsefile(joinpath(historical, annual_fragment(year))) for
        year in years
    ])
    records = combined["variable"]
    metadata_mismatches = combined["metadata_mismatches"]
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
        "scientific_group" => comparison_groups(records, matrix),
        "variable" => records,
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
    matrix = load_matrix()
    normal_parameters =
        joinpath(case_root, "configuration", "controls", "normal_spin.lst")
    accelerated_parameters =
        joinpath(case_root, "configuration", "controls", "accelerated_spin.lst")
    normal_control = harness().parse_control(normal_parameters)
    accelerated_control = harness().parse_control(accelerated_parameters)
    normal_parameter_path = joinpath(
        case_root,
        "stages",
        "03-normal_spin",
        normal_control[:casa_parameters],
    )
    accelerated_parameter_path = joinpath(
        case_root,
        "stages",
        "02-accelerated_spin",
        accelerated_control[:casa_parameters],
    )
    exudation = Dict(
        "normal" => exudation_audit(normal_parameter_path),
        "accelerated" => exudation_audit(accelerated_parameter_path),
    )
    exudation_verified = all(record["all_zero"] for record in values(exudation))
    matches =
        annual["all_match"] &&
        daily["all_match"] &&
        convergence_passes &&
        restoration_verified &&
        exudation_verified
    configuration = joinpath(case_root, "configuration")
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
        "documented_convergence_checks_pass" => convergence_passes,
        "passive_restoration_verified" => restoration_verified,
        "exudation_zero_verified" => exudation_verified,
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
    println("CASA-CN reconstruction report: $path")
    return path
end

function mismatch_count(report)
    count = casa().comparison_mismatch_count(report["annual_comparison"])
    for year in values(report["daily_comparison"]["year"])
        count += casa().comparison_mismatch_count(year)
    end
    get(report, "documented_convergence_checks_pass", false) || (count += 1)
    get(report, "passive_restoration_verified", false) || (count += 1)
    get(report, "exudation_zero_verified", false) || (count += 1)
    return count
end

function prepare_search_report(run_root)
    path = joinpath(run_root, "search_report.toml")
    isfile(path) && rm(path; force = true)
    return path
end

function run_search(source_root, data_root, run_root)
    search_report = prepare_search_report(run_root)
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
    matching_case = ""
    for case in matrix["case"]
        case_id = case["id"]
        try
            run_case(source_root, data_root, run_root, case_id)
            report_path =
                joinpath(run_root, case_id, "reconstruction_report.toml")
            report = TOML.parsefile(report_path)
            build_metadata =
                joinpath(run_root, case_id, "build", "build_metadata.toml")
            build = TOML.parsefile(build_metadata)
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
                    "build_metadata" => abspath(build_metadata),
                    "build_metadata_sha256" => sha256sum(build_metadata),
                    "compiler_version" => build["build"]["compiler_version"],
                ),
            )
            if mismatches < best_mismatch_count
                best_case = case_id
                best_mismatch_count = mismatches
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
    tested_compilers = unique([
        attempt["compiler_version"] for
        attempt in runnable if haskey(attempt, "compiler_version")
    ])
    blocked = filter(attempt -> attempt["status"] == "blocked", runnable)
    status, blocker = if !isempty(matching_case)
        ("matching_setup_pinned", "")
    elseif !isempty(blocked)
        (
            "blocked",
            join(
                [
                    "$(attempt["case"]): $(attempt["blocker"])" for
                    attempt in blocked
                ],
                "; ",
            ),
        )
    else
        (
            "evidence_backed_matrix_exhausted",
            "No evidence-backed source case exactly reconstructs the archive. " *
            "The archive compiler is not recorded; tested compiler(s): " *
            (
                isempty(tested_compilers) ? "none" :
                join(tested_compilers, "; ")
            ) *
            ". The documented GNU Fortran 8.1.0 candidate is unavailable.",
        )
    end
    report = Dict(
        "schema_version" => 1,
        "evidence_matrix" => file_record(MATRIX_PATH),
        "status" => status,
        "matching_case" => matching_case,
        "best_case" => best_case,
        "best_mismatch_count" =>
            best_mismatch_count == typemax(Int) ? -1 : best_mismatch_count,
        "blocker" => blocker,
        "attempt" => attempts,
    )
    harness().write_toml_atomic(search_report, report)
    println("CASA-CN reconstruction search report: $search_report")
    return search_report
end

function self_test()
    matrix = load_matrix()
    Test.@testset "CASA-CN reconstruction" begin
        Test.@test matrix["points"] == 4263
        Test.@test matrix["prespin_loops"] == 100
        Test.@test matrix["spin_loops"] == 499
        Test.@test matrix["history_years"] == [1901, 2014]
        Test.@test matrix["transformation"]["passive_restoration"]["nitrogen_multiplier"] ==
                   10
        Test.@test matrix["postprocessing"]["spin_checkpoint_interval"] == 9960
        Test.@test final_spin_checkpoints() == (9960, 9980)
        Test.@test Set(keys(candidate_paths())) == Set(CANDIDATE_IDS)
        Test.@test "nlitcwd" in required_variables(matrix)
        Test.@test "nMineral" in required_variables(matrix)
        Test.@test "nMinLoss" in required_variables(matrix)
        Test.@test "nLitInptStruc" in required_variables(matrix)
        Test.@test only(matrix["case"])["source_commit"] ==
                   "82c57f8aa1179865d9752b617493ef06f45c3266"
        Test.@test only(matrix["compiler"]["blocked_candidate"])["version"] ==
                   "GNU Fortran 8.1.0"
        Test.@test retained_daily_years(matrix) ==
                   Set(vcat(collect(1901:1905), collect(2010:2014)))
        historical_outputs = historical_stage_outputs(matrix)
        Test.@test "annual_comparison/1901.toml" in historical_outputs
        Test.@test "annual_comparison/2014.toml" in historical_outputs
        Test.@test netcdf_name(1901; daily = true) in historical_outputs
        Test.@test !(netcdf_name(1906; daily = true) in historical_outputs)
        combined = combine_annual_records([
            Dict(
                "metadata_mismatches" => String[],
                "variable" => Dict(
                    "nMineral" => Dict(
                        "failure_count" => 2,
                        "missing_mismatch_count" => 0,
                        "nonfinite_count" => 0,
                        "sign_change_count" => 1,
                        "max_abs_error" => 0.2,
                        "max_rel_error" => 0.1,
                        "first_failure" => [1901, 1],
                    ),
                ),
            ),
            Dict(
                "metadata_mismatches" => ["units differ"],
                "variable" => Dict(
                    "nMineral" => Dict(
                        "failure_count" => 3,
                        "missing_mismatch_count" => 1,
                        "nonfinite_count" => 0,
                        "sign_change_count" => 0,
                        "max_abs_error" => 0.4,
                        "max_rel_error" => 0.3,
                        "first_failure" => [1902, 2],
                    ),
                ),
            ),
        ])
        Test.@test combined["variable"]["nMineral"]["failure_count"] == 5
        Test.@test combined["variable"]["nMineral"]["max_abs_error"] == 0.4
        Test.@test combined["variable"]["nMineral"]["first_failure"] ==
                   [1901, 1]
        Test.@test combined["metadata_mismatches"] == ["units differ"]
        mktempdir() do root
            restart = joinpath(root, "restart.csv")
            write(
                restart,
                "casamet%areacell,casapool%cplant(LEAF)," *
                "casapool%nplant(LEAF),casapool%csoil(PASS)," *
                "casapool%nsoil(PASS),casapool%nsoilmin\n" *
                "1000000,2,0.2,3.25,0.3,0.04\n" *
                "2000000,4,0.4,5.5,0.5,0.06\n",
            )
            restored = joinpath(root, "restored.csv")
            harness().restore_casa_passive_carbon_nitrogen(restart, restored)
            restoration = passive_restoration_report(restart, restored)
            Test.@test restoration["verified"]
            Test.@test restoration["passive_carbon"]["mismatch_count"] == 0
            Test.@test restoration["passive_nitrogen"]["mismatch_count"] == 0
            Test.@test restoration["passive_nitrogen"]["multiplier"] == 10
            Test.@test restoration["unaffected_columns"]["mismatch_count"] == 0
            diagnostic = restart_diagnostic(restored)
            Test.@test diagnostic["points"] == 2
            Test.@test diagnostic["total_pg"]["carbon"] ≈ 0.1525
            Test.@test diagnostic["total_pg"]["nitrogen"] ≈ 0.01416

            parameter = joinpath(root, "parameters.csv")
            rows = [
                ",xkNlimit_min,xkNlimit_max,fracRootExudate\n",
                "vegtype,gN/m2,gN/m2,fraction\n",
            ]
            append!(rows, ["$pft,0.5,2,0.0\n" for pft in 1:18])
            write(parameter, join(rows))
            audit = exudation_audit(parameter)
            Test.@test audit["pft_count"] == 18
            Test.@test audit["all_zero"]

            daily = joinpath(root, "daily.nc")
            NCDatasets.NCDataset(daily, "c") do dataset
                NCDatasets.defDim(dataset, "time", 365)
            end
            Test.@test daily_file_complete(daily)

            annual = joinpath(root, "annual.nc")
            fill_value = Float32(1.0e36)
            NCDatasets.NCDataset(annual, "c") do dataset
                NCDatasets.defDim(dataset, "x", 2)
                NCDatasets.defDim(dataset, "time", 3)
                stock = NCDatasets.defVar(
                    dataset,
                    "stock",
                    Float32,
                    ("x", "time");
                    fillvalue = fill_value,
                )
                stock.var[:, :] = Float32[
                    1 fill_value 3
                    fill_value fill_value fill_value
                ]
            end
            NCDatasets.NCDataset(annual) do dataset
                reduced = casa().annual_mean(dataset["stock"], 2)
                Test.@test reduced[1] == 2.0f0
                Test.@test reduced[2] == fill_value
            end

            final_finished = Ref(false)
            final_wait = @async wait_for_completed_year(
                daily,
                "";
                final_year = true,
                finished = final_finished,
                poll_seconds = 0.01,
            )
            sleep(0.03)
            Test.@test !istaskdone(final_wait)
            final_finished[] = true
            Test.@test fetch(final_wait)

            control = joinpath(root, "source.lst")
            harness().write_smoke_control(
                root;
                points = 4263,
                loops = 499,
                initialization = 3,
                years = (1901, 1920),
                cycle = 2,
            )
            mv(joinpath(root, "fcasacnp_clm_testbed.lst"), control)
            staged = joinpath(root, "staged.lst")
            write_staged_control(control, staged, Dict(:soil_model => 1))
            parsed = harness().parse_control(staged)
            Test.@test parsed[:cycle] == 2
            Test.@test parsed[:soil_model] == 1
            Test.@test last(casa().annual_output_years(parsed)) == 9980

            stale_report = joinpath(root, "search_report.toml")
            write(stale_report, "status = \"blocked\"\n")
            Test.@test prepare_search_report(root) == stale_report
            Test.@test !isfile(stale_report)
        end
    end
    return true
end

function usage(io = stdout)
    println(
        io,
        "Usage: julia casa_cn_reconstruction.jl run-case " *
        "<source-repo> <data-root> <run-root> <case-id>",
    )
    println(
        io,
        "       julia casa_cn_reconstruction.jl report-case " *
        "<data-root> <run-root> <case-id>",
    )
    println(
        io,
        "       julia casa_cn_reconstruction.jl search " *
        "<source-repo> <data-root> <run-root>",
    )
    println(io, "       julia casa_cn_reconstruction.jl self-test")
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
