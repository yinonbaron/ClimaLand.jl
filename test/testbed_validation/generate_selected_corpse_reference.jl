include(joinpath(@__DIR__, "reference_harness.jl"))
include(joinpath(@__DIR__, "selected_cell_fixtures.jl"))

module GenerateSelectedCORPSEReference

import SHA
import TOML

import NCDatasets

const HARNESS = getfield(parentmodule(@__MODULE__), :TestbedReferenceHarness)
const SELECTED_CELLS =
    getfield(parentmodule(@__MODULE__), :TestbedSelectedCellFixtures)
const SELECTED_FIXTURE = joinpath(@__DIR__, "fixtures", "selected_cells")
const REFERENCE_DIRECTORY = joinpath(@__DIR__, "fixtures", "selected_corpse")
const REFERENCE_FILENAME = "fresh_fortran_1901.nc"

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

function verified_inputs(source_root, selected_manifest)
    manifest_path = joinpath(SELECTED_FIXTURE, "fixture.toml")
    selected_files =
        SELECTED_CELLS.verified_fixture_paths(manifest_path, selected_manifest)
    expected_commit = selected_manifest["source"]["repository_commit"]
    actual_commit = HARNESS.source_commit(source_root)
    actual_commit == expected_commit || error(
        "Fortran source must be pinned to $expected_commit; found $actual_commit",
    )
    source_status = HARNESS.source_code_status(source_root)
    isempty(source_status) || error(
        "Pinned Fortran SOURCE_CODE checkout has local modifications:\n" *
        source_status,
    )

    source_paths = Dict(
        "casa_parameters" => joinpath(
            source_root,
            "GRID_CN",
            "pftlookup_igbp_updated4_exud0.csv",
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
    fixture_keys = Dict(
        "casa_parameters" => "casa_c_parameters",
        "corpse_parameters" => "corpse_parameters",
        "phenology" => "phenology",
        "perturbation" => "perturbation",
    )
    source_hashes = Dict(
        name => begin
            isfile(path) || error("Fortran source input is missing: $path")
            actual = sha256sum(path)
            expected =
                selected_manifest["fixture"][fixture_keys[name]]["sha256"]
            actual == expected || error(
                "Fortran $name differs from the pinned selected-cell input",
            )
            actual
        end for (name, path) in source_paths
    )
    selected_hashes =
        Dict(name => sha256sum(path) for (name, path) in selected_files)
    return (;
        selected_files,
        selected_hashes,
        source_hashes,
        commit = actual_commit,
        source_status,
    )
end

function define_like(destination, source, source_name, destination_name)
    source_variable = source[source_name]
    attributes = Dict(source_variable.attrib)
    fillvalue = pop!(attributes, "_FillValue", nothing)
    return NCDatasets.defVar(
        destination,
        destination_name,
        Float64,
        ("time", "cell");
        attrib = attributes,
        fillvalue,
        deflatelevel = 3,
    )
end

function write_fortran_meteorology(source_path, destination_path)
    NCDatasets.NCDataset(source_path) do source
        NCDatasets.NCDataset(
            destination_path,
            "c";
            format = :netcdf4,
        ) do destination
            cell_count = Int(source.dim["cell"])
            NCDatasets.defDim(destination, "lon", cell_count)
            NCDatasets.defDim(destination, "lat", 1)
            NCDatasets.defDim(destination, "time", 365)
            NCDatasets.defDim(
                destination,
                "nsoilyrs",
                Int(source.dim["nsoilyrs"]),
            )
            NCDatasets.defDim(destination, "myear", 1)
            for (name, value) in source.attrib
                destination.attrib[name] = value
            end
            destination.attrib["transformation"] = "selected cells unpacked to a 37 by 1 Fortran grid; values unchanged"

            for name in ("lon",)
                variable = source[name]
                output = NCDatasets.defVar(
                    destination,
                    name,
                    eltype(variable.var),
                    ("lon",);
                    attrib = Dict(variable.attrib),
                )
                output[:] = variable[:]
            end
            latitude = NCDatasets.defVar(destination, "lat", Float32, ("lat",))
            latitude[:] = Float32[0]
            year = NCDatasets.defVar(destination, "year", Int32, ("myear",))
            year[:] = Int32[1901]
            for name in ("landfrac", "cellMissing", "cellid")
                variable = source[name]
                output = NCDatasets.defVar(
                    destination,
                    name,
                    eltype(variable.var),
                    ("lon", "lat");
                    attrib = Dict(variable.attrib),
                )
                output[:, 1] = variable[:]
            end
            for name in ("xtairk", "ndep", "xcgpp")
                variable = source[name]
                output = NCDatasets.defVar(
                    destination,
                    name,
                    eltype(variable.var),
                    ("lon", "lat", "time");
                    attrib = Dict(variable.attrib),
                )
                output[:, 1, :] = permutedims(variable[1:365, :], (2, 1))
            end
            for name in ("xtsoil", "xmoist", "xfrznmoist")
                variable = source[name]
                output = NCDatasets.defVar(
                    destination,
                    name,
                    eltype(variable.var),
                    ("lon", "lat", "nsoilyrs", "time");
                    attrib = Dict(variable.attrib),
                )
                output[:, 1, :, :] =
                    permutedims(variable[:, 1:365, :], (3, 1, 2))
            end
        end
    end
end

function write_fortran_grid(source_path, destination_path)
    lines = readlines(source_path)
    rows = map(enumerate(lines[2:end])) do (index, line)
        fields = split(line, ','; keepempty = true)
        fields[18] = "1"
        fields[19] = string(index)
        join(fields, ',')
    end
    write(destination_path, join([first(lines); rows], '\n') * "\n")
end

function pack_reference(casa_path, corpse_path, destination_path)
    NCDatasets.NCDataset(casa_path) do casa
        NCDatasets.NCDataset(corpse_path) do corpse
            NCDatasets.NCDataset(
                destination_path,
                "c";
                format = :netcdf4,
            ) do destination
                cell_count = size(corpse["cellid"], 1)
                NCDatasets.defDim(destination, "time", 365)
                NCDatasets.defDim(destination, "cell", cell_count)
                destination.attrib["source"] = "fresh pinned biogeochem_testbed Fortran run"
                destination.attrib["configuration"] = "CORPSE soil model 3; carbon-only cycle 1; 1901 daily output"
                destination.attrib["transformation"] = "comparison variables cast to Float64; annual NPP derived from GPP"

                cell_ids =
                    NCDatasets.defVar(destination, "cellid", Int32, ("cell",))
                cell_ids[:] = vec(corpse["cellid"][:, 1])
                pfts = NCDatasets.defVar(destination, "pft", Int32, ("cell",))
                pfts[:] = vec(corpse["IGBP_PFT"][:, 1])
                annual_npp = NCDatasets.defVar(
                    destination,
                    "annual_npp",
                    Float64,
                    ("cell",),
                )
                annual_npp.attrib["units"] = "g C m-2 year-1"
                annual_npp.attrib["derivation"] = "sum of 1901 daily cgpp divided by 2, matching Fortran xcnpp = xcgpp / 2 initialization"
                annual_npp[:] =
                    vec(sum(Float64.(casa["cgpp"][:, 1, :]); dims = 2)) / 2

                mappings = (
                    (casa, "cLitInptMet", "metabolic_litter"),
                    (casa, "cLitInptStruc", "recalcitrant_litter"),
                    (corpse, "Soil_C1", "soil_unprotected_labile"),
                    (corpse, "Soil_C2", "soil_unprotected_recalcitrant"),
                    (corpse, "Soil_C3", "soil_unprotected_dead_microbe"),
                    (corpse, "SoilProtected_C1", "soil_protected_labile"),
                    (corpse, "SoilProtected_C2", "soil_protected_recalcitrant"),
                    (corpse, "SoilProtected_C3", "soil_protected_dead_microbe"),
                    (corpse, "Soil_LiveMicrobeC", "soil_live_microbe"),
                    (corpse, "Soil_CO2", "soil_respiration"),
                    (corpse, "Ts", "soil_temperature"),
                    (corpse, "thetaLiq", "liquid_saturation"),
                    (corpse, "thetaFrzn", "frozen_saturation"),
                    (corpse, "fW", "moisture_factor"),
                )
                for (source, source_name, destination_name) in mappings
                    output = define_like(
                        destination,
                        source,
                        source_name,
                        destination_name,
                    )
                    output[:, :] = permutedims(
                        Float64.(source[source_name][:, 1, :]),
                        (2, 1),
                    )
                end
            end
        end
    end
end

function generate_reference(source_root, destination = REFERENCE_DIRECTORY)
    mkpath(destination)
    selected_manifest =
        TOML.parsefile(joinpath(SELECTED_FIXTURE, "fixture.toml"))
    inputs = verified_inputs(source_root, selected_manifest)
    cell_count = length(selected_manifest["selection"]["extended_cell_ids"])
    return mktempdir() do run_parent
        meteorology = joinpath(run_parent, "selected_1901.nc")
        grid = joinpath(run_parent, "selected_grid.csv")
        write_fortran_meteorology(inputs.selected_files["forcing"], meteorology)
        write_fortran_grid(inputs.selected_files["grid"], grid)
        run_directory = HARNESS.run_smoke_fortran(
            source_root,
            meteorology,
            grid,
            inputs.selected_files["soil"],
            run_parent;
            points = cell_count,
            daily_output = 1,
            soil_model = 3,
            expected_alignment_warnings = cell_count,
        )
        reference_path = joinpath(destination, REFERENCE_FILENAME)
        pack_reference(
            joinpath(run_directory, "casaclm_pool_flux_0001_daily.nc"),
            joinpath(run_directory, "corpse_pool_flux_0001_daily.nc"),
            reference_path,
        )
        run_metadata =
            TOML.parsefile(joinpath(run_directory, "run_metadata.toml"))
        build_metadata = TOML.parsefile(run_metadata["build_metadata"])
        staged_hashes = Dict(
            name => sha256sum(joinpath(run_directory, filename)) for
            (name, filename) in (
                "meteorology" => "met.nc",
                "grid" => "grid.csv",
                "soil" => "soil.csv",
                "casa_parameters" => "casa_parameters.csv",
                "corpse_parameters" => "corpse_parameters.nml",
                "phenology" => "phenology.txt",
                "perturbation" => "perturbation.txt",
                "control" => "fcasacnp_clm_testbed.lst",
            )
        )
        manifest = Dict(
            "schema_version" => 1,
            "title" => "Selected-cell CORPSE fresh-Fortran trajectory reference",
            "reference" => Dict(
                "filename" => REFERENCE_FILENAME,
                "bytes" => filesize(reference_path),
                "sha256" => sha256sum(reference_path),
                "records" => 365,
                "cell_ids" =>
                    selected_manifest["selection"]["extended_cell_ids"],
            ),
            "source" => Dict(
                "repository" => "https://github.com/wwieder/biogeochem_testbed.git",
                "commit" => inputs.commit,
                "selected_fixture_sha256" => sha256sum(
                    joinpath(SELECTED_FIXTURE, "fixture.toml"),
                ),
                "forcing_sha256" => inputs.selected_hashes["forcing"],
                "grid_sha256" => inputs.selected_hashes["grid"],
                "soil_sha256" => inputs.selected_hashes["soil"],
                "casa_parameters_sha256" =>
                    inputs.source_hashes["casa_parameters"],
                "corpse_parameters_sha256" =>
                    inputs.source_hashes["corpse_parameters"],
                "source_code_status" => inputs.source_status,
            ),
            "input_sha256" => Dict(
                "selected_fixture" => inputs.selected_hashes,
                "source_checkout" => inputs.source_hashes,
                "staged_run" => staged_hashes,
            ),
            "build" => Dict(
                "compiler_version" =>
                    build_metadata["build"]["compiler_version"],
                "flags" => build_metadata["build"]["flags"],
                "netcdf_fortran_version" =>
                    build_metadata["build"]["netcdf_fortran_version"],
                "compatibility_patch_md5" =>
                    build_metadata["build"]["compatibility_patch_md5"],
                "executable_sha256" => sha256sum(
                    joinpath(
                        dirname(run_metadata["build_metadata"]),
                        "casaclm_mimics-cn_corpse",
                    ),
                ),
            ),
            "generation" => Dict(
                "command" => "julia --project=test generate_selected_corpse_reference.jl <source-root>",
                "configuration" => "soil_model=3, cycle=1, initialization=0, year=1901, daily_output=1",
                "transformations" => [
                    "unpack selected cells to a 37 by 1 Fortran grid",
                    "replace source grid indices with local packed indices",
                    "retain the first 365 forcing days without numerical conversion",
                    "cast packed comparison drivers and authoritative outputs to Float64",
                    "derive annual NPP as sum of 1901 daily cgpp divided by 2, matching the Fortran xcnpp = xcgpp / 2 initialization",
                ],
                "raw_netcdf_checksums_include_creation_time" => true,
            ),
            "legacy_mean_audit" => Dict(
                "status" => "not reproducible from published inputs",
                "missing" => [
                    "1901-2010 CRU-NCEP meteorology",
                    "exact historical CORPSE CASA restart",
                ],
                "role" => "informational only; not used as an oracle",
            ),
        )
        manifest_path = joinpath(destination, "fixture.toml")
        open(manifest_path, "w") do io
            TOML.print(io, manifest; sorted = true)
        end
        return (; reference_path, manifest_path, run_directory)
    end
end

function main(args)
    length(args) in (1, 2) || error(
        "usage: julia --project=test generate_selected_corpse_reference.jl " *
        "<testbed-source-root> [destination]",
    )
    destination = length(args) == 2 ? args[2] : REFERENCE_DIRECTORY
    result = generate_reference(first(args), destination)
    println("CORPSE reference: $(result.reference_path)")
    println("CORPSE manifest: $(result.manifest_path)")
    return nothing
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    GenerateSelectedCORPSEReference.main(ARGS)
end
