module TestbedRepresentativeCellSelection

import Random
import SHA
import Statistics
import TOML

import NCDatasets

const FEATURE_GROUPS = (
    productivity = (:gpp_median, :gpp_p10, :gpp_p90, :gpp_seasonal_amplitude),
    temperature = (
        :temperature_median,
        :temperature_p10,
        :temperature_p90,
        :temperature_seasonal_amplitude,
    ),
    hydrology = (
        :liquid_moisture_median,
        :liquid_moisture_p10,
        :liquid_moisture_p90,
        :liquid_moisture_seasonal_amplitude,
        :frozen_moisture_median,
        :frozen_moisture_p10,
        :frozen_moisture_p90,
        :frozen_moisture_seasonal_amplitude,
    ),
    nitrogen_input = (
        :nitrogen_deposition_median,
        :nitrogen_deposition_p10,
        :nitrogen_deposition_p90,
        :nitrogen_deposition_seasonal_amplitude,
    ),
    soil_texture = (:clay, :silt, :porosity),
)
const FEATURE_NAMES = Tuple(Iterators.flatten(values(FEATURE_GROUPS)))
const FEATURE_WEIGHTS = Tuple(
    Iterators.flatten(
        ntuple(length(FEATURE_GROUPS)) do group_index
            group = values(FEATURE_GROUPS)[group_index]
            ntuple(
                _ -> 1 / length(FEATURE_GROUPS) / length(group),
                length(group),
            )
        end,
    ),
)
const FORCING_FEATURES = (
    gpp = "xcgpp",
    temperature = "xtsoil",
    liquid_moisture = "xmoist",
    frozen_moisture = "xfrznmoist",
    nitrogen_deposition = "ndep",
)
const SEASONS = (1:90, 91:181, 182:273, 274:365)

selected_fixtures() =
    getfield(parentmodule(@__MODULE__), :TestbedSelectedCellFixtures)
const SMOKE_FIXTURE_MANIFEST =
    joinpath(@__DIR__, "fixtures", "selected_cells", "fixture.toml")

sha256sum(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

function fixture_provenance()
    source_fixture = TOML.parsefile(SMOKE_FIXTURE_MANIFEST)
    return (
        selection = Dict(
            "code" => basename(@__FILE__),
            "code_sha256" => sha256sum(@__FILE__),
        ),
        time = source_fixture["time"],
    )
end

function largest_remainder_allocation(population, total)
    pfts = sort!(collect(keys(population)))
    population_total = sum(values(population))
    population_total > 0 || error("No active PFT candidates were found")
    quotas =
        Dict(pft => total * population[pft] / population_total for pft in pfts)
    allocation = Dict(pft => floor(Int, quotas[pft]) for pft in pfts)
    remaining = total - sum(values(allocation))
    order = sort(pfts; by = pft -> (-(quotas[pft] - allocation[pft]), pft))
    for pft in order[1:remaining]
        allocation[pft] += 1
    end
    return allocation
end

function empirical_quantiles(candidates)
    quantiles = Dict(
        candidate.cell_id => zeros(length(FEATURE_NAMES)) for
        candidate in candidates
    )
    for (feature_index, feature) in enumerate(FEATURE_NAMES)
        ordered = sort([
            (getproperty(candidate.features, feature), candidate.cell_id)
            for candidate in candidates
        ],)
        index = 1
        while index <= length(ordered)
            final =
                findlast(
                    pair -> pair[1] == ordered[index][1],
                    @view(ordered[index:end]),
                ) + index - 1
            rank = ((index + final) / 2 - 0.5) / length(ordered)
            for position in index:final
                quantiles[ordered[position][2]][feature_index] = rank
            end
            index = final + 1
        end
    end
    return quantiles
end

function latin_hypercube_targets(rng, count, dimensions)
    targets = zeros(count, dimensions)
    for dimension in 1:dimensions
        strata = Random.randperm(rng, count)
        for row in 1:count
            targets[row, dimension] =
                (strata[row] - 1 + Random.rand(rng)) / count
        end
    end
    return targets
end

function squared_distance(target, candidate)
    return sum(
        FEATURE_WEIGHTS[index] * (target[index] - candidate[index])^2 for
        index in eachindex(FEATURE_WEIGHTS)
    )
end

function select_representative_cells(
    candidates,
    smoke_ids;
    total_cells = 80,
    seed = 31432026,
)
    ordered = sort!(collect(candidates); by = candidate -> candidate.cell_id)
    length(unique(candidate.cell_id for candidate in ordered)) ==
    length(ordered) || error("Candidate cell IDs must be unique")
    fixed_ids = sort!(unique!(Int.(collect(smoke_ids))))
    fixed = Set(fixed_ids)
    all(id -> any(candidate -> candidate.cell_id == id, ordered), fixed_ids) ||
        error("Every Smoke cell must be a real candidate")
    additions = total_cells - length(fixed_ids)
    additions > 0 || error("Representative must strictly contain Smoke")
    active = filter(
        candidate ->
            candidate.active &&
            candidate.pft ∉ (13, 15, 17) &&
            candidate.cell_id ∉ fixed,
        ordered,
    )
    population = Dict{Int, Int}()
    for candidate in filter(
        candidate -> candidate.active && candidate.pft ∉ (13, 15, 17),
        ordered,
    )
        population[candidate.pft] = get(population, candidate.pft, 0) + 1
    end
    allocation = largest_remainder_allocation(population, additions)
    quantiles = empirical_quantiles(active)
    rng = Random.MersenneTwister(seed)
    matches = NamedTuple[]
    selected = copy(fixed_ids)
    for pft in sort!(collect(keys(allocation)))
        count = allocation[pft]
        count == 0 && continue
        available = filter(candidate -> candidate.pft == pft, active)
        length(available) >= count ||
            error("PFT $pft has fewer unused candidates than allocated slots")
        targets = latin_hypercube_targets(rng, count, length(FEATURE_NAMES))
        for row in axes(targets, 1)
            target = vec(targets[row, :])
            ranked = sort(
                available;
                by = candidate -> (
                    squared_distance(target, quantiles[candidate.cell_id]),
                    candidate.cell_id,
                ),
            )
            match = first(ranked)
            distance = sqrt(squared_distance(target, quantiles[match.cell_id]))
            push!(
                matches,
                (;
                    pft,
                    cell_id = match.cell_id,
                    target,
                    matching_error = distance,
                ),
            )
            push!(selected, match.cell_id)
            deleteat!(
                available,
                findfirst(
                    candidate -> candidate.cell_id == match.cell_id,
                    available,
                ),
            )
        end
    end
    sort!(selected)
    length(selected) == total_cells ||
        error("Representative selection did not reach $total_cells cells")
    return (; cell_ids = selected, population, allocation, matches)
end

function source_locations(path, grid, soils)
    return NCDatasets.NCDataset(path) do dataset
        cell_ids = dataset["cellid"][:, :]
        missing = dataset["cellMissing"][:, :]
        locations = NamedTuple[]
        for index in CartesianIndices(cell_ids)
            cell_id = Int(cell_ids[index])
            haskey(grid, cell_id) && haskey(soils, cell_id) || continue
            push!(
                locations,
                (;
                    cell_id,
                    lon_index = index[1],
                    lat_index = index[2],
                    missing = missing[index] != 0,
                ),
            )
        end
        sort!(locations; by = location -> location.cell_id)
    end
end

function spatial_mean(values, days)
    indices = ntuple(
        dimension -> dimension == ndims(values) ? days : Colon(),
        ndims(values),
    )
    selected = view(values, indices...)
    reduced_dimensions = Tuple(3:ndims(selected))
    sums = dropdims(
        sum(Float64, selected; dims = reduced_dimensions);
        dims = reduced_dimensions,
    )
    count = prod(size(selected, dimension) for dimension in reduced_dimensions)
    return sums ./ count
end

function robust_forcing_features(source_paths, locations)
    years = length(source_paths)
    cells = length(locations)
    annual = Dict(
        name => Matrix{Float64}(undef, years, cells) for
        name in keys(FORCING_FEATURES)
    )
    seasonal = Dict(
        name => zeros(Float64, length(SEASONS), cells) for
        name in keys(FORCING_FEATURES)
    )
    for (year_index, path) in enumerate(source_paths)
        NCDatasets.NCDataset(path) do dataset
            for (feature, variable_name) in pairs(FORCING_FEATURES)
                variable = dataset[variable_name]
                indices = ntuple(_ -> Colon(), ndims(variable))
                values = Array(variable.var[indices...])
                yearly = spatial_mean(values, axes(values, ndims(values)))
                annual[feature][year_index, :] .= map(locations) do location
                    yearly[location.lon_index, location.lat_index]
                end
                for (season_index, days) in enumerate(SEASONS)
                    seasonal_grid = spatial_mean(values, days)
                    seasonal[feature][season_index, :] .+=
                        map(locations) do location
                            seasonal_grid[
                                location.lon_index,
                                location.lat_index,
                            ]
                        end
                end
            end
        end
        (year_index == 1 || year_index % 10 == 0 || year_index == years) &&
            println("summarized forcing year $year_index/$years")
    end
    return map(eachindex(locations)) do cell_index
        values = Float64[]
        names = Symbol[]
        for feature in keys(FORCING_FEATURES)
            yearly = annual[feature][:, cell_index]
            climatology = seasonal[feature][:, cell_index] ./ years
            append!(
                names,
                (
                    Symbol(feature, "_median"),
                    Symbol(feature, "_p10"),
                    Symbol(feature, "_p90"),
                    Symbol(feature, "_seasonal_amplitude"),
                ),
            )
            append!(
                values,
                (
                    Statistics.median(yearly),
                    Statistics.quantile(yearly, 0.1),
                    Statistics.quantile(yearly, 0.9),
                    maximum(climatology) - minimum(climatology),
                ),
            )
        end
        NamedTuple{Tuple(names)}(Tuple(values))
    end
end

function representative_candidates(source_paths, grid_path, soil_path)
    grid = selected_fixtures().grid_metadata(grid_path)
    soils = selected_fixtures().soil_metadata(soil_path)
    locations = source_locations(first(source_paths), grid, soils)
    forcing = robust_forcing_features(source_paths, locations)
    return map(eachindex(locations)) do index
        location = locations[index]
        cell_id = location.cell_id
        soil = soils[cell_id]
        forcing_features = forcing[index]
        features = merge(
            forcing_features,
            (; clay = soil.clay, silt = soil.silt, porosity = soil.porosity),
        )
        finite =
            all(value -> isfinite(value) && abs(value) < 1e30, values(features))
        (;
            cell_id,
            pft = grid[cell_id].pft,
            active = !location.missing &&
                     grid[cell_id].pft ∉ (13, 15, 17) &&
                     finite &&
                     forcing_features.gpp_median > 0,
            features,
        )
    end
end

function feature_group_manifest()
    return Dict(
        String(group) => Dict(
            "weight" => 1 / length(FEATURE_GROUPS),
            "features" => collect(String.(features)),
            "within_group_weight" => 1 / length(features),
        ) for (group, features) in pairs(FEATURE_GROUPS)
    )
end

function write_scope_manifest(
    path,
    selection,
    smoke_ids,
    source_paths,
    grid_path,
    soil_path,
    smoke_manifest;
    seed,
)
    matches = [
        Dict(
            "pft" => match.pft,
            "cell_id" => match.cell_id,
            "target" => match.target,
            "matching_error" => match.matching_error,
        ) for match in selection.matches
    ]
    manifest = Dict(
        "schema_version" => 1,
        "name" => "representative",
        "cell_ids" => selection.cell_ids,
        "eligibility_gaps" => Any[],
        "selection" => Dict(
            "method" => "PFT-stratified augmented Latin hypercube matched to unique real cells in empirical-quantile space",
            "seed" => seed,
            "statistics_period" => "1901-2014",
            "statistics" => [
                "annual median",
                "annual 10th percentile",
                "annual 90th percentile",
                "four-season climatology amplitude",
            ],
            "transforms" => "empirical midrank quantiles over active vegetated candidates",
            "candidate_filter" => "cellMissing == 0; PFT not in [13, 15, 17]; every feature finite with absolute value below 1e30; median annual GPP > 0",
            "matching" => "greedy minimum equal-group-weight Euclidean distance; ties use lowest global cell ID",
            "inactive_candidates_excluded" => true,
            "smoke_cell_ids" => smoke_ids,
            "smoke_manifest_sha256" => sha256sum(smoke_manifest),
            "source_manifest_sha256" => sha256sum(smoke_manifest),
            "forcing_archive_members_sha256" =>
                TOML.parsefile(SMOKE_FIXTURE_MANIFEST)["source"]["archive_members_sha256"],
            "grid_sha256" => sha256sum(grid_path),
            "soil_sha256" => sha256sum(soil_path),
            "first_forcing_file_sha256" => sha256sum(first(source_paths)),
            "last_forcing_file_sha256" => sha256sum(last(source_paths)),
            "feature_group" => feature_group_manifest(),
            "candidate_population" => Dict(
                string(pft) => count for
                (pft, count) in sort!(collect(selection.population))
            ),
            "allocation" => Dict(
                string(pft) => count for
                (pft, count) in sort!(collect(selection.allocation))
            ),
            "match" => matches,
        ),
        "partition" =>
            [Dict("name" => "all", "cell_ids" => selection.cell_ids)],
    )
    mkpath(dirname(path))
    open(path, "w") do io
        TOML.print(io, manifest; sorted = true)
    end
    return path
end

function fixture_file_record(path, license)
    return Dict(
        "filename" => basename(path),
        "bytes" => filesize(path),
        "sha256" => sha256sum(path),
        "license" => license,
    )
end

function build_representative_fixture(
    source_paths,
    source_root,
    destination,
    candidates,
    selection,
    scope_manifest,
)
    mkpath(destination)
    grid_path =
        joinpath(source_root, "GRID_CN", "gridinfo_igbpz_CLM5_GSWP3.csv")
    soil_path = joinpath(source_root, "GRID_CN", "gridinfo_soil_CLM5_GSWP3.csv")
    forcing_path = joinpath(destination, "forcing_1901_2014.nc")
    audit = selected_fixtures().extract_forcing_fixture(
        source_paths,
        forcing_path,
        selection.cell_ids,
    )
    files = Dict(
        "forcing" => forcing_path,
        "grid" => selected_fixtures().write_selected_csv(
            grid_path,
            joinpath(destination, "grid_selected_cells.csv"),
            selection.cell_ids,
        ),
        "soil" => selected_fixtures().write_selected_csv(
            soil_path,
            joinpath(destination, "soil_selected_cells.csv"),
            selection.cell_ids,
        ),
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
    for (name, source) in source_inputs
        destination_path = joinpath(destination, basename(source))
        files[name] =
            selected_fixtures().copy_fixture_file(source, destination_path)
    end
    by_id = Dict(candidate.cell_id => candidate for candidate in candidates)
    smoke =
        Set(Int.(TOML.parsefile(scope_manifest)["selection"]["smoke_cell_ids"]))
    cells = [
        Dict(
            "id" => id,
            "pft" => by_id[id].pft,
            "reasons" =>
                id in smoke ? ["preserved Smoke anchor"] :
                ["augmented Latin-hypercube PFT $(by_id[id].pft)"],
        ) for id in selection.cell_ids
    ]
    provenance = fixture_provenance()
    manifest = Dict(
        "schema_version" => 1,
        "title" => "Representative CLM5/GSWP3 validation forcing",
        "selection" => Dict(
            provenance.selection...,
            "representative_cell_ids" => selection.cell_ids,
            "scope_manifest_sha256" => sha256sum(scope_manifest),
        ),
        "source" => Dict(
            "repository" => "https://github.com/wwieder/biogeochem_testbed.git",
            "repository_commit" => strip(
                read(`git -C $source_root rev-parse HEAD`, String),
            ),
            "forcing_archive_members_sha256" =>
                TOML.parsefile(SMOKE_FIXTURE_MANIFEST)["source"]["archive_members_sha256"],
        ),
        "audit" => Dict(
            "source_selection_exact_before_repacking" =>
                audit.source_selection_exact,
            "fixture_roundtrip_exact" => audit.fixture_roundtrip_exact,
            "static_rows_exact" => true,
            "copied_inputs_exact" => true,
        ),
        "fixture" => Dict(
            name => fixture_file_record(
                file,
                name == "forcing" ? "CC-BY-4.0" : "MIT",
            ) for (name, file) in files
        ),
        "variable" => selected_fixtures().variable_manifest(
            first(source_paths),
            forcing_path,
        ),
        "time" => provenance.time,
        "cell" => cells,
    )
    manifest_path = joinpath(destination, "fixture.toml")
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted = true)
    end
    return manifest_path
end

end
