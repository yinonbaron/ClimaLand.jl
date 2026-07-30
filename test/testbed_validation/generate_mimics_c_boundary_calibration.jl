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

source_record(path) =
    Dict("sha256" => sha256sum(path))

function boundary_values(state, casa_path, mimics_path, grid)
    casa_columns, casa_rows = Native.read_boundary_csv(casa_path)
    mimics_columns, mimics_rows = Native.read_boundary_csv(mimics_path)
    length(casa_rows) == length(mimics_rows) == length(grid) == 4263 ||
        error("MIMICS-C boundary calibration requires 4,263 aligned rows")
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
                parse(Float64, row[columns[fortran_name]]) /
                (source == :casa ? 1000 : 1) for row in rows
            ]
            Calibration.calibration_record(
                actual,
                expected;
                units = "kg C m^-2",
                observations = [
                    (; cell_id = point.cell_id, pft = point.pft) for
                    point in grid
                ],
            )
        end for (fortran_name, source, component, variable) in
        Native.BOUNDARY_VARIABLES
    )
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
    reference_root,
    output_root,
    path,
)
    grid_path =
        joinpath(source_root, "GRID_CN", "gridinfo_igbpz_CLM5_GSWP3.csv")
    soil_path =
        joinpath(source_root, "GRID_CN", "gridinfo_soil_CLM5_GSWP3.csv")
    plant_path =
        joinpath(source_root, "GRID_CN", "pftlookup_igbp_updated4.csv")
    mimics_path = joinpath(
        source_root,
        "GRID_CN",
        "MIMICS_mod5_GSWP3_KO4_push",
        "pftlookup_LIDET-MIM-REV_CN_desorb2xKO4_micCN_FI30.csv",
    )
    grid = Native.casa().read_grid(grid_path)
    length(grid) == 4263 ||
        error("MIMICS-C boundary calibration requires 4,263 grid cells")
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
        variables[stage] =
            boundary_values(state, casa_path, mimics_reference, grid)
        sources[stage] = Dict(
            "checkpoint" => source_record(checkpoint),
            "fresh_fortran_casa" => source_record(casa_path),
            "fresh_fortran_mimics" => source_record(mimics_reference),
        )
    end
    repo_root = normpath(joinpath(@__DIR__, "..", ".."))
    document = Dict(
        "schema_version" => 1,
        "calibration_id" =>
            "mimics-c-current-julia-fresh-fortran-full-grid-boundary-v2",
        "model" => "MIMICS-C",
        "source" => "fresh_fortran_full_grid",
        "cell_count" => 4263,
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
        "source_provenance" => Dict(
            "git_revision_basis" =>
                readchomp(`git -C $repo_root rev-parse HEAD`),
            "julia_version" => string(VERSION),
            "generator" => merge(
                Dict("id" => relpath(@__FILE__, repo_root)),
                source_record(@__FILE__),
            ),
            "grid" => source_record(grid_path),
            "casa_parameters" => source_record(plant_path),
            "mimics_parameters" => source_record(mimics_path),
            "fresh_fortran_build" => source_record(
                joinpath(reference_root, "build", "build_metadata.toml"),
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
