if !isdefined(@__MODULE__, :TestbedNativeCORPSECReconstruction)
    include(joinpath(@__DIR__, "native_corpse_c_reconstruction.jl"))
end

module GenerateRepresentativeCORPSEReference

import SHA
import TOML

import NCDatasets

native_corpse() =
    getfield(parentmodule(@__MODULE__), :TestbedNativeCORPSECReconstruction)

const STATE_SOURCES = Dict(
    "cleaf" => ("casaclm", "cleaf"),
    "cwood" => ("casaclm", "cwood"),
    "cfroot" => ("casaclm", "cfroot"),
    "clitcwd" => ("casaclm", "clitcwd"),
    "Soil_C1" => ("corpse", "Soil_C1"),
    "Soil_C2" => ("corpse", "Soil_C2"),
    "Soil_C3" => ("corpse", "Soil_C3"),
    "SoilProtected_C1" => ("corpse", "SoilProtected_C1"),
    "SoilProtected_C2" => ("corpse", "SoilProtected_C2"),
    "SoilProtected_C3" => ("corpse", "SoilProtected_C3"),
    "Soil_LiveMicrobeC" => ("corpse", "Soil_LiveMicrobeC"),
    "LitterLayer_C1" => ("corpse", "LitterLayer_C1"),
    "LitterLayer_C2" => ("corpse", "LitterLayer_C2"),
    "LitterLayer_C3" => ("corpse", "LitterLayer_C3"),
    "LitterLayer_LiveMicrobeC" => ("corpse", "LitterLayer_LiveMicrobeC"),
    "Ts" => ("corpse", "Ts"),
    "thetaLiq" => ("corpse", "thetaLiq"),
    "thetaFrzn" => ("corpse", "thetaFrzn"),
)
const FLUX_SOURCES = Dict(
    "cgpp" => ("casaclm", "cgpp"),
    "cnpp" => ("casaclm", "cnpp"),
    "Soil_CO2" => ("corpse", "Soil_CO2"),
    "LitterLayer_CO2" => ("corpse", "LitterLayer_CO2"),
)

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

function daily_path(root, prefix, year)
    names = (
        "$(prefix)_pool_flux_$(lpad(year, 4, '0'))_daily.nc",
        "$(prefix)_pool_flux_$(lpad(year, 4, '0')).nc",
    )
    for name in names
        path = joinpath(root, name)
        isfile(path) || continue
        records = NCDatasets.NCDataset(path) do dataset
            get(dataset.dim, "time", 0)
        end
        records == 365 && return path
    end
    error("missing 365-record $prefix daily output for $year")
end

function selected_series(dataset, variable, cell_ids)
    ids = Int.(vec(dataset["cellid"][:]))
    by_id = Dict(id => index for (index, id) in enumerate(ids) if id > 0)
    all(haskey(by_id, id) for id in cell_ids) ||
        error("$variable daily output is missing Representative cells")
    source = dataset[variable]
    dimensions = NCDatasets.dimnames(source)
    time_dimension = findfirst(==("time"), dimensions)
    isnothing(time_dimension) && error("$variable has no time dimension")
    spatial = filter(!=(time_dimension), eachindex(dimensions))
    order = (spatial..., time_dimension)
    indices = ntuple(_ -> Colon(), ndims(source))
    raw = coalesce.(source[indices...], NaN)
    matrix =
        reshape(permutedims(raw, order), length(ids), size(raw, time_dimension))
    return Float64.(matrix[[by_id[id] for id in cell_ids], :])
end

function sample_days(year)
    first_day = (year - 1901) * 365
    return [
        (sample, day - first_day) for
        (sample, day) in enumerate(native_corpse().REDUCED_SAMPLE_DAYS) if
        first_day < day <= first_day + 365
    ]
end

function read_year!(tracker, historical_root, year, cell_ids, provenance)
    paths = Dict(
        prefix => daily_path(historical_root, prefix, year) for
        prefix in ("casaclm", "corpse")
    )
    provenance[string(year)] = Dict(
        prefix => Dict(
            "id" => "fortran/historical/$(basename(path))",
            "sha256" => sha256sum(path),
        ) for (prefix, path) in paths
    )
    datasets =
        Dict(prefix => NCDatasets.NCDataset(path) for (prefix, path) in paths)
    year_index = year - 1900
    samples = sample_days(year)
    try
        for (name, (prefix, variable)) in STATE_SOURCES
            series = selected_series(datasets[prefix], variable, cell_ids)
            tracker.annual_mean[name][:, year_index] .=
                vec(sum(series; dims = 2))
            tracker.end_of_year[name][:, year_index] .= series[:, end]
            for (sample, day) in samples
                tracker.samples[name][:, sample] .= series[:, day]
            end
        end
        for (name, (prefix, variable)) in FLUX_SOURCES
            series = selected_series(datasets[prefix], variable, cell_ids)
            tracker.annual_total[name][:, year_index] .=
                vec(sum(series; dims = 2))
            for (sample, day) in samples
                tracker.samples[name][:, sample] .= series[:, day]
            end
        end
    finally
        foreach(close, values(datasets))
    end
    return nothing
end

function assert_eligible_finite(tracker, eligible)
    for (reducer, arrays) in (
            "annual_mean" => tracker.annual_mean,
            "end_of_year" => tracker.end_of_year,
            "annual_total" => tracker.annual_total,
            "fixed_daily_sample" => tracker.samples,
        ),
        (name, values) in arrays

        all(isfinite, values[eligible, :]) ||
            error("eligible Fortran $reducer $name contains a nonfinite value")
    end
    return nothing
end

function generate(scope_manifest, historical_root, output_path)
    scope = native_corpse().representative_scope(scope_manifest)
    tracker = native_corpse().ReducedCORPSEHistorical(length(scope.cell_ids))
    provenance = Dict{String, Any}()
    for year in 1901:2014
        read_year!(tracker, historical_root, year, scope.cell_ids, provenance)
    end
    eligible = [!haskey(scope.gaps, id) for id in scope.cell_ids]
    assert_eligible_finite(tracker, eligible)
    grid =
        [(cell_id = id, pft = get(scope.gaps, id, 0)) for id in scope.cell_ids]
    native_corpse().write_reduced_historical(
        output_path,
        tracker,
        grid,
        eligible,
    )
    manifest = Dict(
        "schema_version" => 1,
        "reference_id" => "corpse-c-representative-fortran-reduced-v1",
        "scope" => "representative",
        "scope_cell_count" => 80,
        "eligible_cell_count" => 78,
        "eligibility_gaps" => scope.gap_entries,
        "reducers" => Dict(
            "annual_mean" => "18 state/driver variables, 114 years",
            "end_of_year" => "18 state/driver variables, 114 years",
            "annual_total" => "4 carbon flux variables, 114 years",
            "fixed_daily_sample" => "22 state/driver/flux variables, 84 days",
        ),
        "units" => Dict(
            "carbon_state" => "g C m-2",
            "temperature" => "K",
            "saturation" => "1",
            "daily_flux" => "g C m-2 day-1",
            "annual_flux_total" => "g C m-2 year-1",
        ),
        "artifact" => Dict(
            "id" => "fortran/reduced_historical.nc",
            "sha256" => sha256sum(output_path),
            "bytes" => filesize(output_path),
        ),
        "scope_manifest" => Dict(
            "id" => "validation/scopes/representative.toml",
            "sha256" => scope.sha256,
        ),
        "generator" => Dict(
            "id" => "test/testbed_validation/generate_representative_corpse_reference.jl",
            "sha256" => sha256sum(@__FILE__),
        ),
        "historical_input" => provenance,
    )
    manifest_path = output_path * ".toml"
    open(manifest_path, "w") do io
        TOML.print(io, manifest; sorted = true)
    end
    return (; reference = output_path, manifest = manifest_path)
end

function main(args = ARGS)
    length(args) == 3 || error(
        "usage: generate_representative_corpse_reference.jl SCOPE_MANIFEST FORTRAN_HISTORICAL_ROOT OUTPUT_NC",
    )
    result = generate(args...)
    println(result.reference)
    return result
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    GenerateRepresentativeCORPSEReference.main()
end
