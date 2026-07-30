import SHA
import TOML

import ClimaLand

if !isdefined(@__MODULE__, :TestbedNativeMIMICSCNReconstruction)
    include(joinpath(@__DIR__, "native_mimics_cn_reconstruction.jl"))
end
if !isdefined(@__MODULE__, :TestbedMIMICSCNCalibration)
    include(joinpath(@__DIR__, "mimics_cn_calibration.jl"))
end

module GenerateMIMICSCNBoundaryCalibration

import SHA
import TOML

import ClimaLand

const Native =
    getfield(parentmodule(@__MODULE__), :TestbedNativeMIMICSCNReconstruction)
const Calibration =
    getfield(parentmodule(@__MODULE__), :TestbedMIMICSCNCalibration)

const STAGE_DIRECTORIES = Dict(
    "prespin" => "01-prespin",
    "spin" => "02-spin",
    "spin_continuation" => "03-spin_continuation",
    "historical" => "04-historical",
)
const STAGES = ("prespin", "spin", "spin_continuation", "historical")

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

source_record(path) =
    Dict("sha256" => sha256sum(path))

units(variable) =
    startswith(String(variable), "n_") ? "kg N m^-2" : "kg C m^-2"

function boundary_pairs(
    state,
    casa_path,
    mimics_path,
    grid;
    reference_grid_path = joinpath(dirname(casa_path), "grid.csv"),
)
    casa_columns, casa_rows = Native.native_mimics().read_boundary_csv(casa_path)
    mimics_columns, mimics_rows =
        Native.native_mimics().read_boundary_csv(mimics_path)
    length(casa_rows) == length(mimics_rows) ||
        error("MIMICS-CN boundary calibration requires aligned rows")
    reference_grid = Native.native_casa().parse_rows(reference_grid_path)
    by_id = Dict(
        parse(Int, strip(row.ijcam)) => index for
        (index, row) in enumerate(reference_grid)
    )
    indices = map(grid) do point
        get(by_id, point.cell_id) do
            error(
                "MIMICS-CN boundary reference lacks cell $(point.cell_id)",
            )
        end
    end
    return Dict(
        "$(component).$(variable)" => begin
            columns, rows =
                source == :casa ? (casa_columns, casa_rows) :
                (mimics_columns, mimics_rows)
            actual = vec(
                Array(
                    parent(
                        getproperty(getproperty(state, component), variable),
                    ),
                ),
            )
            expected = [
                parse(Float64, rows[index][columns[fortran_name]]) /
                (source == :casa ? 1000 : 1) for index in indices
            ]
            (;
                actual,
                expected,
                observations = [
                    (;
                        cell_id = point.cell_id,
                        pft = point.pft,
                        latitude = point.latitude,
                        longitude = point.longitude,
                    ) for point in grid
                ],
                units = units(variable),
            )
        end for (fortran_name, source, component, variable) in
        Native.BOUNDARY_VARIABLES
    )
end

function validate_exclusions(records, cell_ids)
    ids = Set{Int}()
    boundary_names = Set(
        "$(component).$(variable)" for
        (_, _, component, variable) in Native.BOUNDARY_VARIABLES
    )
    for record in records
        get(record, "reviewed", false) === true ||
            error("MIMICS-CN boundary exclusion is not reviewed")
        cell_id = Int(get(record, "cell_id", 0))
        cell_id in cell_ids ||
            error("MIMICS-CN boundary exclusion is outside its population")
        !isempty(strip(String(get(record, "reason", "")))) &&
            get(record, "first_nonfinite_stage", nothing) in STAGES &&
            get(record, "first_nonfinite_variable", nothing) in
            boundary_names &&
            get(record, "evidence_side", nothing) in ("julia", "fortran") &&
            occursin(
                r"^\d{4}-\d{2}-\d{2}$",
                String(get(record, "first_nonfinite_date", "")),
            ) ||
            error("MIMICS-CN boundary exclusion lacks first-failure evidence")
        cell_id in ids &&
            error("MIMICS-CN boundary exclusion is duplicated")
        push!(ids, cell_id)
    end
    return ids, records
end

cell_ids_sha256(cell_ids) =
    bytes2hex(SHA.sha256(join(string.(cell_ids), ",")))

function compatible_duplicate(left, right)
    return left.observation == right.observation
end

function population_contract(
    population_manifest_path,
    scope_manifest_path,
    label,
    cell_ids,
    grid_path,
    selection_manifest_path = nothing,
)
    population_manifest = TOML.parsefile(population_manifest_path)
    get(population_manifest, "model", nothing) == "MIMICS-CN" ||
        error("boundary population manifest is not for MIMICS-CN")
    scope = TOML.parsefile(scope_manifest_path)
    records = if label == "representative"
        Int.(scope["cell_ids"]) == cell_ids ||
            error("representative boundary population does not match its Scope Manifest")
        [
            gap for gap in get(
                scope,
                "eligibility_gaps",
                Dict{String, Any}[],
            ) if get(gap, "model", nothing) == "MIMICS-CN"
        ]
    else
        candidates = [
            population for population in population_manifest["population"] if
            population["label"] == label
        ]
        length(candidates) == 1 ||
            error("boundary population $label lacks one immutable contract")
        population = only(candidates)
        length(cell_ids) == population["cell_count"] ||
            error("boundary population $label cell count changed")
        cell_ids_sha256(cell_ids) == population["cell_ids_sha256"] ||
            error("boundary population $label cell IDs changed")
        sha256sum(grid_path) == population["grid_sha256"] ||
            error("boundary population $label grid changed")
        isnothing(selection_manifest_path) &&
            error("boundary population $label lacks its selection manifest")
        sha256sum(selection_manifest_path) ==
        population["selection_manifest_sha256"] ||
            error("boundary population $label selection manifest changed")
        get(population, "eligibility_gap", Dict{String, Any}[])
    end
    excluded, reviewed = validate_exclusions(records, cell_ids)
    expected_eligible = if label == "representative"
        length(cell_ids) - length(excluded)
    else
        only([
            population["eligible_cell_count"] for
            population in population_manifest["population"] if
            population["label"] == label
        ])
    end
    length(cell_ids) - length(excluded) == expected_eligible ||
        error("boundary population $label eligibility count changed")
    return excluded, reviewed
end

function failed_pairs(record, pairs, eligible)
    policy = record["derived_policy"]
    failures = 0
    for index in eachindex(pairs.actual)
        pairs.observations[index].cell_id in eligible || continue
        error_value = abs(pairs.actual[index] - pairs.expected[index])
        limit =
            policy["atol"] +
            policy["rtol"] * abs(pairs.expected[index])
        failures += error_value > limit
    end
    return failures
end

function checkpoint_path(output_root, stage)
    directory =
        joinpath(output_root, "stages", stage, "checkpoints", stage)
    return only(
        filter(
            path -> endswith(path, ".hdf5"),
            readdir(directory; join = true),
        ),
    )
end

function write_calibration(
    source_root,
    population_specs,
    path;
    population_manifest_path = joinpath(
        @__DIR__,
        "validation",
        "mimics_cn_boundary_populations.toml",
    ),
    scope_manifest_path = joinpath(
        @__DIR__,
        "validation",
        "scopes",
        "representative.toml",
    ),
)
    isempty(population_specs) &&
        error("MIMICS-CN boundary calibration requires a population")
    soil_path =
        joinpath(source_root, "GRID_CN", "gridinfo_soil_CLM5_GSWP3.csv")
    normal_path =
        joinpath(source_root, "GRID_CN", "pftlookup_igbp_updated4_exud0.csv")
    mimics_path = joinpath(
        source_root,
        "GRID_CN",
        "MIMICS_mod5_GSWP3_JAMES",
        "pftlookup_LIDET-MIM-REV_CN_desorb2xKO4_micCN_FI30.csv",
    )
    all_pairs = Dict(
        stage => Dict(
            "$(component).$(variable)" => Dict{Int, Any}() for
            (_, _, component, variable) in Native.BOUNDARY_VARIABLES
        ) for stage in STAGES
    )
    populations = Dict{String, Any}()
    exclusion_records = Dict{String, Any}[]
    overlapping_cell_ids = Set{Int}()
    duplicate_pair_count = 0
    maximum_duplicate_julia_delta = 0.0
    maximum_duplicate_fortran_delta = 0.0
    for specification in population_specs
        haskey(specification, "exclusions") &&
            error("runtime boundary population specifications cannot declare exclusions")
        label = String(specification["label"])
        haskey(populations, label) &&
            error("MIMICS-CN boundary population label is duplicated")
        grid_path = String(specification["grid_path"])
        reference_root = String(specification["fortran_root"])
        output_root = String(specification["julia_output_root"])
        fortran_workflow_path = String(get(
            specification,
            "fortran_workflow_path",
            joinpath(reference_root, "configuration", "workflow.toml"),
        ))
        fortran_build_path = String(get(
            specification,
            "fortran_build_metadata_path",
            joinpath(reference_root, "build", "build_metadata.toml"),
        ))
        isfile(fortran_workflow_path) ||
            error("MIMICS-CN boundary population lacks Fortran workflow provenance")
        isfile(fortran_build_path) ||
            error("MIMICS-CN boundary population lacks Fortran build provenance")
        fortran_workflow = TOML.parsefile(fortran_workflow_path)
        fortran_source_revision =
            String(get(fortran_workflow, "source_commit", ""))
        length(fortran_source_revision) == 40 &&
            all(isxdigit, fortran_source_revision) ||
            error("MIMICS-CN boundary Fortran source revision is invalid")
        prespin_path = get(
            specification,
            "prespin_parameters_path",
            joinpath(
                reference_root,
                "candidates",
                "parameters",
                "pftlookup_igbp_updated4_borealNfix.candidate.csv",
            ),
        )
        grid = Native.native_casa().read_grid(grid_path)
        cell_ids = getproperty.(grid, :cell_id)
        length(unique(cell_ids)) == length(cell_ids) ||
            error("MIMICS-CN boundary population contains duplicate cell IDs")
        excluded, records = population_contract(
            population_manifest_path,
            scope_manifest_path,
            label,
            cell_ids,
            grid_path,
            get(specification, "selection_manifest_path", nothing),
        )
        append!(
            exclusion_records,
            [merge(Dict("population" => label), record) for record in records],
        )
        eligible = Set(filter(id -> id ∉ excluded, cell_ids))
        soils = Native.native_casa().read_soils(soil_path)
        domain = Native.native_casa().gridded_domain(length(grid))
        buffers = Native.native_mimics().MIMICSBuffers(domain)
        deposition =
            Native.native_casa().scalar_field(domain, zeros(length(grid)))
        prespin = Native.build_gridded_model(
            grid,
            soils,
            prespin_path,
            mimics_path,
            buffers,
            deposition;
            domain,
            boreal_fixation = true,
        )
        normal = Native.build_gridded_model(
            grid,
            soils,
            normal_path,
            mimics_path,
            buffers,
            deposition;
            domain,
        )
        population_pairs = Dict{String, Any}()
        source_stages = Dict{String, Any}()
        unreviewed_nonfinite = NamedTuple[]
        observed_nonfinite = NamedTuple[]
        for stage in STAGES
            checkpoint = checkpoint_path(output_root, stage)
            model = stage == "prespin" ? prespin.model : normal.model
            state, _ = ClimaLand.read_checkpoint(checkpoint; model)
            directory = STAGE_DIRECTORIES[stage]
            casa_path =
                joinpath(reference_root, "stages", directory, "casa_final.csv")
            mimics_reference = joinpath(
                reference_root,
                "stages",
                directory,
                "mimics_final.csv",
            )
            pairs = boundary_pairs(
                state,
                casa_path,
                mimics_reference,
                grid,
                ;
                reference_grid_path = get(
                    specification,
                    "reference_grid_path",
                    joinpath(dirname(casa_path), "grid.csv"),
                ),
            )
            population_pairs[stage] = pairs
            for (name, values) in pairs
                for index in eachindex(values.actual)
                    cell_id = values.observations[index].cell_id
                    if !isfinite(values.actual[index]) ||
                       !isfinite(values.expected[index])
                        item = (;
                            cell_id,
                            stage,
                            variable = name,
                            side =
                                !isfinite(values.actual[index]) ?
                                "julia" : "fortran",
                        )
                        push!(observed_nonfinite, item)
                        cell_id in excluded || push!(unreviewed_nonfinite, item)
                        continue
                    end
                    cell_id in eligible || continue
                    pair = (
                        actual = values.actual[index],
                        expected = values.expected[index],
                        observation = values.observations[index],
                    )
                    existing = get(all_pairs[stage][name], cell_id, nothing)
                    if !isnothing(existing)
                        compatible_duplicate(existing, pair) || error(
                            "incompatible duplicate MIMICS-CN boundary pair for cell $cell_id at $stage.$name: existing=$existing candidate=$pair",
                        )
                        push!(overlapping_cell_ids, cell_id)
                        duplicate_pair_count += 1
                        maximum_duplicate_julia_delta = max(
                            maximum_duplicate_julia_delta,
                            abs(existing.actual - pair.actual),
                        )
                        maximum_duplicate_fortran_delta = max(
                            maximum_duplicate_fortran_delta,
                            abs(existing.expected - pair.expected),
                        )
                        continue
                    end
                    all_pairs[stage][name][cell_id] = pair
                end
            end
            source_stages[stage] = Dict(
                "checkpoint" => source_record(checkpoint),
                "fresh_fortran_casa" => source_record(casa_path),
                "fresh_fortran_mimics" => source_record(mimics_reference),
            )
        end
        for record in records
            cell_id = Int(record["cell_id"])
            evidence = filter(
                item ->
                    item.cell_id == cell_id &&
                    item.stage == record["first_nonfinite_stage"] &&
                    item.variable == record["first_nonfinite_variable"] &&
                    item.side == record["evidence_side"],
                observed_nonfinite,
            )
            isempty(evidence) && error(
                "reviewed MIMICS-CN exclusion for cell $cell_id is not supported by the supplied outputs",
            )
            first_stage = minimum(
                findfirst(==(item.stage), STAGES) for
                item in observed_nonfinite if item.cell_id == cell_id
            )
            STAGES[first_stage] == record["first_nonfinite_stage"] || error(
                "reviewed MIMICS-CN exclusion for cell $cell_id is not its first nonfinite stage",
            )
        end
        if !isempty(unreviewed_nonfinite)
            sort!(
                unreviewed_nonfinite;
                by = item -> (
                    item.cell_id,
                    findfirst(==(item.stage), STAGES),
                    item.variable,
                    item.side,
                ),
            )
            first_failure = Dict{Int, Any}()
            for item in unreviewed_nonfinite
                get!(first_failure, item.cell_id, item)
            end
            error(
                "eligible MIMICS-CN boundary pairs are nonfinite: " *
                join(
                    (
                        "cell $(item.cell_id) $(item.stage).$(item.variable) ($(item.side))" for
                        item in sort!(
                            collect(values(first_failure));
                            by = item -> item.cell_id,
                        )
                    ),
                    "; ",
                ),
            )
        end
        populations[label] = Dict(
            "cell_count" => length(cell_ids),
            "eligible_cell_count" => length(eligible),
            "cell_ids_sha256" => cell_ids_sha256(cell_ids),
            "fortran_source_revision" => fortran_source_revision,
            "fortran_workflow" => source_record(fortran_workflow_path),
            "fortran_build" => source_record(fortran_build_path),
            "sources" => source_stages,
            "_eligible" => eligible,
            "_pairs" => population_pairs,
        )
    end
    variables = Dict(
        stage => Dict(
            name => begin
                pairs = sort!(collect(values(by_cell)); by = x -> x.observation.cell_id)
                Calibration.calibration_record(
                    getproperty.(pairs, :actual),
                    getproperty.(pairs, :expected);
                    units = units(
                        Symbol(last(split(name, "."))),
                    ),
                    observations = getproperty.(pairs, :observation),
                )
            end for (name, by_cell) in stage_pairs
        ) for (stage, stage_pairs) in all_pairs
    )
    population_validation = Dict(
        label => Dict(
            stage => Dict(
                name => Dict(
                    "finite_pair_count" => count(
                        observation ->
                            observation.cell_id in record["_eligible"],
                        pairs.observations,
                    ),
                    "failed_pairs" => failed_pairs(
                        variables[stage][name],
                        pairs,
                        record["_eligible"],
                    ),
                ) for (name, pairs) in record["_pairs"][stage]
            ) for stage in STAGES
        ) for (label, record) in populations
    )
    all(
        validation["failed_pairs"] == 0 for
        population in values(population_validation) for
        stage in values(population) for validation in values(stage)
    ) || error("MIMICS-CN fitted boundary policy failed a source population")
    for record in values(populations)
        delete!(record, "_eligible")
        delete!(record, "_pairs")
    end
    repo_root = normpath(joinpath(@__DIR__, "..", ".."))
    document = Dict(
        "schema_version" => 1,
        "calibration_id" =>
            "mimics-cn-current-julia-fresh-fortran-800-representative-union-boundary-v1",
        "model" => "MIMICS-CN",
        "source" => "fresh_fortran_compatible_population_union",
        "union_cell_count" => maximum(
            length(by_cell) for stage in values(all_pairs) for
            by_cell in values(stage)
        ),
        "method" => Dict(
            "error" => "e_i = abs(Julia_i - Fortran_i)",
            "reference_magnitude" => "x_i = abs(Fortran_i)",
            "raw_absolute" => "a(r) = max(0, max_i(e_i - r*x_i))",
            "selection" =>
                "choose the smallest r >= 0 minimizing a(r) + r*mean(x)",
            "safety_margin" =>
                "multiply raw atol and rtol by 1.05, then add 64eps(Float64) times the maximum observed Julia/Fortran magnitude to atol",
            "nonfinite" =>
                "fail calibration; exclusions require a reviewed Scope Manifest Eligibility Gap",
        ),
        "deduplication" => Dict(
            "rule" =>
                "one pair per cell/stage/variable; overlapping population metadata must match exactly, the first population is retained, and compatibility requires zero failed pairs when the fitted policy is applied independently to both complete populations",
            "overlapping_cell_count" => length(overlapping_cell_ids),
            "overlapping_cell_ids" => sort!(collect(overlapping_cell_ids)),
            "duplicate_pair_count" => duplicate_pair_count,
            "maximum_julia_absolute_delta" =>
                maximum_duplicate_julia_delta,
            "maximum_fortran_absolute_delta" =>
                maximum_duplicate_fortran_delta,
        ),
        "source_provenance" => Dict(
            "git_revision_basis" =>
                readchomp(`git -C $repo_root rev-parse HEAD`),
            "julia_version" => string(VERSION),
            "generator" => merge(
                Dict("id" => relpath(@__FILE__, repo_root)),
                source_record(@__FILE__),
            ),
            "calibration" => Dict(
                "id" => relpath(
                    joinpath(@__DIR__, "mimics_cn_calibration.jl"),
                    repo_root,
                ),
                "sha256" => sha256sum(
                    joinpath(@__DIR__, "mimics_cn_calibration.jl"),
                ),
            ),
            "population_manifest" => Dict(
                "id" => relpath(population_manifest_path, repo_root),
                "sha256" => sha256sum(population_manifest_path),
            ),
            "scope_manifest" => Dict(
                "id" => relpath(scope_manifest_path, repo_root),
                "sha256" => sha256sum(scope_manifest_path),
            ),
            "normal_casa_parameters" => source_record(normal_path),
            "mimics_parameters" => source_record(mimics_path),
            "population" => populations,
        ),
        "reviewed_exclusion" => exclusion_records,
        "population_validation" => population_validation,
        "variable" => variables,
    )
    mkpath(dirname(abspath(path)))
    temporary = "$(abspath(path)).tmp"
    open(temporary, "w") do io
        TOML.print(io, document; sorted = true)
    end
    mv(temporary, abspath(path); force = true)
    return abspath(path)
end

function main(args = ARGS)
    length(args) == 3 || error(
        "usage: generate_mimics_cn_boundary_calibration.jl SOURCE_ROOT POPULATIONS_TOML OUTPUT_PATH",
    )
    source_root, populations_path, output_path = args
    population_document = TOML.parsefile(populations_path)
    return write_calibration(
        source_root,
        population_document["population"],
        output_path,
    )
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    GenerateMIMICSCNBoundaryCalibration.main()
end
