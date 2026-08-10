include(joinpath(@__DIR__, "reference_harness.jl"))
include(joinpath(@__DIR__, "selected_cell_fixtures.jl"))
include(joinpath(@__DIR__, "generate_selected_corpse_reference.jl"))

module GenerateCompleteSelectedCORPSEReference

import SHA
import TOML

import NCDatasets

const HARNESS = getfield(parentmodule(@__MODULE__), :TestbedReferenceHarness)
const SELECTED =
    getfield(parentmodule(@__MODULE__), :TestbedSelectedCellFixtures)
const BASE_GENERATOR =
    getfield(parentmodule(@__MODULE__), :GenerateSelectedCORPSEReference)
const SELECTED_FIXTURE = joinpath(@__DIR__, "fixtures", "selected_cells")
const REFERENCE_DIRECTORY = joinpath(@__DIR__, "fixtures", "selected_corpse")
const ARTIFACT_FILENAME = "complete_workflow.nc"
const MANIFEST_FILENAME = "complete_workflow.toml"
const SOURCE_REPOSITORY = "https://github.com/wwieder/biogeochem_testbed.git"
const STAGES = (
    (
        name = "prespin",
        loops = 100,
        years = 1901:1901,
        initialization = 0,
        netcdf_interval = 99,
        saved_years = (1, 99, 100),
    ),
    (
        name = "spin",
        loops = 499,
        years = 1901:1920,
        initialization = 3,
        netcdf_interval = 9960,
        saved_years = (1, 9960, 9980),
    ),
    (
        name = "restart",
        loops = 499,
        years = 1901:1920,
        initialization = 3,
        netcdf_interval = 9960,
        saved_years = (1, 9960, 9980),
    ),
    (
        name = "historical",
        loops = 1,
        years = 1901:2014,
        initialization = 2,
        netcdf_interval = 1,
        saved_years = Tuple(1901:2014),
    ),
)
const CORPSE_COMPONENTS = (
    "unprotected_labile",
    "unprotected_recalcitrant",
    "unprotected_dead_microbe",
    "protected_labile",
    "protected_recalcitrant",
    "protected_dead_microbe",
    "living_microbe",
    "cumulative_respiration",
    "original_carbon",
    "cumulative_decomposition",
)
const LAYERS = ("litter", "soil")
const COHORTS = ("rhizosphere", "bulk")
const HISTORICAL_YEARS = (1901, 1957, 2014)
const HISTORICAL_CASA_FIELDS = ("cleaf", "cwood", "cfroot", "clitcwd")
const HISTORICAL_CORPSE_FIELDS = (
    "Soil_C1",
    "Soil_C2",
    "Soil_C3",
    "SoilProtected_C1",
    "SoilProtected_C2",
    "SoilProtected_C3",
    "Soil_LiveMicrobeC",
    "LitterLayer_C1",
    "LitterLayer_C2",
    "LitterLayer_C3",
    "LitterLayer_LiveMicrobeC",
    "Ts",
    "thetaLiq",
    "thetaFrzn",
)

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

function materialize_configuration(source_root, run_root, inputs, manifest)
    configuration = joinpath(run_root, "configuration")
    controls = joinpath(configuration, "controls")
    forcing = joinpath(configuration, "forcing")
    mkpath(controls)
    mkpath(forcing)
    grid = joinpath(configuration, "grid.csv")
    BASE_GENERATOR.write_fortran_grid(inputs.selected_files["grid"], grid)
    for year in 1901:2014
        BASE_GENERATOR.write_fortran_meteorology(
            inputs.selected_files["forcing"],
            joinpath(forcing, "met_$(year)_$(year).nc");
            selected_year = year,
        )
    end

    points = length(manifest["selection"]["extended_cell_ids"])
    controls_by_stage = Dict{String, String}()
    for stage in STAGES
        daily = 0
        control = HARNESS.write_smoke_control(
            controls;
            points,
            daily_output = daily,
            soil_model = 3,
            loops = stage.loops,
            initialization = stage.initialization,
            years = (first(stage.years), last(stage.years)),
            cycle = 1,
            meteorology = "met_1901_1901.nc",
            casa_initial = "casa_initial.csv",
            casa_final = "casa_final.csv",
            casa_flux_final = "casa_flux_final.csv",
            casa_netcdf = "casaclm_pool_flux_yyyy.nc",
            corpse_initial = "corpse_initial.csv",
            corpse_final = "corpse_final.csv",
            corpse_parameters = "corpse_parameters.nml",
            corpse_netcdf = "corpse_pool_flux_yyyy.nc",
            netcdf_interval = stage.netcdf_interval,
        )
        destination = joinpath(controls, "$(stage.name).lst")
        mv(control, destination; force = true)
        controls_by_stage[stage.name] = destination
    end
    return (; configuration, forcing, grid, controls_by_stage)
end

output_name(prefix, year, daily) =
    "$(prefix)_pool_flux_$(lpad(year, 4, '0'))$(daily ? "_daily" : "").nc"

function stage_outputs(stage)
    daily = false
    outputs = ["casa_final.csv", "casa_flux_final.csv", "corpse_final.csv"]
    for prefix in ("casaclm", "corpse")
        append!(outputs, output_name.(prefix, stage.saved_years, daily))
    end
    if stage.initialization == 0
        push!(outputs, "casaclm_pool_flux_yyyy.nc")
        push!(outputs, "corpse_pool_flux_yyyy.nc")
    end
    return outputs
end

function common_inputs(configuration, stage, inputs)
    workflow_input = HARNESS.workflow_input
    records = [
        workflow_input(configuration.grid, "grid.csv"),
        workflow_input(inputs.selected_files["soil"], "soil.csv"),
        workflow_input(
            inputs.selected_files["casa_c_parameters"],
            "casa_parameters.csv",
        ),
        workflow_input(
            inputs.selected_files["corpse_parameters"],
            "corpse_parameters.nml",
        ),
        workflow_input(inputs.selected_files["phenology"], "phenology.txt"),
        workflow_input(
            inputs.selected_files["perturbation"],
            "perturbation.txt",
        ),
    ]
    for year in stage.years
        filename = "met_$(year)_$(year).nc"
        push!(
            records,
            workflow_input(
                joinpath(configuration.forcing, filename),
                filename;
                mode = "symlink",
            ),
        )
    end
    return records
end

function write_workflow(source_root, run_root)
    selected_manifest =
        TOML.parsefile(joinpath(SELECTED_FIXTURE, "fixture.toml"))
    inputs = BASE_GENERATOR.verified_inputs(source_root, selected_manifest)
    configuration = materialize_configuration(
        source_root,
        run_root,
        inputs,
        selected_manifest,
    )
    stage_specs = Dict{String, Any}[]
    for (index, stage) in enumerate(STAGES)
        stage_inputs = common_inputs(configuration, stage, inputs)
        if index > 1
            predecessor = STAGES[index - 1].name
            push!(
                stage_inputs,
                HARNESS.workflow_input(
                    "stage:$predecessor/casa_final.csv",
                    "casa_initial.csv",
                ),
            )
            push!(
                stage_inputs,
                HARNESS.workflow_input(
                    "stage:$predecessor/corpse_final.csv",
                    "corpse_initial.csv",
                ),
            )
        end
        push!(
            stage_specs,
            Dict(
                "name" => stage.name,
                "control" => relpath(
                    configuration.controls_by_stage[stage.name],
                    configuration.configuration,
                ),
                "outputs" => stage_outputs(stage),
                "input" => stage_inputs,
            ),
        )
    end
    workflow = Dict(
        "schema_version" => 1,
        "name" => "selected-cell-corpse-complete-workflow",
        "source_commit" => inputs.commit,
        "stage" => stage_specs,
    )
    workflow_path = joinpath(configuration.configuration, "workflow.toml")
    HARNESS.write_toml_atomic(workflow_path, workflow)
    return (; workflow_path, selected_manifest, inputs)
end

function read_csv(path)
    lines = readlines(path)
    isempty(lines) && error("Empty CSV: $path")
    header = strip.(split(first(lines), ','; keepempty = true))
    # The Fortran writer leaves a trailing comma on data rows.
    rows = map(lines[2:end]) do line
        values = strip.(split(line, ','; keepempty = true))
        isempty(last(values)) && pop!(values)
        length(values) == length(header) || error(
            "CSV column mismatch in $path: $(length(values)) != $(length(header))",
        )
        values
    end
    return (; header, rows)
end

function ordered_rows(table, cell_ids, id_name)
    id_column = only(findall(==(id_name), table.header))
    rows = Dict(parse(Int, row[id_column]) => row for row in table.rows)
    return map(cell_ids) do cell_id
        haskey(rows, cell_id) || error("Cell $cell_id is missing from $id_name")
        rows[cell_id]
    end
end

column(table, name) = only(findall(==(name), table.header))

function corpse_column_name(layer, cohort, component)
    prefix = layer == "litter" ? "litlyr" : "soil_1"
    suffix = cohort == "rhizosphere" ? "rhiz" : "bulk"
    component == "unprotected_labile" &&
        return "$(prefix)_unprotect_$(suffix)(LABILE)"
    component == "unprotected_recalcitrant" &&
        return "$(prefix)_unprotect_$(suffix)(RECALCTRNT)"
    component == "unprotected_dead_microbe" &&
        return "$(prefix)_unprotect_$(suffix)(DEADMICRB)"
    component == "protected_labile" &&
        return "$(prefix)_protect_$(suffix)(LABILE)"
    component == "protected_recalcitrant" &&
        return "$(prefix)_protect_$(suffix)(RECALCTRNT)"
    component == "protected_dead_microbe" &&
        return "$(prefix)_protect_$(suffix)(DEADMICRB)"
    component == "living_microbe" && return "$(prefix)_livingMicrobeC_$(suffix)"
    component == "cumulative_respiration" && return "$(prefix)_CO2_$(suffix)"
    component == "original_carbon" && return "$(prefix)_originalC_$(suffix)"
    component == "cumulative_decomposition" && return "$(prefix)_Rtot_$(suffix)"
    error("Unsupported CORPSE component: $component")
end

function boundary_arrays(run_root, cell_ids)
    stage_count = length(STAGES)
    cell_count = length(cell_ids)
    casa_tables = Any[]
    corpse_tables = Any[]
    for (index, stage) in enumerate(STAGES)
        directory =
            joinpath(run_root, "stages", "$(lpad(index, 2, '0'))-$(stage.name)")
        push!(casa_tables, read_csv(joinpath(directory, "casa_final.csv")))
        push!(corpse_tables, read_csv(joinpath(directory, "corpse_final.csv")))
    end
    casa_fields = filter(
        name -> startswith(lowercase(name), "casapool%c"),
        first(casa_tables).header,
    )
    casa_state = zeros(Float64, length(casa_fields), stage_count, cell_count)
    corpse_state = zeros(
        Float64,
        length(CORPSE_COMPONENTS),
        stage_count,
        cell_count,
        length(LAYERS),
        length(COHORTS),
    )
    pfts = zeros(Int32, cell_count)
    for stage_index in eachindex(STAGES)
        casa = casa_tables[stage_index]
        corpse = corpse_tables[stage_index]
        casa_rows = ordered_rows(casa, collect(eachindex(cell_ids)), "npt")
        corpse_rows = ordered_rows(corpse, cell_ids, "ijgcm")
        for (field_index, field) in enumerate(casa_fields)
            field_column = column(casa, field)
            casa_state[field_index, stage_index, :] =
                parse.(Float64, getindex.(casa_rows, field_column))
        end
        pft_column = column(corpse, "veg")
        stage_pfts = Int32.(parse.(Int, getindex.(corpse_rows, pft_column)))
        if stage_index == 1
            pfts .= stage_pfts
        else
            pfts == stage_pfts || error("PFT identity changed between stages")
        end
        for (component_index, component) in enumerate(CORPSE_COMPONENTS),
            (layer_index, layer) in enumerate(LAYERS),
            (cohort_index, cohort) in enumerate(COHORTS)

            field = corpse_column_name(layer, cohort, component)
            field_column = column(corpse, field)
            corpse_state[
                component_index,
                stage_index,
                :,
                layer_index,
                cohort_index,
            ] = parse.(Float64, getindex.(corpse_rows, field_column))
        end
    end
    return (; casa_fields, casa_state, corpse_state, pfts)
end

function historical_arrays(run_root, cell_ids)
    directory = joinpath(run_root, "stages", "04-historical")
    casa = zeros(
        Float64,
        length(HISTORICAL_CASA_FIELDS),
        length(HISTORICAL_YEARS),
        length(cell_ids),
    )
    corpse = zeros(
        Float64,
        length(HISTORICAL_CORPSE_FIELDS),
        length(HISTORICAL_YEARS),
        length(cell_ids),
    )
    for (year_index, year) in enumerate(HISTORICAL_YEARS)
        NCDatasets.NCDataset(
            joinpath(directory, output_name("casaclm", year, false)),
        ) do dataset
            Int.(vec(dataset["cellid"][:, 1])) == cell_ids ||
                error("Historical CASA cells are not in fixture order")
            for (field_index, field) in enumerate(HISTORICAL_CASA_FIELDS)
                casa[field_index, year_index, :] =
                    vec(Float64.(dataset[field][:, 1, 1]))
            end
        end
        NCDatasets.NCDataset(
            joinpath(directory, output_name("corpse", year, false)),
        ) do dataset
            Int.(vec(dataset["cellid"][:, 1])) == cell_ids ||
                error("Historical CORPSE cells are not in fixture order")
            for (field_index, field) in enumerate(HISTORICAL_CORPSE_FIELDS)
                corpse[field_index, year_index, :] =
                    vec(Float64.(dataset[field][:, 1, 1]))
            end
        end
    end
    return (; casa, corpse)
end

function diagnostics(arrays, cell_ids)
    respiration = findfirst(==("cumulative_respiration"), CORPSE_COMPONENTS)
    original = findfirst(==("original_carbon"), CORPSE_COMPONENTS)
    active_components = 1:7
    conservation = Dict{String, Any}[]
    active_total = zeros(Float64, length(STAGES), length(cell_ids))
    for stage_index in eachindex(STAGES), cell_index in eachindex(cell_ids)
        active = sum(
            arrays.corpse_state[
                active_components,
                stage_index,
                cell_index,
                :,
                :,
            ],
        )
        respired =
            sum(arrays.corpse_state[respiration, stage_index, cell_index, :, :])
        source =
            sum(arrays.corpse_state[original, stage_index, cell_index, :, :])
        residual = active + respired - source
        active_total[stage_index, cell_index] = active
        push!(
            conservation,
            Dict(
                "stage" => STAGES[stage_index].name,
                "cell_id" => cell_ids[cell_index],
                "active_carbon" => active,
                "cumulative_respiration" => respired,
                "original_carbon" => source,
                "residual" => residual,
                "close" => abs(residual) <= 1.0e-4,
            ),
        )
    end
    convergence = map(eachindex(cell_ids)) do cell_index
        before = active_total[2, cell_index]
        after = active_total[3, cell_index]
        difference = abs(after - before)
        Dict(
            "cell_id" => cell_ids[cell_index],
            "spin_active_carbon" => before,
            "restart_active_carbon" => after,
            "absolute_change" => difference,
            "relative_change" =>
                difference / max(abs(before), eps(Float64)),
        )
    end
    return Dict(
        "conservation" => conservation,
        "spin_convergence" => convergence,
    )
end

function write_artifact(path, arrays, historical, cell_ids, core_ids)
    NCDatasets.NCDataset(path, "c"; format = :netcdf4) do dataset
        NCDatasets.defDim(dataset, "cell", length(cell_ids))
        NCDatasets.defDim(dataset, "stage", length(STAGES))
        NCDatasets.defDim(
            dataset,
            "casa_state_field",
            length(arrays.casa_fields),
        )
        NCDatasets.defDim(
            dataset,
            "corpse_state_field",
            length(CORPSE_COMPONENTS),
        )
        NCDatasets.defDim(dataset, "layer", length(LAYERS))
        NCDatasets.defDim(dataset, "cohort", length(COHORTS))
        NCDatasets.defDim(dataset, "historical_year", length(HISTORICAL_YEARS))
        NCDatasets.defDim(
            dataset,
            "historical_casa_field",
            length(HISTORICAL_CASA_FIELDS),
        )
        NCDatasets.defDim(
            dataset,
            "historical_corpse_field",
            length(HISTORICAL_CORPSE_FIELDS),
        )
        dataset.attrib["source"] = "pinned fresh GSWP3 CORPSE Fortran workflow"
        NCDatasets.defVar(dataset, "cellid", Int32, ("cell",))[:] = cell_ids
        NCDatasets.defVar(dataset, "pft", Int32, ("cell",))[:] = arrays.pfts
        NCDatasets.defVar(dataset, "core_cell", Int8, ("cell",))[:] =
            Int8.(in.(cell_ids, Ref(Set(core_ids))))
        NCDatasets.defVar(dataset, "stage_name", String, ("stage",))[:] =
            [stage.name for stage in STAGES]
        NCDatasets.defVar(
            dataset,
            "casa_state_field",
            String,
            ("casa_state_field",),
        )[:] = String.(arrays.casa_fields)
        NCDatasets.defVar(
            dataset,
            "corpse_state_field",
            String,
            ("corpse_state_field",),
        )[:] = collect(CORPSE_COMPONENTS)
        NCDatasets.defVar(dataset, "layer_name", String, ("layer",))[:] =
            collect(LAYERS)
        NCDatasets.defVar(dataset, "cohort_name", String, ("cohort",))[:] =
            collect(COHORTS)
        casa_state = NCDatasets.defVar(
            dataset,
            "casa_state",
            Float64,
            ("casa_state_field", "stage", "cell");
            deflatelevel = 3,
        )
        casa_state.attrib["units"] = "g C m-2"
        casa_state[:] = arrays.casa_state
        corpse_state = NCDatasets.defVar(
            dataset,
            "corpse_state",
            Float64,
            ("corpse_state_field", "stage", "cell", "layer", "cohort");
            deflatelevel = 3,
        )
        corpse_state.attrib["units"] = "kg C m-2"
        corpse_state[:] = arrays.corpse_state
        NCDatasets.defVar(
            dataset,
            "historical_year",
            Int32,
            ("historical_year",),
        )[:] = collect(Int32.(HISTORICAL_YEARS))
        NCDatasets.defVar(
            dataset,
            "historical_casa_field",
            String,
            ("historical_casa_field",),
        )[:] = collect(HISTORICAL_CASA_FIELDS)
        NCDatasets.defVar(
            dataset,
            "historical_corpse_field",
            String,
            ("historical_corpse_field",),
        )[:] = collect(HISTORICAL_CORPSE_FIELDS)
        historical_casa = NCDatasets.defVar(
            dataset,
            "historical_casa",
            Float64,
            ("historical_casa_field", "historical_year", "cell");
            deflatelevel = 3,
        )
        historical_casa.attrib["units"] = "g C m-2 annual mean"
        historical_casa[:] = historical.casa
        historical_corpse = NCDatasets.defVar(
            dataset,
            "historical_corpse",
            Float64,
            ("historical_corpse_field", "historical_year", "cell");
            deflatelevel = 3,
        )
        historical_corpse.attrib["units"] = "source units; carbon g C m-2, temperature K, saturation fraction"
        historical_corpse[:] = historical.corpse
    end
    return path
end

function stage_record(result)
    metadata_path = joinpath(result.directory, "stage_metadata.toml")
    metadata = TOML.parsefile(metadata_path)
    inputs = Dict(
        record["destination"] =>
            sha256sum(joinpath(result.directory, record["destination"])) for
        record in metadata["inputs"]
    )
    outputs = Dict(
        filename => sha256sum(joinpath(result.directory, filename)) for
        filename in keys(metadata["outputs"])
    )
    return Dict(
        "name" => result.name,
        "status" => "complete",
        "elapsed_seconds" => metadata["elapsed_seconds"],
        "hashes" => Dict(
            "control" => sha256sum(
                joinpath(result.directory, metadata["control"]["materialized"]),
            ),
            "inputs" => inputs,
            "outputs" => outputs,
            "log" => sha256sum(joinpath(result.directory, metadata["log"])),
        ),
    )
end

function build_record(run_root)
    workflow = TOML.parsefile(joinpath(run_root, "workflow_metadata.toml"))
    executable = workflow["executable"]["path"]
    cache = TOML.parsefile(joinpath(dirname(executable), "cache_metadata.toml"))
    build = TOML.parsefile(joinpath(dirname(executable), "build_metadata.toml"))
    return Dict(
        "compiler" => build["build"]["compiler_version"],
        "flags" => build["build"]["flags"],
        "netcdf_fortran" => build["build"]["netcdf_fortran_version"],
        "compatibility_patch_md5" => build["build"]["compatibility_patch_md5"],
        "fingerprint" => cache["fingerprint"],
        "executable_sha256" => sha256sum(executable),
    )
end

function generate(source_root, run_root, destination = REFERENCE_DIRECTORY)
    mkpath(run_root)
    mkpath(destination)
    specification = write_workflow(source_root, run_root)
    executable = HARNESS.ensure_fortran_build(
        source_root,
        run_root;
        expected_commit = specification.inputs.commit,
    )
    results = HARNESS.run_stage_workflow(
        executable,
        specification.workflow_path,
        run_root,
    )
    all(result.status in (:ran, :reused, :recovered) for result in results) ||
        error("The complete CORPSE workflow did not finish")

    selection = specification.selected_manifest["selection"]
    cell_ids = Int.(selection["extended_cell_ids"])
    core_ids = Int.(selection["core_cell_ids"])
    arrays = boundary_arrays(run_root, cell_ids)
    historical = historical_arrays(run_root, cell_ids)
    artifact_path = write_artifact(
        joinpath(destination, ARTIFACT_FILENAME),
        arrays,
        historical,
        cell_ids,
        core_ids,
    )
    manifest = Dict(
        "schema_version" => 1,
        "title" => "Complete selected-cell CORPSE fresh-Fortran workflow reference",
        "artifact" => Dict(
            "filename" => ARTIFACT_FILENAME,
            "bytes" => filesize(artifact_path),
            "sha256" => sha256sum(artifact_path),
        ),
        "source" => Dict(
            "repository" => SOURCE_REPOSITORY,
            "commit" => specification.inputs.commit,
            "selected_fixture_sha256" =>
                sha256sum(joinpath(SELECTED_FIXTURE, "fixture.toml")),
            "casa_parameters_sha256" =>
                specification.inputs.selected_hashes["casa_c_parameters"],
            "corpse_namelist_sha256" =>
                specification.inputs.selected_hashes["corpse_parameters"],
            "forcing_sha256" =>
                specification.inputs.selected_hashes["forcing"],
        ),
        "build" => build_record(run_root),
        "oracle" => Dict(
            "designation" => "fresh_gswp3_fortran",
            "reason" => "the legacy mean lacks its exact CRU-NCEP forcing and CASA/CORPSE restart",
            "legacy_2000_2010_mean" => Dict(
                "promoted" => false,
                "status" => "informational_only_missing_reproducible_inputs",
            ),
        ),
        "collection" => Dict(
            "core" => Dict("status" => "complete", "cell_ids" => core_ids),
            "extended" =>
                Dict("status" => "complete", "cell_ids" => cell_ids),
        ),
        "stage" => stage_record.(results),
        "diagnostics" => diagnostics(arrays, cell_ids),
        "extraction" => Dict(
            "command" => "julia --project=test generate_complete_selected_corpse_reference.jl <source-root> <run-root> [destination]",
            "state_boundary" => "final CASA and cohort-resolved CORPSE restart state for each stage",
            "historical_coverage" => "1901, 1957, and 2014 annual samples packed from the hash-verified 1901-2014 raw outputs",
            "core_representation" => "core_cell mask over the complete extended-cell artifact",
        ),
    )
    manifest_path = joinpath(destination, MANIFEST_FILENAME)
    HARNESS.write_toml_atomic(manifest_path, manifest)
    return (; artifact_path, manifest_path, run_root)
end

function main(args)
    length(args) in (2, 3) || error(
        "usage: julia --project=test generate_complete_selected_corpse_reference.jl " *
        "<testbed-source-root> <run-root> [destination]",
    )
    destination = length(args) == 3 ? args[3] : REFERENCE_DIRECTORY
    result = generate(args[1], args[2], destination)
    println("CORPSE workflow artifact: $(result.artifact_path)")
    println("CORPSE workflow manifest: $(result.manifest_path)")
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    GenerateCompleteSelectedCORPSEReference.main(ARGS)
end
