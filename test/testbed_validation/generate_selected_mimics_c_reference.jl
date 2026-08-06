import SHA
import TOML

import NCDatasets

if !isdefined(@__MODULE__, :TestbedSelectedMIMICSCWorkflow)
    include(joinpath(@__DIR__, "selected_mimics_c_workflow.jl"))
end

module GenerateSelectedMIMICSCReference

import SHA
import TOML

import NCDatasets

const Workflow =
    getfield(parentmodule(@__MODULE__), :TestbedSelectedMIMICSCWorkflow)
const Native =
    getfield(parentmodule(@__MODULE__), :TestbedNativeMIMICSCReconstruction)
const Cells =
    getfield(parentmodule(@__MODULE__), :TestbedReferenceCellComparisons)
const Fixtures =
    getfield(parentmodule(@__MODULE__), :TestbedSelectedCellFixtures)

const STAGE_DIRECTORIES = Dict(
    "prespin" => "01-prespin",
    "spin" => "02-spin",
    "historical" => "03-historical",
)

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

source_record(id, path) = Dict("id" => id, "sha256" => sha256sum(path))

function source_indices(fortran_root, cell_ids)
    rows = Native.casa().parse_rows(
        joinpath(fortran_root, "stages", "01-prespin", "grid.csv"),
    )
    by_id = Dict(
        parse(Int, strip(row.ijcam)) => index for
        (index, row) in enumerate(rows)
    )
    return map(cell_ids) do cell_id
        haskey(by_id, cell_id) ||
            error("MIMICS-C Fortran grid has no requested cell $cell_id")
        by_id[cell_id]
    end
end

"""
    reference_grid(fortran_root, grid)

Replace global grid indices with the packed indices the Fortran run wrote.

The Representative run packs its 80 cells along `lon` with a singleton `lat`,
so reading its output by global index is out of bounds.
"""
function reference_grid(fortran_root, grid)
    rows = Native.casa().parse_rows(
        joinpath(fortran_root, "stages", "01-prespin", "grid.csv"),
    )
    by_id = Dict(parse(Int, strip(row.ijcam)) => row for row in rows)
    return map(grid) do point
        row = get(by_id, point.cell_id) do
            error(
                "MIMICS-C Fortran grid has no requested cell $(point.cell_id)",
            )
        end
        merge(
            point,
            (
                longitude_index = parse(Int, strip(row.ilon)),
                latitude_index = parse(Int, strip(row.ilat)),
            ),
        )
    end
end

function finite_vector(values, eligible_positions, location)
    any(ismissing, values) &&
        error("MIMICS-C Fortran oracle is missing $location")
    result = vec(Float64.(values))
    all(isfinite, result[eligible_positions]) ||
        error("MIMICS-C Fortran oracle is nonfinite at $location")
    return result
end

function boundary_values(fortran_root, cell_ids, eligible_positions)
    indices = source_indices(fortran_root, cell_ids)
    boundary = Dict{String, Any}()
    sources = Dict{String, Any}()
    for stage in Workflow.STAGE_NAMES
        directory = STAGE_DIRECTORIES[stage]
        casa_path =
            joinpath(fortran_root, "stages", directory, "casa_final.csv")
        mimics_path =
            joinpath(fortran_root, "stages", directory, "mimics_final.csv")
        casa_columns, casa_rows = Native.read_boundary_csv(casa_path)
        mimics_columns, mimics_rows = Native.read_boundary_csv(mimics_path)
        values = Dict{String, Any}()
        for (fortran_name, source, component, variable) in
            Native.BOUNDARY_VARIABLES
            columns, rows =
                source == :casa ? (casa_columns, casa_rows) :
                (mimics_columns, mimics_rows)
            scale = source == :casa ? 1 / 1000 : 1.0
            values["$(component).$(variable)"] = finite_vector(
                [
                    scale * parse(Float64, rows[index][columns[fortran_name]]) for
                    index in indices
                ],
                eligible_positions,
                "boundary.$stage.$fortran_name",
            )
        end
        boundary[stage] = values
        sources[stage] = Dict(
            "casa_final_sha256" => sha256sum(casa_path),
            "mimics_final_sha256" => sha256sum(mimics_path),
        )
    end
    return boundary, sources
end

function reference_dataset(root, source, year)
    prefix = source == :casa ? "casaclm" : "mimics"
    return joinpath(
        root,
        "stages",
        "03-historical",
        "$(prefix)_pool_flux_$(year)_daily.nc",
    )
end

function reference_matrix(
    dataset,
    path,
    name,
    grid,
    eligible_positions = eachindex(grid),
)
    locations = map(grid) do point
        (;
            cell_id = point.cell_id,
            lon_index = point.longitude_index,
            lat_index = point.latitude_index,
        )
    end
    selected = Fixtures.selected_values(dataset[name], locations)
    ndims(selected) == 2 || error(
        "MIMICS-C Fortran oracle has unexpected dimensions at $path:$name",
    )
    raw = permutedims(selected)
    any(ismissing, raw) &&
        error("MIMICS-C Fortran oracle is missing $path:$name")
    values = Float64.(raw)
    size(values) == (length(grid), 365) ||
        error("MIMICS-C Fortran oracle has unexpected shape at $path:$name")
    all(isfinite, values[eligible_positions, :]) ||
        error("MIMICS-C Fortran oracle is nonfinite at $path:$name")
    return values
end

function historical_values(fortran_root, grid, eligible_positions)
    points = length(grid)
    year_count = length(Workflow.HISTORICAL_YEARS)
    annual_mean = Dict(
        name => zeros(points * year_count) for
        name in Workflow.ANNUAL_STATE_NAMES
    )
    end_of_year = Dict(
        name => zeros(points * year_count) for
        name in Workflow.ANNUAL_STATE_NAMES
    )
    annual_total = Dict(
        name => zeros(points * year_count) for
        name in Workflow.ANNUAL_FLUX_NAMES
    )
    daily = Dict(name => zeros(points * 84) for name in Workflow.DAILY_NAMES)
    local_days =
        vcat((collect(start:(start + 6)) for start in (1, 91, 182, 274))...)
    sampled_years = Dict(1901 => 0, 1957 => 1, 2014 => 2)
    sources = Dict{String, String}()
    for (year_index, year) in enumerate(Workflow.HISTORICAL_YEARS)
        if year_index == 1 || year_index % 10 == 0 || year_index == year_count
            println(
                "reading fresh historical year $year ($year_index/$year_count)",
            )
            flush(stdout)
        end
        annual_destination =
            ((year_index - 1) * points + 1):(year_index * points)
        paths = Dict(
            source => reference_dataset(fortran_root, source, year) for
            source in (:casa, :mimics)
        )
        for path in values(paths)
            sources[basename(path)] = sha256sum(path)
        end
        NCDatasets.NCDataset(paths[:casa]) do casa
            NCDatasets.NCDataset(paths[:mimics]) do mimics
                for (fortran_name, source, native_name, scale) in
                    Native.HISTORICAL_VARIABLES
                    dataset = source == :casa ? casa : mimics
                    path = paths[source]
                    raw = reference_matrix(
                        dataset,
                        path,
                        fortran_name,
                        grid,
                        eligible_positions,
                    )
                    name = replace(native_name, "__" => ".")
                    if scale == 1000.0
                        annual_mean[name][annual_destination] .=
                            vec(sum(raw; dims = 2)) ./ (365 * 1000)
                        end_of_year[name][annual_destination] .=
                            vec(raw[:, 365]) ./ 1000
                    else
                        annual_total[name][annual_destination] .=
                            vec(sum(raw; dims = 2)) ./ 1000
                    end
                    haskey(sampled_years, year) || continue
                    sample = sampled_years[year]
                    daily_destination =
                        (sample * points * length(local_days) + 1):((sample + 1) * points * length(
                            local_days,
                        ))
                    canonical_scale =
                        scale == 1000.0 ? 1 / 1000 :
                        1 / (1000 * Native.DAY_SECONDS)
                    daily[name][daily_destination] .=
                        canonical_scale .* vec(raw[:, local_days])
                end
            end
        end
    end
    annual = Dict(
        "years" => collect(Workflow.HISTORICAL_YEARS),
        "annual_mean" => annual_mean,
        "end_of_year" => end_of_year,
        "annual_total" => annual_total,
    )
    samples = Dict(
        "sample_days" => Workflow.fixed_daily_sample_days(),
        "variable" => daily,
    )
    return annual, samples, sources
end

function budget_values(boundary, annual, grid, eligible_positions)
    cell_count = length(grid)
    years = length(Workflow.HISTORICAL_YEARS)
    start = zeros(cell_count)
    stop = zeros(cell_count)
    for name in Workflow.BOUNDARY_NAMES
        start .+= boundary["spin"][name]
        stop .+= boundary["historical"][name]
    end
    annual_total = annual["annual_total"]
    npp = reshape(annual_total["diagnostic.cnpp"], cell_count, years)
    respiration = reshape(
        annual_total["diagnostic.mimics_respiration"],
        cell_count,
        years,
    )
    residual_per_area = stop .- start .- vec(sum(npp .- respiration; dims = 2))
    residual_kg = getproperty.(grid, :area_m2) .* residual_per_area
    return Dict(
        "units" => "kg C",
        "reducer" => "maximum_absolute_residual",
        "maximum_absolute_residual_kg_c" =>
            maximum(abs, residual_kg[eligible_positions]),
        "historical_residual_kg_c" => residual_kg,
    )
end

function write_reference(
    collection,
    scope_manifest_path,
    fortran_root,
    path;
    build_metadata_path = joinpath(
        fortran_root,
        "build",
        "build_metadata.toml",
    ),
)
    cell_ids = Int.(getproperty.(collection.cells, :id))
    length(cell_ids) == 80 ||
        error("Representative MIMICS-C oracle requires exactly 80 cells")
    scope = TOML.parsefile(scope_manifest_path)
    Int.(scope["cell_ids"]) == cell_ids ||
        error("MIMICS-C oracle collection does not match the Scope Manifest")
    gaps = [
        gap for
        gap in get(scope, "eligibility_gaps", Dict{String, Any}[]) if
        get(gap, "model", nothing) == "MIMICS-C"
    ]
    excluded = Workflow.validate_gaps(gaps, cell_ids)
    eligible_positions = findall(id -> id ∉ excluded, cell_ids)
    isempty(eligible_positions) &&
        error("MIMICS-C Scope Manifest has no eligible cells")
    grid =
        Workflow.selected_casa.selected_grid(collection.files["grid"], cell_ids)
    boundary, boundary_sources =
        boundary_values(fortran_root, cell_ids, eligible_positions)
    annual, daily, historical_sources = historical_values(
        fortran_root,
        reference_grid(fortran_root, grid),
        eligible_positions,
    )
    workflow_path = joinpath(fortran_root, "configuration", "workflow.toml")
    workflow = TOML.parsefile(workflow_path)
    fortran_grid_path =
        joinpath(fortran_root, "stages", "01-prespin", "grid.csv")
    document = Dict(
        "schema_version" => 1,
        "model" => "MIMICS-C",
        "scope" => collection.name,
        "cell_ids" => cell_ids,
        "cell" => [
            Dict(
                "cell_id" => point.cell_id,
                "latitude" => point.latitude,
                "longitude" => point.longitude,
                "pft" => point.pft,
            ) for point in grid
        ],
        "provenance" => Dict(
            "fortran_source_revision" => workflow["source_commit"],
            "generator_sha256" => sha256sum(@__FILE__),
            "scope_manifest_sha256" => sha256sum(scope_manifest_path),
            "fortran_grid" => source_record(
                "stages/01-prespin/grid.csv",
                fortran_grid_path,
            ),
            "fixture_grid" => source_record(
                "selected_cell_fixture_grid",
                collection.files["grid"],
            ),
            "fortran_workflow" => source_record(
                "configuration/workflow.toml",
                workflow_path,
            ),
            "fortran_build_sha256" => sha256sum(build_metadata_path),
            "boundary_source_sha256" => boundary_sources,
            "fresh_historical_source_sha256" => historical_sources,
        ),
        "oracle" => Dict(
            "boundary" => boundary,
            "annual" => annual,
            "daily" => daily,
            "budget" => budget_values(
                boundary,
                annual,
                grid,
                eligible_positions,
            ),
        ),
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
    length(args) in (4, 5) || error(
        "usage: generate_selected_mimics_c_reference.jl FIXTURE_MANIFEST SCOPE_MANIFEST FORTRAN_ROOT OUTPUT_PATH [BUILD_METADATA]",
    )
    fixture_manifest, scope_manifest, fortran_root, output_path = args
    scope = TOML.parsefile(scope_manifest)
    collection = Cells.selected_cell_collection(
        String(scope["name"]),
        Int.(scope["cell_ids"]);
        manifest_path = fixture_manifest,
    )
    return write_reference(
        collection,
        scope_manifest,
        fortran_root,
        output_path,
        ;
        build_metadata_path = length(args) == 5 ? args[5] : joinpath(
            fortran_root,
            "build",
            "build_metadata.toml",
        ),
    )
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    GenerateSelectedMIMICSCReference.main()
end
