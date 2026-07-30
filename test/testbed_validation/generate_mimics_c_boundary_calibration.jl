import SHA
import TOML

import ClimaLand

if !isdefined(@__MODULE__, :TestbedNativeMIMICSCReconstruction)
    include(joinpath(@__DIR__, "native_mimics_c_reconstruction.jl"))
end
if !isdefined(@__MODULE__, :TestbedMIMICSCCalibration)
    include(joinpath(@__DIR__, "mimics_c_calibration.jl"))
end

module GenerateMIMICSCBoundaryCalibration

import SHA
import TOML

import ClimaLand

const Native =
    getfield(parentmodule(@__MODULE__), :TestbedNativeMIMICSCReconstruction)
const Calibration =
    getfield(parentmodule(@__MODULE__), :TestbedMIMICSCCalibration)

const STAGE_DIRECTORIES = Dict(
    "prespin" => "01-prespin",
    "spin" => "02-spin",
    "historical" => "03-historical",
)

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

source_record(path) = Dict("sha256" => sha256sum(path))

cell_ids_sha256(cell_ids) = bytes2hex(SHA.sha256(join(string.(cell_ids), ",")))

function population_contract(path, grid_path, cell_ids)
    document = TOML.parsefile(path)
    get(document, "schema_version", nothing) == 1 &&
        get(document, "model", nothing) == "MIMICS-C" ||
        error("MIMICS-C boundary population contract is incompatible")
    population = document["population"]
    get(population, "label", nothing) == "global" &&
        get(population, "cell_count", nothing) == length(cell_ids) &&
        get(population, "cell_ids_sha256", nothing) ==
        cell_ids_sha256(cell_ids) &&
        get(population, "grid_sha256", nothing) == sha256sum(grid_path) ||
        error("MIMICS-C boundary population changed")
    gaps = get(population, "eligibility_gaps", Dict{String, Any}[])
    excluded = Set{Int}()
    boundary_names = Set(
        "$(component).$(variable)" for
        (_, _, component, variable) in Native.BOUNDARY_VARIABLES
    )
    for gap in gaps
        cell_id = Int(get(gap, "cell_id", 0))
        get(gap, "reviewed", false) === true &&
            cell_id in cell_ids &&
            get(gap, "first_nonfinite_stage", nothing) in
            keys(STAGE_DIRECTORIES) &&
            get(gap, "first_nonfinite_variable", nothing) in boundary_names &&
            get(gap, "evidence_side", nothing) in ("julia", "fortran") &&
            occursin(
                r"^\d{4}-\d{2}-\d{2}$",
                String(get(gap, "first_nonfinite_date", "")),
            ) || error("MIMICS-C boundary exclusion lacks reviewed evidence")
        cell_id in excluded &&
            error("MIMICS-C boundary exclusion is duplicated")
        push!(excluded, cell_id)
    end
    get(population, "eligible_cell_count", nothing) ==
    length(cell_ids) - length(excluded) ||
        error("MIMICS-C boundary eligibility count changed")
    return (; population, gaps, excluded)
end

function boundary_values(
    state,
    casa_path,
    mimics_path,
    grid,
    excluded,
    reference_grid_path = joinpath(dirname(casa_path), "grid.csv"),
)
    casa_columns, casa_rows = Native.read_boundary_csv(casa_path)
    mimics_columns, mimics_rows = Native.read_boundary_csv(mimics_path)
    length(casa_rows) == length(mimics_rows) == length(grid) == 4263 ||
        error("MIMICS-C boundary calibration requires 4,263 aligned rows")
    reference_grid = Native.casa().parse_rows(reference_grid_path)
    by_id = Dict(
        parse(Int, strip(row.ijcam)) => index for
        (index, row) in enumerate(reference_grid)
    )
    indices = map(grid) do point
        get(by_id, point.cell_id) do
            error("MIMICS-C boundary reference lacks cell $(point.cell_id)")
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
            eligible = findall(point -> point.cell_id ∉ excluded, grid)
            Calibration.calibration_record(
                actual[eligible],
                expected[eligible];
                units = "kg C m^-2",
                observations = [
                    (;
                        cell_id = point.cell_id,
                        pft = point.pft,
                        latitude = point.latitude,
                        longitude = point.longitude,
                    ) for point in grid[eligible]
                ],
            )
        end for
        (fortran_name, source, component, variable) in Native.BOUNDARY_VARIABLES
    )
end

function checkpoint_path(output_root, stage)
    directory = joinpath(output_root, "stages", stage, "checkpoints", stage)
    return only(
        filter(
            path -> endswith(path, ".hdf5"),
            readdir(directory; join = true),
        ),
    )
end

function write_calibration(
    source_root,
    reference_root,
    output_root,
    path;
    population_manifest_path = joinpath(
        @__DIR__,
        "validation",
        "mimics_c_boundary_population.toml",
    ),
)
    grid_path =
        joinpath(source_root, "GRID_CN", "gridinfo_igbpz_CLM5_GSWP3.csv")
    soil_path = joinpath(source_root, "GRID_CN", "gridinfo_soil_CLM5_GSWP3.csv")
    plant_path = joinpath(source_root, "GRID_CN", "pftlookup_igbp_updated4.csv")
    mimics_path = joinpath(
        source_root,
        "GRID_CN",
        "MIMICS_mod5_GSWP3_KO4_push",
        "pftlookup_LIDET-MIM-REV_CN_desorb2xKO4_micCN_FI30.csv",
    )
    grid = Native.casa().read_grid(grid_path)
    length(grid) == 4263 ||
        error("MIMICS-C boundary calibration requires 4,263 grid cells")
    cell_ids = getproperty.(grid, :cell_id)
    contract =
        population_contract(population_manifest_path, grid_path, cell_ids)
    soils = Native.casa().read_soils(soil_path)
    domain = Native.casa().gridded_domain(length(grid))
    buffers = Native.MIMICSBuffers(domain)
    built = Native.build_gridded_model(
        grid,
        soils,
        plant_path,
        mimics_path,
        buffers;
        domain,
    )
    variables = Dict{String, Any}()
    sources = Dict{String, Any}()
    for stage in ("prespin", "spin", "historical")
        checkpoint = checkpoint_path(output_root, stage)
        state, _ = ClimaLand.read_checkpoint(checkpoint; model = built.model)
        directory = STAGE_DIRECTORIES[stage]
        casa_path =
            joinpath(reference_root, "stages", directory, "casa_final.csv")
        mimics_reference =
            joinpath(reference_root, "stages", directory, "mimics_final.csv")
        variables[stage] = boundary_values(
            state,
            casa_path,
            mimics_reference,
            grid,
            contract.excluded,
        )
        sources[stage] = Dict(
            "checkpoint" => source_record(checkpoint),
            "fresh_fortran_casa" => source_record(casa_path),
            "fresh_fortran_mimics" => source_record(mimics_reference),
            "fresh_fortran_grid" =>
                source_record(joinpath(dirname(casa_path), "grid.csv")),
        )
    end
    repo_root = normpath(joinpath(@__DIR__, "..", ".."))
    fortran_workflow_path =
        joinpath(reference_root, "configuration", "workflow.toml")
    fortran_workflow = TOML.parsefile(fortran_workflow_path)
    document = Dict(
        "schema_version" => 1,
        "calibration_id" => "mimics-c-current-julia-fresh-fortran-full-grid-boundary-v2",
        "model" => "MIMICS-C",
        "source" => "fresh_fortran_full_grid",
        "cell_count" => 4263,
        "eligible_cell_count" => 4263 - length(contract.excluded),
        "units" => "kg C m^-2",
        "reviewed_exclusion" => contract.gaps,
        "method" => Calibration.calibration_method(),
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
                    joinpath(@__DIR__, "mimics_c_calibration.jl"),
                    repo_root,
                ),
                "sha256" => sha256sum(
                    joinpath(@__DIR__, "mimics_c_calibration.jl"),
                ),
            ),
            "population_manifest" => Dict(
                "id" => relpath(population_manifest_path, repo_root),
                "sha256" => sha256sum(population_manifest_path),
            ),
            "population" => Dict(
                "label" => contract.population["label"],
                "cell_count" => contract.population["cell_count"],
                "eligible_cell_count" =>
                    contract.population["eligible_cell_count"],
                "cell_ids_sha256" => contract.population["cell_ids_sha256"],
                "grid_sha256" => contract.population["grid_sha256"],
            ),
            "grid" => source_record(grid_path),
            "casa_parameters" => source_record(plant_path),
            "mimics_parameters" => source_record(mimics_path),
            "fresh_fortran_build" => source_record(
                joinpath(reference_root, "build", "build_metadata.toml"),
            ),
            "fresh_fortran_workflow" => merge(
                Dict("source_revision" => fortran_workflow["source_commit"]),
                source_record(fortran_workflow_path),
            ),
            "stage" => sources,
        ),
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
    length(args) == 4 || error(
        "usage: generate_mimics_c_boundary_calibration.jl SOURCE_ROOT FORTRAN_ROOT JULIA_OUTPUT_ROOT OUTPUT_PATH",
    )
    return write_calibration(args...)
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    GenerateMIMICSCBoundaryCalibration.main()
end
