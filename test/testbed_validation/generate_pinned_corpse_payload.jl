if !isdefined(@__MODULE__, :TestbedNativeCORPSECReconstruction)
    include(joinpath(@__DIR__, "native_corpse_c_reconstruction.jl"))
end

module GeneratePinnedCORPSEPayload

import Tar
import TOML

native_corpse() =
    getfield(parentmodule(@__MODULE__), :TestbedNativeCORPSECReconstruction)

const STAGES = Dict(
    "prespin" => "01-prespin",
    "spin" => "02-spin",
    "spin_continuation" => "03-spin_continuation",
    "historical" => "04-historical",
)
const STAGE_FILES =
    ("casa_final.csv", "corpse_final.csv", "grid.csv", "stage_metadata.toml")

function boundary_members()
    return [
        "reconstruction_report.toml"
        [
            "stages/$directory/$name" for directory in values(STAGES) for
            name in STAGE_FILES
        ]
    ]
end

function create_boundary_payload(reference_root, archive_path, manifest_path)
    members = boundary_members()
    all(relative -> isfile(joinpath(reference_root, relative)), members) ||
        error("CORPSE boundary source is incomplete")
    mkpath(dirname(archive_path))
    allowed(path) =
        path in members ||
        any(startswith(member, "$path/") for member in members)
    Tar.create(allowed, reference_root, archive_path; portable = true)
    document = Dict(
        "schema_version" => 1,
        "schema" => "corpse-boundary-archive-v1",
        "model" => "CORPSE",
        "scope" => "representative",
        "scope_cell_count" => 80,
        "eligible_cell_count" => 78,
        "archive_format" => "tar",
        "stage" => STAGES,
        "members" => Dict(
            relative => native_corpse().native_workflow().sha256sum(
                joinpath(reference_root, relative),
            ) for relative in members
        ),
    )
    open(manifest_path, "w") do io
        TOML.print(io, document; sorted = true)
    end
    return (; archive = archive_path, manifest = manifest_path)
end

function generate(reference_root, reduced_reference, destination)
    calibration_path = joinpath(
        @__DIR__,
        "validation",
        "corpse_c_representative_calibration.toml",
    )
    calibration = native_corpse().calibration_policy(calibration_path)
    native_corpse().verify_boundary_reference(calibration, reference_root)
    native_corpse().verify_reduced_reference(calibration, reduced_reference)
    mkpath(destination)
    boundaries = create_boundary_payload(
        reference_root,
        joinpath(destination, "boundaries.tar"),
        joinpath(destination, "boundaries.toml"),
    )
    reduced = joinpath(destination, "reduced_history.nc")
    reduced_manifest = joinpath(destination, "reduced_history.toml")
    cp(reduced_reference, reduced; force = true)
    cp(reduced_reference * ".toml", reduced_manifest; force = true)
    return (; boundaries..., reduced, reduced_manifest)
end

function main(args = ARGS)
    length(args) == 3 || error(
        "usage: generate_pinned_corpse_payload.jl FORTRAN_REFERENCE_ROOT REDUCED_REFERENCE_NC DESTINATION",
    )
    result = generate(args...)
    println(dirname(result.archive))
    return result
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    GeneratePinnedCORPSEPayload.main()
end
