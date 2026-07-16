module TestbedFixtureExtraction

import NCDatasets
import SHA
import TOML
import Test

const HARNESS_DIR = @__DIR__
const EXPERIMENTS_PATH = joinpath(HARNESS_DIR, "experiments.toml")

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

function variable_data(variable, selectors)
    ndims(variable) == 0 && return [variable[]]
    indices = map(NCDatasets.dimnames(variable)) do dimension
        selector = get(selectors, String(dimension), Colon())
        selector isa Integer ? (selector:selector) : selector
    end
    return variable[indices...]
end

function copy_netcdf_slice(source_path, destination_path, selectors)
    NCDatasets.NCDataset(source_path) do source
        NCDatasets.NCDataset(
            destination_path,
            "c";
            format = :netcdf4,
        ) do destination
            for (name, dimension) in source.dim
                selector = get(selectors, String(name), Colon())
                length = selector isa Colon ? Int(dimension) : 1
                NCDatasets.defDim(destination, String(name), length)
            end
            for (name, value) in source.attrib
                destination.attrib[name] = value
            end
            for name in keys(source)
                source_variable = source[name]
                attributes = Dict(source_variable.attrib)
                fillvalue = pop!(attributes, "_FillValue", nothing)
                destination_variable = NCDatasets.defVar(
                    destination,
                    String(name),
                    eltype(source_variable.var),
                    NCDatasets.dimnames(source_variable);
                    attrib = attributes,
                    fillvalue,
                    deflatelevel = 1,
                )
                data = variable_data(source_variable, selectors)
                indices = ntuple(_ -> Colon(), ndims(destination_variable))
                destination_variable[indices...] = data
            end
        end
    end
    return destination_path
end

function roundtrip_exact(source_path, fixture_path, selectors)
    return NCDatasets.NCDataset(source_path) do source
        NCDatasets.NCDataset(fixture_path) do fixture
            all(keys(source)) do name
                isequal(
                    variable_data(source[name], selectors),
                    variable_data(fixture[name], Dict()),
                )
            end
        end
    end
end

function select_csv_row(source_path, destination_path, cell_id; reindex = false)
    lines = readlines(source_path)
    row_index = findfirst(lines[2:end]) do line
        fields = split(line, ','; keepempty = true)
        !isempty(fields) && tryparse(Int, strip(first(fields))) == cell_id
    end
    isnothing(row_index) && error("Cell $cell_id was not found in $source_path")
    fields = split(lines[row_index + 1], ','; keepempty = true)
    if reindex
        length(fields) >= 19 || error("Unexpected grid CSV row in $source_path")
        fields[18] = "   1"
        fields[19] = "   1"
    end
    write(destination_path, lines[1] * "\n" * join(fields, ',') * "\n")
    return destination_path
end

function artifact(manifest, id)
    match = findfirst(item -> item["id"] == id, manifest["artifact"])
    isnothing(match) && error("Artifact $id was not found in experiments.toml")
    return manifest["artifact"][match]
end

function cell_indices(dataset_path, cell_id)
    return NCDatasets.NCDataset(dataset_path) do dataset
        index = findfirst(==(cell_id), dataset["cellid"][:, :])
        isnothing(index) &&
            error("Cell $cell_id was not found in $dataset_path")
        Dict("lon" => index[1], "lat" => index[2])
    end
end

function fixture_file(path)
    return Dict(
        "filename" => basename(path),
        "bytes" => filesize(path),
        "sha256" => sha256sum(path),
    )
end

function verify_fixture_manifest(path)
    manifest = TOML.parsefile(path)
    directory = dirname(path)
    return all(values(manifest["fixture"])) do entry
        fixture = joinpath(directory, entry["filename"])
        isfile(fixture) &&
            filesize(fixture) == entry["bytes"] &&
            sha256sum(fixture) == entry["sha256"]
    end
end

function output_summary(path)
    return NCDatasets.NCDataset(path) do dataset
        maximum_gpp = maximum(skipmissing(dataset["cgpp"][:]))
        (
            pft = Int(dataset["IGBP_PFT"][1, 1]),
            maximum_gpp = Float64(maximum_gpp),
        )
    end
end

function extract_fixture(
    driver_path,
    output_path,
    grid_csv,
    soil_csv,
    destination,
    cell_id,
    ;
    output_artifact_id = "casa_c_output",
    output_member =
        "CASACNP_mod5_GSWP3_Conly/OUTPUT_C/HIST/" *
        "casaclm_pool_flux_1901_1905_daily.nc",
    script = "extract_fixture.jl",
)
    mkpath(destination)
    driver_fixture = joinpath(destination, "met_1901_cell_$(cell_id).nc")
    output_fixture = joinpath(destination, "casa_1901_1905_cell_$(cell_id).nc")
    grid_fixture = joinpath(destination, "grid_cell_$(cell_id).csv")
    soil_fixture = joinpath(destination, "soil_cell_$(cell_id).csv")

    driver_selectors = cell_indices(driver_path, cell_id)
    output_selectors = cell_indices(output_path, cell_id)
    copy_netcdf_slice(driver_path, driver_fixture, driver_selectors)
    copy_netcdf_slice(output_path, output_fixture, output_selectors)
    select_csv_row(grid_csv, grid_fixture, cell_id; reindex = true)
    select_csv_row(soil_csv, soil_fixture, cell_id)

    driver_roundtrip =
        roundtrip_exact(driver_path, driver_fixture, driver_selectors)
    output_roundtrip =
        roundtrip_exact(output_path, output_fixture, output_selectors)
    driver_roundtrip || error("Driver fixture failed its round-trip audit")
    output_roundtrip || error("Output fixture failed its round-trip audit")
    summary = output_summary(output_fixture)

    manifest = TOML.parsefile(EXPERIMENTS_PATH)
    driver_archive = artifact(manifest, "drivers")
    output_archive = artifact(manifest, output_artifact_id)
    fixture_manifest = Dict(
        "schema_version" => 1,
        "license" => "CC-BY-4.0",
        "generation" => Dict(
            "script" => script,
            "roundtrip_exact" => driver_roundtrip && output_roundtrip,
        ),
        "cell" => Dict(
            "id" => cell_id,
            "source_lon_index" => driver_selectors["lon"],
            "source_lat_index" => driver_selectors["lat"],
            "fixture_lon_index" => 1,
            "fixture_lat_index" => 1,
            "pft" => summary.pft,
            "reference_maximum_gpp" => summary.maximum_gpp,
            "reason" =>
                summary.maximum_gpp > 0 ?
                "small productive-cell runtime and trajectory fixture" :
                "ice/water boundary fixture",
        ),
        "comparison" => Dict(
            "reference_time_start" => 1,
            "reference_time_stop" => 365,
            "candidate_time_offset" => 1900,
            "expected_alignment_warnings" => 1,
        ),
        "source" => Dict(
            "driver_archive" => driver_archive["filename"],
            "driver_archive_md5" => driver_archive["md5"],
            "driver_member" => "INPUT_GSWP3_CLM5dev110_hist/met_1901_1901.nc",
            "output_archive" => output_archive["filename"],
            "output_archive_md5" => output_archive["md5"],
            "output_member" => output_member,
        ),
        "fixture" => Dict(
            "driver" => fixture_file(driver_fixture),
            "output" => fixture_file(output_fixture),
            "grid" => fixture_file(grid_fixture),
            "soil" => fixture_file(soil_fixture),
        ),
    )
    open(joinpath(destination, "fixture.toml"), "w") do io
        TOML.print(io, fixture_manifest; sorted = true)
    end
    return destination
end

function extract_mimics_fixture(
    mimics_output_path,
    casa_output_path,
    destination,
    cell_id,
    ;
    output_artifact_id = "mimics_c_output",
    output_root = "MIMICS_mod5_Conly_KO4/OUTPUT_C/HIST",
    script = "extract_fixture.jl mimics",
)
    mkpath(destination)
    mimics_fixture =
        joinpath(destination, "mimics_1901_1905_cell_$(cell_id).nc")
    casa_fixture = joinpath(destination, "casa_1901_1905_cell_$(cell_id).nc")
    mimics_selectors = cell_indices(mimics_output_path, cell_id)
    casa_selectors = cell_indices(casa_output_path, cell_id)
    copy_netcdf_slice(mimics_output_path, mimics_fixture, mimics_selectors)
    copy_netcdf_slice(casa_output_path, casa_fixture, casa_selectors)
    mimics_roundtrip =
        roundtrip_exact(mimics_output_path, mimics_fixture, mimics_selectors)
    casa_roundtrip =
        roundtrip_exact(casa_output_path, casa_fixture, casa_selectors)
    mimics_roundtrip || error("MIMICS fixture failed its round-trip audit")
    casa_roundtrip || error("CASA fixture failed its round-trip audit")

    manifest = TOML.parsefile(EXPERIMENTS_PATH)
    output_archive = artifact(manifest, output_artifact_id)
    summary = output_summary(casa_fixture)
    fixture_manifest = Dict(
        "schema_version" => 1,
        "license" => "CC-BY-4.0",
        "generation" => Dict(
            "script" => script,
            "roundtrip_exact" => mimics_roundtrip && casa_roundtrip,
        ),
        "cell" => Dict(
            "id" => cell_id,
            "source_lon_index" => mimics_selectors["lon"],
            "source_lat_index" => mimics_selectors["lat"],
            "fixture_lon_index" => 1,
            "fixture_lat_index" => 1,
            "pft" => summary.pft,
            "reason" =>
                summary.maximum_gpp > 0 ?
                "active MIMICS trajectory fixture" :
                "MIMICS ice/water boundary fixture",
        ),
        "source" => Dict(
            "output_archive" => output_archive["filename"],
            "output_archive_md5" => output_archive["md5"],
            "mimics_output_member" =>
                output_root * "/mimics_pool_flux_1901_1905_daily.nc",
            "casa_output_member" =>
                output_root * "/casaclm_pool_flux_1901_1905_daily.nc",
            "parameter_file" =>
                "GRID_CN/MIMICS_mod5_GSWP3_KO4_push/" *
                "pftlookup_LIDET-MIM-REV_CN_desorb2xKO4_micCN_FI30.csv",
            "parameter_file_md5" => "f8b2e7f45f3c6eace3fedaa239ae8de8",
            "parameter_status" => "candidate; original archived control is unpublished",
        ),
        "fixture" => Dict(
            "mimics_output" => fixture_file(mimics_fixture),
            "casa_output" => fixture_file(casa_fixture),
        ),
    )
    open(joinpath(destination, "fixture.toml"), "w") do io
        TOML.print(io, fixture_manifest; sorted = true)
    end
    return destination
end

function write_test_netcdf(path)
    NCDatasets.NCDataset(path, "c"; format = :netcdf4) do dataset
        NCDatasets.defDim(dataset, "lon", 2)
        NCDatasets.defDim(dataset, "lat", 2)
        NCDatasets.defDim(dataset, "time", 2)
        cellid = NCDatasets.defVar(dataset, "cellid", Int32, ("lon", "lat"))
        cellid[:, :] = Int32[1 2; 3 4]
        pft = NCDatasets.defVar(dataset, "IGBP_PFT", Int32, ("lon", "lat"))
        pft[:, :] = Int32[7 8; 9 10]
        values = NCDatasets.defVar(
            dataset,
            "values",
            Float32,
            ("lon", "lat", "time"),
        )
        values[:, :, :] = reshape(Float32.(1:8), 2, 2, 2)
        gpp =
            NCDatasets.defVar(dataset, "cgpp", Float32, ("lon", "lat", "time"))
        gpp[:, :, :] = reshape(Float32.(1:8), 2, 2, 2)
    end
end

function self_test()
    Test.@testset "fixture extraction" begin
        mktempdir() do directory
            source = joinpath(directory, "source.nc")
            fixture = joinpath(directory, "fixture.nc")
            write_test_netcdf(source)
            selectors = Dict("lon" => 2, "lat" => 1)
            copy_netcdf_slice(source, fixture, selectors)
            Test.@test roundtrip_exact(source, fixture, selectors)
            NCDatasets.NCDataset(fixture) do dataset
                Test.@test dataset.dim["lon"] == 1
                Test.@test dataset.dim["lat"] == 1
                Test.@test dataset["cellid"][1, 1] == 3
            end
            summary = output_summary(fixture)
            Test.@test summary.pft == 9
            Test.@test summary.maximum_gpp == 6

            mimics_fixture = joinpath(directory, "mimics")
            extract_mimics_fixture(source, source, mimics_fixture, 3)
            generated = TOML.parsefile(joinpath(mimics_fixture, "fixture.toml"))
            Test.@test generated["cell"]["id"] == 3
            Test.@test generated["generation"]["roundtrip_exact"]
        end
        for fixture in (
            "mimics_c_cell_11060",
            "casa_cn_cell_51",
            "casa_cn_cell_11060",
            "mimics_cn_cell_51",
            "mimics_cn_cell_11060",
        )
            committed_manifest =
                joinpath(HARNESS_DIR, "fixtures", fixture, "fixture.toml")
            Test.@test verify_fixture_manifest(committed_manifest)
        end
        corpse_manifest = joinpath(
            HARNESS_DIR,
            "fixtures",
            "corpse_c_fresh_cell_11060",
            "fixture.toml",
        )
        Test.@test verify_fixture_manifest(corpse_manifest)
    end
    return true
end

function main(args)
    if !isempty(args) && first(args) == "casa-cn"
        length(args) == 7 || begin
            println(
                stderr,
                "Usage: julia extract_fixture.jl casa-cn " *
                "<driver.nc> <output.nc> <grid.csv> <soil.csv> " *
                "<destination> <cell-id>",
            )
            return 2
        end
        extract_fixture(
            args[2],
            args[3],
            args[4],
            args[5],
            args[6],
            parse(Int, args[7]);
            output_artifact_id = "casa_cn_output",
            output_member =
                "CASACNP_mod5_GSWP3_exudate0_cwdN/OUTPUT_CN/HIST/" *
                "casaclm_pool_flux_1901_1905_daily.nc",
            script = "extract_fixture.jl casa-cn",
        )
        return 0
    end
    if !isempty(args) && first(args) == "mimics-cn"
        length(args) == 5 || begin
            println(
                stderr,
                "Usage: julia extract_fixture.jl mimics-cn " *
                "<mimics-output.nc> <casa-output.nc> " *
                "<destination> <cell-id>",
            )
            return 2
        end
        extract_mimics_fixture(
            args[2],
            args[3],
            args[4],
            parse(Int, args[5]);
            output_artifact_id = "mimics_cn_output",
            output_root =
                "MIMICS_mod5_GSWP3_KO4_exudate0_cwdN/OUTPUT_CN/HIST",
            script = "extract_fixture.jl mimics-cn",
        )
        return 0
    end
    if !isempty(args) && first(args) == "mimics"
        length(args) == 5 || begin
            println(
                stderr,
                "Usage: julia extract_fixture.jl mimics " *
                "<mimics-output.nc> <casa-output.nc> " *
                "<destination> <cell-id>",
            )
            return 2
        end
        extract_mimics_fixture(args[2], args[3], args[4], parse(Int, args[5]))
        return 0
    end
    length(args) == 6 || begin
        println(
            stderr,
            "Usage: julia extract_fixture.jl <driver.nc> <output.nc> <grid.csv> <soil.csv> <destination> <cell-id>",
        )
        return 2
    end
    extract_fixture(
        args[1],
        args[2],
        args[3],
        args[4],
        args[5],
        parse(Int, args[6]),
    )
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end

end
