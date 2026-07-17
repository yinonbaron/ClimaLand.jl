module TestbedSelectedCellFixtures

import SHA
import Test
import TOML

import NCDatasets

# ============================================================================
# Selection
# ============================================================================

const DISTRIBUTIONS = (
    (:mean_gpp, "mean GPP"),
    (:mean_temperature, "mean soil temperature"),
    (:mean_moisture, "mean liquid moisture"),
    (:mean_nitrogen_deposition, "mean nitrogen deposition"),
    (:clay, "clay fraction"),
    (:silt, "silt fraction"),
    (:porosity, "porosity"),
)
const FORCING_VARIABLES =
    ("xtairk", "ndep", "xcgpp", "xtsoil", "xmoist", "xfrznmoist")
const NON_VEGETATED_PFTS = (13, 15, 17)

function add_reason!(selected, candidate, reason)
    reasons = get!(selected, candidate.cell_id, String[])
    reason in reasons || push!(reasons, reason)
    return nothing
end

function maximum_candidate(candidates, field)
    return first(
        sort(
            candidates;
            by = candidate ->
                (-getproperty(candidate, field), candidate.cell_id),
        ),
    )
end

function quantile_candidate(candidates, field, fraction)
    ordered = sort(
        candidates;
        by = candidate ->
            (getproperty(candidate, field), candidate.cell_id),
    )
    index = round(Int, 1 + fraction * (length(ordered) - 1))
    return ordered[index]
end

function materialize_selection(candidates, selected)
    by_id = Dict(candidate.cell_id => candidate for candidate in candidates)
    return map(sort!(collect(keys(selected)))) do cell_id
        merge(by_id[cell_id], (; reasons = sort!(selected[cell_id])))
    end
end

"""
    select_fixture_cells(candidates, boundary)

Select deterministic core and extended fixture cells with recorded reasons.
"""
function select_fixture_cells(candidates, boundary)
    productive = sort(
        filter(
            candidate ->
                candidate.mean_gpp > 0 &&
                    candidate.pft ∉ NON_VEGETATED_PFTS,
            candidates,
        );
        by = candidate -> candidate.cell_id,
    )
    isempty(productive) && error("No productive fixture candidates were found")
    core = Dict{Int, Vector{String}}()
    extended = Dict{Int, Vector{String}}()

    woody = filter(candidate -> candidate.pft <= 8, productive)
    nonwoody = filter(candidate -> 9 <= candidate.pft <= 14, productive)
    isempty(woody) || add_reason!(
        core,
        maximum_candidate(woody, :mean_gpp),
        "productive woody vegetation",
    )
    isempty(nonwoody) || add_reason!(
        core,
        maximum_candidate(nonwoody, :mean_gpp),
        "productive non-woody vegetation",
    )
    for (field, label) in (DISTRIBUTIONS[2:3]..., DISTRIBUTIONS[5:6]...)
        add_reason!(
            core,
            quantile_candidate(productive, field, 0.1),
            "low $label",
        )
        add_reason!(
            core,
            quantile_candidate(productive, field, 0.9),
            "high $label",
        )
    end
    add_reason!(core, boundary, "inactive ice/water boundary")

    for (cell_id, reasons) in core
        extended[cell_id] = copy(reasons)
    end
    for pft in sort!(unique(candidate.pft for candidate in productive))
        pft_candidates = filter(candidate -> candidate.pft == pft, productive)
        add_reason!(
            extended,
            maximum_candidate(pft_candidates, :mean_gpp),
            "productive representative for PFT $pft",
        )
    end
    for (field, label) in DISTRIBUTIONS
        for (fraction, region) in
            ((0.1, "low"), (0.5, "central"), (0.9, "high"))
            add_reason!(
                extended,
                quantile_candidate(productive, field, fraction),
                "$region $label",
            )
        end
    end

    all_candidates = [productive; boundary]
    core_cells = materialize_selection(all_candidates, core)
    extended_cells = materialize_selection(all_candidates, extended)
    return (;
        core = core_cells,
        extended = extended_cells,
        core_cell_ids = getproperty.(core_cells, :cell_id),
        extended_cell_ids = getproperty.(extended_cells, :cell_id),
    )
end

# ============================================================================
# NetCDF extraction and audit
# ============================================================================

"""
    source_cell_locations(path, cell_ids)

Resolve global cell IDs to source longitude and latitude indices. Called from
the extraction and round-trip audit paths.
"""
function source_cell_locations(path, cell_ids)
    return NCDatasets.NCDataset(path) do dataset
        source_ids = dataset["cellid"][:, :]
        map(cell_ids) do cell_id
            index = findfirst(==(cell_id), source_ids)
            isnothing(index) && error("Cell $cell_id was not found in $path")
            (; cell_id, lon_index = index[1], lat_index = index[2])
        end
    end
end

"""
    selected_values(variable, locations)

Pack one source variable at scattered locations into a trailing cell
dimension. Called from [`selected_year`](@ref).
"""
function selected_values(variable, locations)
    dimensions = String.(NCDatasets.dimnames(variable))
    values = map(locations) do location
        indices = map(dimensions) do dimension
            dimension == "lon" && return location.lon_index
            dimension == "lat" && return location.lat_index
            return Colon()
        end
        Array(variable[indices...])
    end
    return cat(values...; dims = ndims(first(values)) + 1)
end

"""
    selected_year(path, locations)

Read every forcing variable at `locations` for one source year. Called from
[`extract_forcing_fixture`](@ref) and [`audit_forcing_fixture`](@ref).
"""
function selected_year(path, locations)
    return NCDatasets.NCDataset(path) do dataset
        Dict(
            name => selected_values(dataset[name], locations) for
            name in FORCING_VARIABLES
        )
    end
end

"""
    define_like(destination, name, source, dimensions)

Define a packed variable with the source type and attributes. Called from
[`write_forcing_fixture`](@ref).
"""
function define_like(destination, name, source, dimensions)
    attributes = Dict(source.attrib)
    fillvalue = pop!(attributes, "_FillValue", nothing)
    return NCDatasets.defVar(
        destination,
        name,
        eltype(source.var),
        dimensions;
        attrib = attributes,
        fillvalue,
        deflatelevel = 3,
    )
end

function static_cell_values(dataset, name, locations)
    variable = dataset[name]
    return map(locations) do location
        variable[location.lon_index, location.lat_index]
    end
end

"""
    selected_static_values(path, locations)

Read source coordinates, masks, and cell IDs at `locations`. Called from
[`extract_forcing_fixture`](@ref) and [`audit_forcing_fixture`](@ref).
"""
function selected_static_values(path, locations)
    return NCDatasets.NCDataset(path) do dataset
        Dict(
            "cellid" => Int32[
                dataset["cellid"][location.lon_index, location.lat_index]
                for location in locations
            ],
            "lon" =>
                [dataset["lon"][location.lon_index] for location in locations],
            "lat" =>
                [dataset["lat"][location.lat_index] for location in locations],
            "landfrac" => static_cell_values(dataset, "landfrac", locations),
            "cellMissing" =>
                static_cell_values(dataset, "cellMissing", locations),
        )
    end
end

"""
    audit_source_selection(path, locations, data; static = nothing)

Compare selected arrays to independent direct source indexing. Called from
[`extract_forcing_fixture`](@ref).
"""
function audit_source_selection(path, locations, data; static = nothing)
    return NCDatasets.NCDataset(path) do dataset
        for name in FORCING_VARIABLES
            variable = dataset[name]
            for (cell_index, location) in enumerate(locations)
                indices = ntuple(ndims(variable)) do dimension
                    dimension == 1 && return location.lon_index
                    dimension == 2 && return location.lat_index
                    return Colon()
                end
                expected = Array(variable[indices...])
                actual = selectdim(data[name], ndims(data[name]), cell_index)
                isequal(actual, expected) || return false
            end
        end
        isnothing(static) && return true
        for (cell_index, location) in enumerate(locations)
            static["cellid"][cell_index] ==
            dataset["cellid"][location.lon_index, location.lat_index] ||
                return false
            static["lon"][cell_index] == dataset["lon"][location.lon_index] ||
                return false
            static["lat"][cell_index] == dataset["lat"][location.lat_index] ||
                return false
            for name in ("landfrac", "cellMissing")
                static[name][cell_index] ==
                dataset[name][location.lon_index, location.lat_index] ||
                    return false
            end
        end
        return true
    end
end

"""
    fixture_indices(variable, time_indices)

Build indices that select `time_indices` and retain every other dimension.
Called from the forcing writer and round-trip audit.
"""
function fixture_indices(variable, time_indices)
    return Tuple(
        dimension == "time" ? time_indices : Colon() for
        dimension in String.(NCDatasets.dimnames(variable))
    )
end

"""
    write_forcing_fixture(source_paths, destination_path, locations, yearly_data, static)

Pack audited yearly arrays into one selected-cell NetCDF file. Called from
[`extract_forcing_fixture`](@ref).
"""
function write_forcing_fixture(
    source_paths,
    destination_path,
    locations,
    yearly_data,
    static,
)
    years = map(source_paths) do path
        NCDatasets.NCDataset(path) do dataset
            Int(dataset["year"][1])
        end
    end
    day_counts = map(source_paths) do path
        NCDatasets.NCDataset(path) do dataset
            Int(dataset.dim["time"])
        end
    end
    NCDatasets.NCDataset(first(source_paths)) do source
        NCDatasets.NCDataset(
            destination_path,
            "c";
            format = :netcdf4,
        ) do fixture
            NCDatasets.defDim(fixture, "cell", length(locations))
            NCDatasets.defDim(fixture, "time", sum(day_counts))
            NCDatasets.defDim(fixture, "year", length(years))
            for (name, dimension) in source.dim
                name in ("lon", "lat", "time", "myear") && continue
                NCDatasets.defDim(fixture, String(name), Int(dimension))
            end
            for (name, value) in source.attrib
                fixture.attrib[name] = value
            end
            fixture.attrib["packing"] = "selected lon/lat cells packed into the cell dimension; values unchanged"

            cellid = NCDatasets.defVar(fixture, "cellid", Int32, ("cell",))
            cellid[:] = static["cellid"]
            source_lon =
                NCDatasets.defVar(fixture, "source_lon_index", Int32, ("cell",))
            source_lon[:] = Int32.(getproperty.(locations, :lon_index))
            source_lat =
                NCDatasets.defVar(fixture, "source_lat_index", Int32, ("cell",))
            source_lat[:] = Int32.(getproperty.(locations, :lat_index))
            lon = define_like(fixture, "lon", source["lon"], ("cell",))
            lon[:] = static["lon"]
            lat = define_like(fixture, "lat", source["lat"], ("cell",))
            lat[:] = static["lat"]
            for name in ("landfrac", "cellMissing")
                variable = define_like(fixture, name, source[name], ("cell",))
                variable[:] = static[name]
            end
            year = NCDatasets.defVar(fixture, "year", Int32, ("year",))
            year[:] = Int32.(years)
            year_start =
                NCDatasets.defVar(fixture, "year_start_index", Int32, ("year",))
            year_start[:] = Int32.(cumsum([1; day_counts[1:(end - 1)]]))
            time = NCDatasets.defVar(fixture, "time", Int32, ("time",))
            time[:] = Int32.(0:(sum(day_counts) - 1))
            time.attrib["units"] = "days since $(first(years))-01-01"
            time.attrib["calendar"] = "noleap"

            for name in FORCING_VARIABLES
                source_dimensions =
                    collect(String.(NCDatasets.dimnames(source[name])))
                dimensions = Tuple(
                    vcat(
                        filter(
                            dimension ->
                                dimension != "lon" && dimension != "lat",
                            source_dimensions,
                        ),
                        ["cell"],
                    ),
                )
                define_like(fixture, name, source[name], dimensions)
            end
            offset = 0
            for (data, day_count) in zip(yearly_data, day_counts)
                days = (offset + 1):(offset + day_count)
                for name in FORCING_VARIABLES
                    variable = fixture[name]
                    variable[fixture_indices(variable, days)...] = data[name]
                end
                offset += day_count
            end
        end
    end
    return destination_path
end

"""
    audit_forcing_fixture(source_paths, fixture_path)

Check packed forcing values, coordinates, masks, and source indices exactly.
"""
function audit_forcing_fixture(source_paths, fixture_path)
    return NCDatasets.NCDataset(fixture_path) do fixture
        cell_ids = Int.(fixture["cellid"][:])
        locations = source_cell_locations(first(source_paths), cell_ids)
        fixture["source_lon_index"][:] ==
        Int32.(getproperty.(locations, :lon_index)) || return false
        fixture["source_lat_index"][:] ==
        Int32.(getproperty.(locations, :lat_index)) || return false
        static = selected_static_values(first(source_paths), locations)
        for name in ("cellid", "lon", "lat", "landfrac", "cellMissing")
            isequal(fixture[name][:], static[name]) || return false
        end
        offset = 0
        for path in source_paths
            data = selected_year(path, locations)
            day_count = size(data[first(FORCING_VARIABLES)], 1)
            days = (offset + 1):(offset + day_count)
            for name in FORCING_VARIABLES
                actual = fixture[name][fixture_indices(fixture[name], days)...]
                isequal(actual, data[name]) || return false
            end
            offset += day_count
        end
        return offset == fixture.dim["time"]
    end
end

"""
    extract_forcing_fixture(source_paths, destination_path, cell_ids)

Extract selected cells after an independent exact source-selection audit.
"""
function extract_forcing_fixture(source_paths, destination_path, cell_ids)
    locations = source_cell_locations(first(source_paths), cell_ids)
    static = selected_static_values(first(source_paths), locations)
    yearly_data = map(source_paths) do path
        data = selected_year(path, locations)
        audit_source_selection(
            path,
            locations,
            data;
            static = path == first(source_paths) ? static : nothing,
        ) || error("Source selection audit failed for $path")
        data
    end
    write_forcing_fixture(
        source_paths,
        destination_path,
        locations,
        yearly_data,
        static,
    )
    fixture_roundtrip_exact =
        audit_forcing_fixture(source_paths, destination_path)
    fixture_roundtrip_exact || error("Forcing fixture round-trip audit failed")
    return (; source_selection_exact = true, fixture_roundtrip_exact)
end

# ============================================================================
# Archive-independent loading
# ============================================================================

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

"""
    verified_fixture_paths(manifest_path, manifest)

Resolve fixture files after checking their recorded sizes and hashes. Called
from [`load_selected_cell_fixture`](@ref).
"""
function verified_fixture_paths(manifest_path, manifest)
    directory = dirname(manifest_path)
    return Dict(
        map(collect(manifest["fixture"])) do (name, description)
            path = joinpath(directory, description["filename"])
            isfile(path) || error("Fixture file is missing: $path")
            filesize(path) == description["bytes"] ||
                error("Fixture size mismatch: $path")
            sha256sum(path) == description["sha256"] ||
                error("Fixture checksum mismatch: $path")
            String(name) => path
        end,
    )
end

"""
    load_selected_cell_fixture(callback, manifest_path; tier = :core)

Verify fixture hashes, open the packed forcing, and call `callback` with a
named tuple containing the selected tier and its file paths.

# Arguments
- `callback`: Consume the verified fixture while its NetCDF dataset is open.
- `manifest_path`: Point to the committed or regenerated fixture manifest.

# Keyword Arguments
- `tier`: Select `:core` or `:extended`; defaults to `:core`.

# Returns
Return the value produced by `callback`.

# Examples
```julia
include("test/testbed_validation/selected_cell_fixtures.jl")
using .TestbedSelectedCellFixtures

manifest = "test/testbed_validation/fixtures/selected_cells/fixture.toml"
TestbedSelectedCellFixtures.load_selected_cell_fixture(manifest; tier = :core) do fixture
    fixture.cell_ids
end
```

See also [`build_selected_cell_fixture`](@ref).
"""
function load_selected_cell_fixture(callback, manifest_path; tier = :core)
    tier in (:core, :extended) ||
        error("Fixture tier must be :core or :extended")
    manifest = TOML.parsefile(manifest_path)
    files = verified_fixture_paths(manifest_path, manifest)
    cell_ids = Int.(manifest["selection"]["$(tier)_cell_ids"])
    return NCDatasets.NCDataset(files["forcing"]) do forcing
        fixture_ids = Int.(forcing["cellid"][:])
        cell_indices = map(cell_ids) do cell_id
            index = findfirst(==(cell_id), fixture_ids)
            isnothing(index) &&
                error("Cell $cell_id is missing from the forcing fixture")
            index
        end
        callback((; manifest, files, forcing, cell_ids, cell_indices))
    end
end


# ============================================================================
# Source verification and manifest
# ============================================================================

"""
    md5sum(path)

Return a file's MD5 with the available platform command. Called from
[`build_selected_cell_fixture`](@ref).
"""
function md5sum(path)
    executable = something(Sys.which("md5sum"), Sys.which("md5"), nothing)
    isnothing(executable) && error("Neither md5sum nor md5 is available")
    arguments =
        basename(executable) == "md5" ? [executable, "-q", path] :
        [executable, path]
    return first(split(read(Cmd(arguments), String)))
end

"""
    update_hash!(context, io)

Stream `io` into a SHA context with bounded memory. Called from the archive
and extracted-file hash helpers.
"""
function update_hash!(context, io)
    buffer = Vector{UInt8}(undef, 1024 * 1024)
    while !eof(io)
        count = readbytes!(io, buffer)
        count == 0 && break
        SHA.update!(context, @view(buffer[1:count]))
    end
    return context
end

"""
    sha256_stream(io)

Return the SHA-256 of a byte stream. Called from [`verify_archive_members`](@ref).
"""
function sha256_stream(io)
    context = update_hash!(SHA.SHA256_CTX(), io)
    return bytes2hex(SHA.digest!(context))
end

"""
    sha256_files(paths)

Return the SHA-256 of files concatenated in order. Called from
[`verify_archive_members`](@ref).
"""
function sha256_files(paths)
    context = SHA.SHA256_CTX()
    for path in paths
        open(path) do io
            update_hash!(context, io)
        end
    end
    return bytes2hex(SHA.digest!(context))
end

"""
    verify_archive_members(archive_path, source_paths)

Prove extracted forcing bytes match the corresponding verified archive
members. Called from [`build_selected_cell_fixture`](@ref).
"""
function verify_archive_members(archive_path, source_paths)
    executable = something(Sys.which("tar"), nothing)
    isnothing(executable) && error("tar is required to verify archive members")
    forcing_root = dirname(first(source_paths))
    requested = Dict(
        joinpath(basename(forcing_root), basename(path)) => path for
        path in source_paths
    )
    listing = split(read(Cmd([executable, "-tzf", archive_path]), String))
    members = filter(member -> haskey(requested, member), listing)
    Set(members) == Set(keys(requested)) ||
        error("The forcing archive is missing required members")
    command = Cmd(vcat([executable, "-xOzf", archive_path], members))
    archived_hash = open(command, "r") do io
        sha256_stream(io)
    end
    extracted_hash = sha256_files([requested[member] for member in members])
    archived_hash == extracted_hash ||
        error("Extracted forcing files do not match the verified archive")
    return archived_hash
end

"""
    verify_repository_inputs(source_root, source_commit, source_paths)

Prove copied testbed inputs match their blobs at `source_commit`. Called from
[`build_selected_cell_fixture`](@ref).
"""
function verify_repository_inputs(source_root, source_commit, source_paths)
    executable = something(Sys.which("git"), nothing)
    isnothing(executable) && error("git is required to verify source inputs")
    head = strip(
        read(Cmd([executable, "-C", source_root, "rev-parse", "HEAD"]), String),
    )
    head == source_commit || error("Source checkout is not at $source_commit")
    for path in source_paths
        relative = relpath(path, source_root)
        committed = read(
            Cmd([
                executable,
                "-C",
                source_root,
                "show",
                "$source_commit:$relative",
            ]),
        )
        read(path) == committed ||
            error("Source input differs from $source_commit: $relative")
    end
    return true
end

"""
    csv_rows(path)

Index raw CSV rows by global cell ID. Called by static metadata extraction.
"""
function csv_rows(path)
    lines = readlines(path)
    rows = Dict{Int, String}()
    for line in lines[2:end]
        fields = split(line, ','; keepempty = true)
        isempty(fields) && continue
        cell_id = tryparse(Int, strip(first(fields)))
        isnothing(cell_id) || (rows[cell_id] = line)
    end
    return (; header = first(lines), rows)
end

"""
    grid_metadata(path)

Parse selected grid fields used by candidate construction. Called from
[`fixture_candidates`](@ref).
"""
function grid_metadata(path)
    table = csv_rows(path)
    return Dict(
        map(collect(table.rows)) do (cell_id, line)
            fields = split(line, ','; keepempty = true)
            cell_id => (;
                latitude = parse(Float64, strip(fields[2])),
                longitude = parse(Float64, strip(fields[3])),
                pft = parse(Int, strip(fields[4])),
            )
        end,
    )
end

"""
    soil_metadata(path)

Parse soil texture fields used by candidate construction. Called from
[`fixture_candidates`](@ref).
"""
function soil_metadata(path)
    table = csv_rows(path)
    return Dict(
        map(collect(table.rows)) do (cell_id, line)
            fields = split(line, ','; keepempty = true)
            cell_id => (;
                sand = parse(Float64, strip(fields[4])),
                clay = parse(Float64, strip(fields[5])),
                silt = parse(Float64, strip(fields[6])),
                wilting_point = parse(Float64, strip(fields[7])),
                field_capacity = parse(Float64, strip(fields[8])),
                porosity = parse(Float64, strip(fields[9])),
            )
        end,
    )
end

"""
    write_selected_csv(source_path, destination_path, cell_ids)

Write exact static rows for selected cells and audit their text. Called from
[`build_selected_cell_fixture`](@ref).
"""
function write_selected_csv(source_path, destination_path, cell_ids)
    table = csv_rows(source_path)
    selected = [table.rows[cell_id] for cell_id in cell_ids]
    open(destination_path, "w") do io
        println(io, table.header)
        foreach(line -> println(io, line), selected)
    end
    written = csv_rows(destination_path)
    all(cell_id -> written.rows[cell_id] == table.rows[cell_id], cell_ids) ||
        error("CSV fixture failed its exact row audit: $destination_path")
    return destination_path
end

"""
    spatial_sum_and_count(dataset, name)

Reduce one forcing variable over all nonspatial dimensions. Called from
[`forcing_metrics`](@ref).
"""
function spatial_sum_and_count(dataset, name)
    variable = dataset[name]
    dimensions = String.(NCDatasets.dimnames(variable))
    dimensions[1:2] == ("lon", "lat") ||
        error("Unexpected dimensions for $name: $dimensions")
    indices = ntuple(_ -> Colon(), ndims(variable))
    values = variable.var[indices...]
    reduced_dimensions = Tuple(3:ndims(values))
    sums = dropdims(
        sum(Float64, values; dims = reduced_dimensions);
        dims = reduced_dimensions,
    )
    return sums,
    prod(size(values, dimension) for dimension in reduced_dimensions)
end

"""
    forcing_metrics(source_paths, locations)

Compute full-period driver means used by deterministic selection. Called from
[`fixture_candidates`](@ref).
"""
function forcing_metrics(source_paths, locations)
    metric_variables = (
        mean_gpp = "xcgpp",
        mean_temperature = "xtsoil",
        mean_moisture = "xmoist",
        mean_nitrogen_deposition = "ndep",
    )
    sums = Dict(
        name => zeros(Float64, length(locations)) for
        name in keys(metric_variables)
    )
    counts = Dict(name => 0 for name in keys(metric_variables))
    for (file_index, path) in enumerate(source_paths)
        NCDatasets.NCDataset(path) do dataset
            for (metric, variable) in pairs(metric_variables)
                spatial_sums, count = spatial_sum_and_count(dataset, variable)
                sums[metric] .+= map(locations) do location
                    spatial_sums[location.lon_index, location.lat_index]
                end
                counts[metric] += count
            end
        end
        (
            file_index == 1 ||
            file_index % 10 == 0 ||
            file_index == length(source_paths)
        ) && println(
            "summarized forcing year $(file_index)/$(length(source_paths))",
        )
    end
    return Dict(name => values ./ counts[name] for (name, values) in sums)
end

"""
    fixture_candidates(source_paths, grid_path, soil_path)

Build selection candidates from forcing statistics and static grid metadata.
Called from [`build_selected_cell_fixture`](@ref).
"""
function fixture_candidates(source_paths, grid_path, soil_path)
    grid = grid_metadata(grid_path)
    soils = soil_metadata(soil_path)
    locations = NCDatasets.NCDataset(first(source_paths)) do dataset
        cell_ids = dataset["cellid"][:, :]
        missing_mask = dataset["cellMissing"][:, :]
        found = NamedTuple[]
        for index in CartesianIndices(cell_ids)
            cell_id = Int(cell_ids[index])
            haskey(grid, cell_id) || continue
            haskey(soils, cell_id) || continue
            missing_mask[index] == 0 || cell_id == 51 || continue
            push!(
                found,
                (; cell_id, lon_index = index[1], lat_index = index[2]),
            )
        end
        sort!(found; by = location -> location.cell_id)
    end
    metrics = forcing_metrics(source_paths, locations)
    candidates = map(eachindex(locations)) do index
        location = locations[index]
        cell_id = location.cell_id
        soil = soils[cell_id]
        (;
            cell_id,
            pft = grid[cell_id].pft,
            mean_gpp = metrics[:mean_gpp][index],
            mean_temperature = metrics[:mean_temperature][index],
            mean_moisture = metrics[:mean_moisture][index],
            mean_nitrogen_deposition = metrics[:mean_nitrogen_deposition][index],
            clay = soil.clay,
            silt = soil.silt,
            porosity = soil.porosity,
        )
    end
    boundary_index = findfirst(candidate -> candidate.cell_id == 51, candidates)
    isnothing(boundary_index) && error("Boundary cell 51 was not found")
    boundary = candidates[boundary_index]
    deleteat!(candidates, boundary_index)
    productive = filter(candidates) do candidate
        all(
            value -> isfinite(value) && abs(value) < 1e30,
            (
                candidate.mean_gpp,
                candidate.mean_temperature,
                candidate.mean_moisture,
                candidate.mean_nitrogen_deposition,
            ),
        ) && candidate.mean_gpp > 0
    end
    return select_fixture_cells(productive, boundary)
end

"""
    fixture_description(path, license)

Record a fixture file's name, size, hash, and license. Called from
[`write_fixture_manifest`](@ref).
"""
function fixture_description(path, license)
    return Dict(
        "filename" => basename(path),
        "bytes" => filesize(path),
        "sha256" => sha256sum(path),
        "license" => license,
    )
end

"""
    copy_fixture_file(source, destination)

Copy one repository input and verify exact bytes. Called from
[`build_selected_cell_fixture`](@ref).
"""
function copy_fixture_file(source, destination)
    cp(source, destination; force = true)
    read(source) == read(destination) ||
        error("Fixture copy audit failed: $source")
    return destination
end

"""
    variable_manifest(source_path, fixture_path)

Describe forcing units, dimensions, and conversions. Called from
[`write_fixture_manifest`](@ref).
"""
function variable_manifest(source_path, fixture_path)
    return NCDatasets.NCDataset(source_path) do source
        NCDatasets.NCDataset(fixture_path) do fixture
            collect(
                map(FORCING_VARIABLES) do name
                    Dict(
                        "name" => name,
                        "units" => get(source[name].attrib, "units", ""),
                        "source_dimensions" =>
                            collect(String.(NCDatasets.dimnames(source[name]))),
                        "fixture_dimensions" => collect(
                            String.(NCDatasets.dimnames(fixture[name])),
                        ),
                        "conversion" => "none; values and storage type retained exactly",
                    )
                end,
            )
        end
    end
end

"""
    write_fixture_manifest(destination, selection, fixture_files, source_paths,
                           driver_archive, source_commit,
                           archive_members_sha256, audit)

Record selection, provenance, licensing, conversion, and fixture hashes.
Called from [`build_selected_cell_fixture`](@ref).
"""
function write_fixture_manifest(
    destination,
    selection,
    fixture_files,
    source_paths,
    driver_archive,
    source_commit,
    archive_members_sha256,
    audit,
)
    forcing_path = fixture_files["forcing"]
    cells = map(selection.extended) do cell
        Dict(
            "id" => cell.cell_id,
            "pft" => cell.pft,
            "core" => cell.cell_id in selection.core_cell_ids,
            "reasons" => cell.reasons,
            "mean_gpp_gC_m2_day" => cell.mean_gpp,
            "mean_soil_temperature_K" => cell.mean_temperature,
            "mean_liquid_moisture_m3_m3" => cell.mean_moisture,
            "mean_nitrogen_deposition_gN_m2_day" =>
                cell.mean_nitrogen_deposition,
            "clay_fraction" => cell.clay,
            "silt_fraction" => cell.silt,
            "porosity" => cell.porosity,
        )
    end
    manifest = Dict(
        "schema_version" => 1,
        "title" => "Stratified CLM5/GSWP3 selected-cell workflow fixture",
        "license" => Dict(
            "driver_dataset" => "CC-BY-4.0",
            "testbed_repository_inputs" => "MIT",
        ),
        "selection" => Dict(
            "method" => "non-vegetated PFTs 13, 15, and 17 excluded; deterministic PFT maxima plus nearest 0.1, 0.5, and 0.9 empirical quantiles; ties use the lowest global cell ID",
            "statistics_period" => "1901-2014",
            "core_cell_ids" => selection.core_cell_ids,
            "extended_cell_ids" => selection.extended_cell_ids,
            "code" => basename(@__FILE__),
            "code_sha256" => sha256sum(@__FILE__),
        ),
        "source" => Dict(
            "archive" => driver_archive,
            "repository" => "https://github.com/wwieder/biogeochem_testbed.git",
            "repository_commit" => source_commit,
            "dataset_doi" => "10.5065/jqts-cg20",
            "archive_md5_verified" => true,
            "archive_members_match_extracted_sources" => true,
            "archive_members_sha256" => archive_members_sha256,
            "repository_inputs_match_commit" => true,
        ),
        "time" => Dict(
            "start_year" => 1901,
            "end_year" => 2014,
            "calendar" => "noleap",
            "days" => 114 * 365,
            "conversion" => "yearly 365-day source dimensions concatenated; zero-based day coordinate added",
        ),
        "audit" => Dict(
            "source_selection_exact_before_repacking" =>
                audit.source_selection_exact,
            "fixture_roundtrip_exact" => audit.fixture_roundtrip_exact,
            "static_rows_exact" => true,
            "copied_inputs_exact" => true,
        ),
        "fixture" => Dict(
            name => fixture_description(
                path,
                name == "forcing" ? "CC-BY-4.0" : "MIT",
            ) for (name, path) in fixture_files
        ),
        "variable" => variable_manifest(first(source_paths), forcing_path),
        "cell" => cells,
    )
    path = joinpath(destination, "fixture.toml")
    open(path, "w") do io
        TOML.print(io, manifest; sorted = true)
    end
    return path
end

# ============================================================================
# Fixture builder
# ============================================================================

"""
    build_selected_cell_fixture(data_root, source_root, destination)

Build both selected-cell tiers from a verified driver archive and pinned source
checkout, then write their archive-independent manifest.

# Arguments
- `data_root`: Contain the verified archive and its extracted forcing directory.
- `source_root`: Point to the pinned biogeochemical-testbed Git checkout.
- `destination`: Receive the packed forcing, static inputs, and manifest.

# Returns
Return the generated manifest path.

# Examples
```julia
include("test/testbed_validation/selected_cell_fixtures.jl")
using .TestbedSelectedCellFixtures

TestbedSelectedCellFixtures.build_selected_cell_fixture(
    "/data/testbed",
    "/src/biogeochem_testbed",
    "test/testbed_validation/fixtures/selected_cells",
)
```

See also [`load_selected_cell_fixture`](@ref).
"""
function build_selected_cell_fixture(data_root, source_root, destination)
    experiment_manifest = TOML.parsefile(joinpath(@__DIR__, "experiments.toml"))
    driver_archive = only(
        filter(
            item -> item["id"] == "drivers",
            experiment_manifest["artifact"],
        ),
    )
    archive_path = joinpath(data_root, driver_archive["filename"])
    isfile(archive_path) || error("Driver archive is missing: $archive_path")
    filesize(archive_path) == driver_archive["bytes"] ||
        error("Driver archive size mismatch: $archive_path")
    md5sum(archive_path) == driver_archive["md5"] ||
        error("Driver archive checksum mismatch: $archive_path")

    forcing_root = joinpath(data_root, "INPUT_GSWP3_CLM5dev110_hist")
    source_paths =
        [joinpath(forcing_root, "met_$(year)_$(year).nc") for year in 1901:2014]
    all(isfile, source_paths) ||
        error("The 1901-2014 forcing files are incomplete")
    archive_members_sha256 = verify_archive_members(archive_path, source_paths)
    grid_path =
        joinpath(source_root, "GRID_CN", "gridinfo_igbpz_CLM5_GSWP3.csv")
    soil_path = joinpath(source_root, "GRID_CN", "gridinfo_soil_CLM5_GSWP3.csv")
    selection = fixture_candidates(source_paths, grid_path, soil_path)
    mkpath(destination)
    forcing_fixture = joinpath(destination, "forcing_1901_2014.nc")
    fixture_ids =
        isfile(forcing_fixture) ?
        NCDatasets.NCDataset(forcing_fixture) do dataset
            Int.(dataset["cellid"][:])
        end : Int[]
    audit = if fixture_ids == selection.extended_cell_ids
        roundtrip_exact = audit_forcing_fixture(source_paths, forcing_fixture)
        roundtrip_exact ||
            error("Existing forcing fixture failed its audit")
        (; source_selection_exact = true, fixture_roundtrip_exact = true)
    else
        extract_forcing_fixture(
            source_paths,
            forcing_fixture,
            selection.extended_cell_ids,
        )
    end
    fixture_files = Dict("forcing" => forcing_fixture)
    fixture_files["grid"] = write_selected_csv(
        grid_path,
        joinpath(destination, "grid_selected_cells.csv"),
        selection.extended_cell_ids,
    )
    fixture_files["soil"] = write_selected_csv(
        soil_path,
        joinpath(destination, "soil_selected_cells.csv"),
        selection.extended_cell_ids,
    )
    source_inputs = Dict(
        "casa_c_parameters" => joinpath(
            source_root,
            "GRID_CN",
            "pftlookup_igbp_updated4_exud0.csv",
        ),
        "casa_cn_parameters" =>
            joinpath(source_root, "GRID_CN", "pftlookup_igbp_updated4.csv"),
        "mimics_parameters" => joinpath(
            source_root,
            "GRID_CN",
            "MIMICS_mod5_GSWP3_KO4_push",
            "pftlookup_LIDET-MIM-REV_CN_desorb2xKO4_micCN_FI30.csv",
        ),
        "corpse_parameters" => joinpath(
            source_root,
            "EXAMPLE_GRID",
            "corpse_params_12.18d.2017.nml",
        ),
        "phenology" =>
            joinpath(source_root, "GRID_CN", "modis_phenology_wtundra.txt"),
        "perturbation" =>
            joinpath(source_root, "GRID_CN", "co2delta_control.txt"),
    )
    source_commit = experiment_manifest["source"]["local_checkout_commit"]
    verify_repository_inputs(
        source_root,
        source_commit,
        [grid_path, soil_path, collect(values(source_inputs))...],
    )
    for (name, source) in source_inputs
        isfile(source) || error("Workflow input is missing: $source")
        destination_path = joinpath(destination, basename(source))
        fixture_files[name] = copy_fixture_file(source, destination_path)
    end
    archive_record = Dict(
        "filename" => driver_archive["filename"],
        "bytes" => driver_archive["bytes"],
        "md5" => driver_archive["md5"],
        "url" => driver_archive["url"],
    )
    manifest_path = write_fixture_manifest(
        destination,
        selection,
        fixture_files,
        source_paths,
        archive_record,
        source_commit,
        archive_members_sha256,
        audit,
    )
    load_selected_cell_fixture(manifest_path; tier = :core) do fixture
        fixture.cell_ids == selection.core_cell_ids ||
            error("Core fixture load audit failed")
    end
    load_selected_cell_fixture(manifest_path; tier = :extended) do fixture
        fixture.cell_ids == selection.extended_cell_ids ||
            error("Extended fixture load audit failed")
    end
    return manifest_path
end

# ============================================================================
# Synthetic fixtures and self-tests
# ============================================================================

function write_test_forcing_year(path, year)
    NCDatasets.NCDataset(path, "c"; format = :netcdf4) do dataset
        NCDatasets.defDim(dataset, "lon", 2)
        NCDatasets.defDim(dataset, "lat", 2)
        NCDatasets.defDim(dataset, "time", 2)
        NCDatasets.defDim(dataset, "nsoilyrs", 2)
        NCDatasets.defDim(dataset, "myear", 1)
        lon = NCDatasets.defVar(dataset, "lon", Float32, ("lon",))
        lon[:] = Float32[10, 20]
        lon.attrib["units"] = "degrees_east"
        lat = NCDatasets.defVar(dataset, "lat", Float32, ("lat",))
        lat[:] = Float32[-5, 5]
        lat.attrib["units"] = "degrees_north"
        year_variable = NCDatasets.defVar(dataset, "year", Int32, ("myear",))
        year_variable[:] = Int32[year]
        landfrac =
            NCDatasets.defVar(dataset, "landfrac", Float32, ("lon", "lat"))
        landfrac[:, :] = Float32[0.1 0.2; 0.3 0.4]
        missing_mask =
            NCDatasets.defVar(dataset, "cellMissing", Int32, ("lon", "lat"))
        missing_mask[:, :] = zeros(Int32, 2, 2)
        cellid = NCDatasets.defVar(dataset, "cellid", Int32, ("lon", "lat"))
        cellid[:, :] = Int32[1 2; 3 4]
        for (offset, name) in enumerate(("xtairk", "ndep", "xcgpp"))
            variable = NCDatasets.defVar(
                dataset,
                name,
                Float32,
                ("lon", "lat", "time"),
            )
            variable[:, :, :] =
                reshape(Float32.(year * 100 + offset * 10 .+ (1:8)), 2, 2, 2)
            variable.attrib["units"] = "test_units"
        end
        for (offset, name) in enumerate(("xtsoil", "xmoist", "xfrznmoist"))
            variable = NCDatasets.defVar(
                dataset,
                name,
                Float32,
                ("lon", "lat", "nsoilyrs", "time"),
            )
            variable[:, :, :, :] = reshape(
                Float32.(year * 100 + offset * 20 .+ (1:16)),
                2,
                2,
                2,
                2,
            )
            variable.attrib["units"] = "test_units"
        end
    end
    return path
end

function self_test()
    Test.@testset "selected-cell fixture selection" begin
        candidates = [
            (;
                cell_id = 1,
                pft = 1,
                mean_gpp = 4.0,
                mean_temperature = 270.0,
                mean_moisture = 0.10,
                mean_nitrogen_deposition = 0.001,
                clay = 0.10,
                silt = 0.70,
                porosity = 0.35,
            ),
            (;
                cell_id = 2,
                pft = 2,
                mean_gpp = 2.0,
                mean_temperature = 275.0,
                mean_moisture = 0.20,
                mean_nitrogen_deposition = 0.002,
                clay = 0.20,
                silt = 0.50,
                porosity = 0.40,
            ),
            (;
                cell_id = 3,
                pft = 9,
                mean_gpp = 5.0,
                mean_temperature = 280.0,
                mean_moisture = 0.30,
                mean_nitrogen_deposition = 0.003,
                clay = 0.30,
                silt = 0.30,
                porosity = 0.45,
            ),
            (;
                cell_id = 4,
                pft = 10,
                mean_gpp = 3.0,
                mean_temperature = 285.0,
                mean_moisture = 0.40,
                mean_nitrogen_deposition = 0.004,
                clay = 0.40,
                silt = 0.10,
                porosity = 0.50,
            ),
            (;
                cell_id = 5,
                pft = 15,
                mean_gpp = 100.0,
                mean_temperature = 260.0,
                mean_moisture = 0.50,
                mean_nitrogen_deposition = 0.005,
                clay = 0.50,
                silt = 0.05,
                porosity = 0.55,
            ),
        ]
        boundary = (;
            cell_id = 51,
            pft = 17,
            mean_gpp = 0.0,
            mean_temperature = 277.0,
            mean_moisture = 0.25,
            mean_nitrogen_deposition = 0.0,
            clay = 0.25,
            silt = 0.40,
            porosity = 0.42,
        )

        selection = select_fixture_cells(candidates, boundary)
        reversed = select_fixture_cells(reverse(candidates), boundary)
        Test.@test selection == reversed
        Test.@test selection.core_cell_ids == sort(selection.core_cell_ids)
        Test.@test selection.extended_cell_ids ==
                   sort(selection.extended_cell_ids)
        Test.@test 51 in selection.core_cell_ids
        Test.@test issubset(
            selection.core_cell_ids,
            selection.extended_cell_ids,
        )
        Test.@test Set(
            candidate.pft for
            candidate in candidates if candidate.pft ∉ (13, 15, 17)
        ) == Set(
            candidate.pft for
            candidate in selection.extended if candidate.mean_gpp > 0
        )
        Test.@test all(candidate.pft != 15 for candidate in selection.extended)
        Test.@test any(candidate.pft <= 8 for candidate in selection.core)
        Test.@test any(9 <= candidate.pft <= 14 for candidate in selection.core)
        for field in (
            "mean GPP",
            "mean soil temperature",
            "mean liquid moisture",
            "mean nitrogen deposition",
            "clay fraction",
            "silt fraction",
            "porosity",
        )
            for region in ("low", "central", "high")
                Test.@test any(selection.extended) do candidate
                    "$region $field" in candidate.reasons
                end
            end
        end
    end
    Test.@testset "audited multi-cell forcing extraction" begin
        mktempdir() do directory
            sources = map(1901:1902) do year
                write_test_forcing_year(
                    joinpath(directory, "met_$(year)_$(year).nc"),
                    year,
                )
            end
            fixture = joinpath(directory, "forcing.nc")
            audit = extract_forcing_fixture(sources, fixture, [1, 4])
            Test.@test audit.source_selection_exact
            Test.@test audit.fixture_roundtrip_exact
            Test.@test audit_forcing_fixture(sources, fixture)
            NCDatasets.NCDataset(fixture) do dataset
                Test.@test dataset["cellid"][:] == Int32[1, 4]
                Test.@test dataset["year"][:] == Int32[1901, 1902]
                Test.@test dataset.dim["cell"] == 2
                Test.@test dataset.dim["time"] == 4
                Test.@test dataset["time"].attrib["calendar"] == "noleap"
                Test.@test dataset["xcgpp"][1:2, 1] ==
                           NCDatasets.NCDataset(sources[1]) do source
                    source["xcgpp"][1, 1, :]
                end
                Test.@test eltype(dataset["xmoist"].var) == Float32
                Test.@test dataset["xmoist"].attrib["units"] == "test_units"
            end
            NCDatasets.NCDataset(fixture, "a") do dataset
                dataset["lon"][1] = Float32(-999)
            end
            Test.@test !audit_forcing_fixture(sources, fixture)
        end
    end
    Test.@testset "verified archive members" begin
        mktempdir() do directory
            forcing_root = joinpath(directory, "forcing")
            mkpath(forcing_root)
            source_paths = [
                joinpath(forcing_root, "met_1901_1901.nc"),
                joinpath(forcing_root, "met_1902_1902.nc"),
            ]
            write(source_paths[1], "first forcing member")
            write(source_paths[2], "second forcing member")
            archive = joinpath(directory, "forcing.tar.gz")
            run(
                Cmd([
                    something(Sys.which("tar"), "tar"),
                    "-czf",
                    archive,
                    "-C",
                    directory,
                    basename(forcing_root),
                ]),
            )
            Test.@test length(verify_archive_members(archive, source_paths)) ==
                       64
            write(source_paths[2], "changed forcing member")
            Test.@test_throws ErrorException verify_archive_members(
                archive,
                source_paths,
            )
        end
    end
    Test.@testset "archive-independent fixture loading" begin
        mktempdir() do directory
            source = write_test_forcing_year(
                joinpath(directory, "met_1901_1901.nc"),
                1901,
            )
            forcing = joinpath(directory, "forcing.nc")
            extract_forcing_fixture([source], forcing, [1, 4])
            checksum = open(forcing) do io
                bytes2hex(SHA.sha256(io))
            end
            manifest_path = joinpath(directory, "fixture.toml")
            manifest = Dict(
                "schema_version" => 1,
                "selection" => Dict(
                    "core_cell_ids" => [1],
                    "extended_cell_ids" => [1, 4],
                ),
                "fixture" => Dict(
                    "forcing" => Dict(
                        "filename" => basename(forcing),
                        "bytes" => filesize(forcing),
                        "sha256" => checksum,
                    ),
                ),
                "variable" => variable_manifest(source, forcing),
            )
            open(manifest_path, "w") do io
                TOML.print(io, manifest; sorted = true)
            end

            load_selected_cell_fixture(manifest_path; tier = :core) do fixture
                Test.@test fixture.cell_ids == [1]
                Test.@test fixture.forcing["cellid"][fixture.cell_indices] ==
                           Int32[1]
            end
            load_selected_cell_fixture(
                manifest_path;
                tier = :extended,
            ) do fixture
                Test.@test fixture.cell_ids == [1, 4]
            end
            open(forcing, "a") do io
                write(io, UInt8(0))
            end
            Test.@test_throws ErrorException load_selected_cell_fixture(
                identity,
                manifest_path;
                tier = :core,
            )
        end
        committed_manifest =
            joinpath(@__DIR__, "fixtures", "selected_cells", "fixture.toml")
        load_selected_cell_fixture(committed_manifest; tier = :core) do fixture
            Test.@test length(fixture.cell_ids) == 11
            Test.@test fixture.forcing.dim["time"] == 114 * 365
            Test.@test fixture.forcing["year"][[1, end]] == Int32[1901, 2014]
            Test.@test all(values(fixture.manifest["audit"]))
            Test.@test fixture.manifest["selection"]["code_sha256"] ==
                       sha256sum(@__FILE__)
            Test.@test fixture.manifest["license"]["driver_dataset"] ==
                       "CC-BY-4.0"
            Test.@test fixture.manifest["license"]["testbed_repository_inputs"] ==
                       "MIT"
            Test.@test fixture.manifest["source"]["archive_members_match_extracted_sources"]
            Test.@test haskey(fixture.files, "corpse_parameters")
        end
        load_selected_cell_fixture(
            committed_manifest;
            tier = :extended,
        ) do fixture
            Test.@test length(fixture.cell_ids) == 37
        end
    end
    return true
end

function main(args)
    isempty(args) && return self_test() ? 0 : 1
    if length(args) == 4 && first(args) == "build"
        println(build_selected_cell_fixture(args[2], args[3], args[4]))
        return 0
    end
    println(
        stderr,
        "Usage: julia selected_cell_fixtures.jl build " *
        "<data-root> <biogeochem-testbed-root> <destination>",
    )
    return 2
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end

end
