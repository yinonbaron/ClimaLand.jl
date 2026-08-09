#!/usr/bin/env julia

import NCDatasets
import SHA
import TOML

include("process_stress_matrix.jl")
using .CLASSICProcessStressMatrix: root_relative_path, selection_passes

const PROCESS_CLASSES =
    ("tropical_warm_wet", "seasonal_dry", "wet_mineral", "cold_freeze_thaw")

const CRITERIA = Dict{String, Any}(
    "tropical_warm_wet" => Dict(
        "absolute_latitude_max_deg" => 23.5,
        "mean_air_temperature_min_c" => 20.0,
        "annual_precipitation_min_mm" => 1500.0,
        "dry_month_fraction_max" => 0.25,
    ),
    "seasonal_dry" => Dict(
        "mean_air_temperature_min_c" => 15.0,
        "dry_month_fraction_min" => 0.25,
        "maximum_dry_spell_min_days" => 30,
    ),
    "wet_mineral" => Dict(
        "absolute_latitude_min_deg" => 23.5,
        "annual_precipitation_min_mm" => 1000.0,
        "dry_month_fraction_max" => 0.2,
        "mineral_layer_fraction_min" => 0.8,
        "initial_mineral_liquid_water_min_m3_m3" => 0.25,
    ),
    "cold_freeze_thaw" => Dict(
        "mean_air_temperature_max_c" => 10.0,
        "minimum_air_temperature_max_c" => -10.0,
        "subzero_day_fraction_min" => 0.1,
        "freeze_thaw_transition_count_min" => 10,
    ),
)

sha256_file(path) = bytes2hex(open(SHA.sha256, path))
rounded(value) = round(Float64(value); digits = 6)

function required_regular_file(path, label)
    isfile(path) || throw(ArgumentError("missing $label: $path"))
    islink(path) && throw(ArgumentError("$label must not be a symlink: $path"))
    filesize(path) > 0 || throw(ArgumentError("empty $label: $path"))
    return abspath(path)
end

function write_toml(path, table)
    temporary = path * ".tmp"
    open(temporary, "w") do io
        TOML.print(io, table; sorted = true)
    end
    mv(temporary, path; force = true)
end

function metadata_value(path, key)
    expression = Regex("^" * key * raw":\s*\"?([^\"#\n]+)", "m")
    match_result = match(expression, read(path, String))
    isnothing(match_result) && throw(ArgumentError("missing $key in $path"))
    return strip(match_result.captures[1])
end

function forcing_vector(path, variable)
    required_regular_file(path, "$variable forcing")
    return NCDatasets.NCDataset(path, "r") do dataset
        haskey(dataset, variable) ||
            throw(ArgumentError("missing $variable in $path"))
        values = Float64.(vec(dataset[variable][:]))
        times = Float64.(vec(dataset["time"].var[:]))
        length(values) == length(times) ||
            throw(ArgumentError("$variable/time length mismatch in $path"))
        all(isfinite, values) ||
            throw(ArgumentError("non-finite $variable forcing in $path"))
        return values, times
    end
end

date_code(time) = floor(Int, time + 1.0e-6)
year_code(date) = date ÷ 10000
month_code(date) = date ÷ 100

function grouped_sum(values, keys)
    result = Dict{Int, Float64}()
    for (value, key) in zip(values, keys)
        result[key] = get(result, key, 0.0) + value
    end
    return result
end

function grouped_mean(values, keys)
    sums = grouped_sum(values, keys)
    counts = Dict{Int, Int}()
    for key in keys
        counts[key] = get(counts, key, 0) + 1
    end
    return Dict(key => value / counts[key] for (key, value) in sums)
end

function maximum_run(flags)
    longest = 0
    current = 0
    for flag in flags
        current = flag ? current + 1 : 0
        longest = max(longest, current)
    end
    return longest
end

function forcing_metrics(temperature_path, precipitation_path)
    temperature, temperature_times = forcing_vector(temperature_path, "ta")
    precipitation, precipitation_times =
        forcing_vector(precipitation_path, "pr")
    temperature_times == precipitation_times ||
        throw(ArgumentError("temperature/precipitation time axes differ"))
    all(>=(0), precipitation) ||
        throw(ArgumentError("negative precipitation forcing"))

    dates = date_code.(temperature_times)
    day_counts = Dict{Int, Int}()
    for date in dates
        day_counts[date] = get(day_counts, date, 0) + 1
    end
    records_per_day = only(unique(values(day_counts)))
    records_per_day > 0 || throw(ArgumentError("empty forcing time axis"))
    timestep_seconds = 86_400.0 / records_per_day
    precipitation_depth = precipitation .* timestep_seconds

    years = year_code.(dates)
    months = month_code.(dates)
    annual_precipitation = grouped_sum(precipitation_depth, years)
    monthly_precipitation = grouped_sum(precipitation_depth, months)
    daily_precipitation = grouped_sum(precipitation_depth, dates)
    daily_temperature = grouped_mean(temperature, dates)
    ordered_days = sort!(collect(keys(daily_temperature)))
    dry_days = [daily_precipitation[day] < 1.0 for day in ordered_days]
    daily_temperatures = [daily_temperature[day] for day in ordered_days]
    freeze_thaw_transitions = count(
        index ->
            (daily_temperatures[index] <= 0 < daily_temperatures[index + 1]) || (
                daily_temperatures[index] > 0 >= daily_temperatures[index + 1]
            ),
        1:(length(daily_temperatures) - 1),
    )

    return Dict{String, Any}(
        "record_count" => length(temperature),
        "records_per_day" => records_per_day,
        "year_count" => length(annual_precipitation),
        "air_temperature_mean_c" =>
            rounded(sum(temperature) / length(temperature)),
        "air_temperature_min_c" => rounded(minimum(temperature)),
        "air_temperature_max_c" => rounded(maximum(temperature)),
        "annual_precipitation_mean_mm" => rounded(
            sum(values(annual_precipitation)) / length(annual_precipitation),
        ),
        "dry_month_fraction" => rounded(
            count(<(30.0), values(monthly_precipitation)) /
            length(monthly_precipitation),
        ),
        "maximum_dry_spell_days" => maximum_run(dry_days),
        "subzero_day_fraction" => rounded(
            count(<=(0.0), daily_temperatures) / length(daily_temperatures),
        ),
        "freeze_thaw_transition_count" => freeze_thaw_transitions,
    )
end

function initialization_metrics(path)
    required_regular_file(path, "prepared initialization")
    sand, liquid = NCDatasets.NCDataset(path, "r") do dataset
        return Float64.(vec(dataset["SAND"][:])), Float64.(vec(dataset["THLQ"][:]))
    end
    length(sand) == length(liquid) ||
        throw(ArgumentError("SAND/THLQ shape mismatch in $path"))
    active = sand .> -3
    mineral = sand .>= 0
    any(active) || throw(ArgumentError("no active soil layers in $path"))
    has_mineral_layers = any(mineral)
    return Dict{String, Any}(
        "active_layer_count" => count(active),
        "mineral_layer_count" => count(mineral),
        "has_mineral_layers" => has_mineral_layers,
        "mineral_layer_fraction" => rounded(count(mineral) / count(active)),
        "initial_mineral_liquid_water_mean_m3_m3" =>
            has_mineral_layers ?
            rounded(sum(liquid[mineral]) / count(mineral)) : 0.0,
    )
end

function site_metrics(
    site,
    metadata_path,
    temperature_path,
    precipitation_path,
    init_path,
)
    metrics = forcing_metrics(temperature_path, precipitation_path)
    merge!(metrics, initialization_metrics(init_path))
    latitude = parse(Float64, metadata_value(metadata_path, "lat"))
    metrics["latitude_deg"] = latitude
    metrics["absolute_latitude_deg"] = abs(latitude)
    metrics["biome"] = metadata_value(metadata_path, "biome")
    metrics["configured_start_year"] =
        parse(Int, metadata_value(metadata_path, "start"))
    metrics["configured_end_year"] =
        parse(Int, metadata_value(metadata_path, "end"))
    metrics["site"] = site
    metrics["source_kind"] = "released_configuration_and_forcing"
    return metrics
end

function rank_key(class_name, metrics)
    if class_name == "tropical_warm_wet"
        return (
            -metrics["annual_precipitation_mean_mm"],
            metrics["dry_month_fraction"],
            metrics["site"],
        )
    elseif class_name == "seasonal_dry"
        return (
            -metrics["dry_month_fraction"],
            -metrics["maximum_dry_spell_days"],
            metrics["site"],
        )
    elseif class_name == "wet_mineral"
        return (
            -metrics["initial_mineral_liquid_water_mean_m3_m3"],
            -metrics["annual_precipitation_mean_mm"],
            metrics["site"],
        )
    elseif class_name == "cold_freeze_thaw"
        return (
            -metrics["freeze_thaw_transition_count"],
            -metrics["subzero_day_fraction"],
            metrics["site"],
        )
    end
    throw(ArgumentError("unknown process class: $class_name"))
end

function select_sites(all_metrics)
    used = Set{String}()
    selections = Dict{String, Any}[]
    for class_name in PROCESS_CLASSES
        qualifying = filter(all_metrics) do metrics
            metrics["site"] ∉ used &&
                selection_passes(class_name, metrics, CRITERIA[class_name])
        end
        isempty(qualifying) &&
            throw(ArgumentError("no qualifying site for $class_name"))
        sort!(qualifying; by = metrics -> rank_key(class_name, metrics))
        selected = first(qualifying)
        push!(used, selected["site"])
        push!(
            selections,
            Dict{String, Any}(
                "class" => class_name,
                "site" => selected["site"],
                "criteria_passed" => true,
                "selection_rule" => "first deterministic rank among qualifying unused sites",
                "metrics" => selected,
            ),
        )
    end
    return selections
end

function identical_site_inventory(
    configuration_root,
    forcing_root,
    run_root,
    site_list_path,
)
    configured = sort!(
        filter(
            name -> isdir(joinpath(configuration_root, name)),
            readdir(configuration_root),
        ),
    )
    forced = sort!(
        filter(
            name -> isdir(joinpath(forcing_root, name)),
            readdir(forcing_root),
        ),
    )
    listed = sort!(filter(!isempty, strip.(readlines(site_list_path))))
    run_sites = sort!(
        filter(readdir(run_root)) do name
            isdir(joinpath(run_root, name)) &&
                isfile(joinpath(run_root, name, "$(name)_init.nc"))
        end,
    )
    length(configured) == 59 || throw(
        ArgumentError(
            "expected 59 configured sites, found $(length(configured))",
        ),
    )
    configured == forced == listed == run_sites || throw(
        ArgumentError("configuration/forcing/run/site-list inventories differ"),
    )
    return configured
end

function main(args)
    length(args) == 1 || error("usage: generate_matrix.jl REFERENCE_ROOT")
    reference_root = abspath(only(args))
    extraction_root = joinpath(
        reference_root,
        "replaceable",
        "extracted",
        "issue-98-all-sites-pristine-20260809",
        "CLASSIC",
    )
    run_root = joinpath(
        reference_root,
        "replaceable",
        "runs",
        "issue-98-all-sites-pristine-20260809",
    )
    configuration_root =
        joinpath(extraction_root, "inputFiles", "FLUXNETsites_12PFT")
    forcing_root = joinpath(extraction_root, "inputFiles", "meteorology")
    site_list_path =
        required_regular_file(joinpath(run_root, "site-list.txt"), "site list")
    sites = identical_site_inventory(
        configuration_root,
        forcing_root,
        run_root,
        site_list_path,
    )

    metrics = Dict{String, Any}[]
    receipts = Dict{String, Any}[]
    for site in sites
        paths = Dict(
            "site_metadata" => required_regular_file(
                joinpath(configuration_root, site, "siteinfo.yaml"),
                "$site metadata",
            ),
            "air_temperature_forcing" => required_regular_file(
                joinpath(forcing_root, site, "metVar_ta.nc"),
                "$site air temperature forcing",
            ),
            "precipitation_forcing" => required_regular_file(
                joinpath(forcing_root, site, "metVar_pr.nc"),
                "$site precipitation forcing",
            ),
            "prepared_initialization" => required_regular_file(
                joinpath(run_root, site, "$(site)_init.nc"),
                "$site prepared initialization",
            ),
        )
        push!(
            metrics,
            site_metrics(
                site,
                paths["site_metadata"],
                paths["air_temperature_forcing"],
                paths["precipitation_forcing"],
                paths["prepared_initialization"],
            ),
        )
        push!(
            receipts,
            Dict(
                "site" => site,
                "raw_data_embedded" => false,
                "input_path" => Dict(
                    label =>
                        root_relative_path(path, reference_root, label) for
                    (label, path) in paths
                ),
                "input_sha256" =>
                    Dict(label => sha256_file(path) for (label, path) in paths),
            ),
        )
    end

    output_directory = @__DIR__
    metrics_path = joinpath(output_directory, "site_metrics.toml")
    receipts_path = joinpath(output_directory, "input_receipts.toml")
    write_toml(
        metrics_path,
        Dict(
            "schema_version" => 1,
            "site_count" => length(metrics),
            "site" => metrics,
        ),
    )
    write_toml(
        receipts_path,
        Dict(
            "schema_version" => 2,
            "path_root" => "CLASSIC_REFERENCE_ROOT",
            "site_count" => length(receipts),
            "raw_data_embedded" => false,
            "site" => receipts,
        ),
    )

    archive_root = joinpath(reference_root, "immutable", "archives")
    source_archive = required_regular_file(
        joinpath(archive_root, "zenodo-18188101", "classic-CLASSICv2.0.tar.gz"),
        "CLASSIC v2 source archive",
    )
    input_archive = required_regular_file(
        joinpath(archive_root, "zenodo-18202323", "FLUXNET.tar.gz"),
        "released FLUXNET archive",
    )
    container_archive = required_regular_file(
        joinpath(archive_root, "zenodo-18201505", "CLASSIC_container.tar.gz"),
        "released container archive",
    )
    campaign_summary = required_regular_file(
        joinpath(run_root, "campaign-summary.toml"),
        "campaign summary",
    )
    matrix = Dict{String, Any}(
        "schema_version" => 1,
        "inventory" => Dict(
            "site_count" => length(sites),
            "site_list_sha256" => sha256_file(site_list_path),
            "site_metrics_sha256" => sha256_file(metrics_path),
            "input_receipts_sha256" => sha256_file(receipts_path),
        ),
        "provenance" => Dict(
            "source_doi" => "10.5281/zenodo.18188101",
            "source_archive_sha256" => sha256_file(source_archive),
            "input_doi" => "10.5281/zenodo.18202323",
            "input_archive_sha256" => sha256_file(input_archive),
            "container_doi" => "10.5281/zenodo.18201505",
            "container_archive_sha256" => sha256_file(container_archive),
            "campaign_summary_sha256" => sha256_file(campaign_summary),
            "metric_generator" => basename(@__FILE__),
            "metric_generator_sha256" => sha256_file(@__FILE__),
        ),
        "criteria" => CRITERIA,
        "selection" => select_sites(metrics),
        "acceptance" => Dict(
            "status" => "blocked",
            "blocked_reason" => "pending direct user approval to record the independent-root archive manifest and promote scientific acceptance status",
            "seasonal_parity_claimed" => false,
            "required_oracle_contract" => "stage_b_v5",
        ),
    )
    write_toml(joinpath(output_directory, "selection_matrix.toml"), matrix)
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
