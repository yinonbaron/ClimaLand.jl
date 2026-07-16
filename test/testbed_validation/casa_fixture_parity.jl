module CASAFixtureParity

import SHA
import TOML

include(joinpath(@__DIR__, "reference_harness.jl"))
include(joinpath(@__DIR__, "netcdf_compare.jl"))

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

function verify_fixture(fixture_dir, manifest)
    for description in values(manifest["fixture"])
        path = joinpath(fixture_dir, description["filename"])
        isfile(path) || error("Missing fixture file $path")
        filesize(path) == description["bytes"] ||
            error("Fixture size mismatch for $path")
        sha256sum(path) == description["sha256"] ||
            error("Fixture checksum mismatch for $path")
    end
    manifest["generation"]["roundtrip_exact"] ||
        error("Fixture manifest does not record an exact extraction round trip")
    return true
end

function run_parity(source_root, fixture_dir, run_parent = tempdir())
    manifest = TOML.parsefile(joinpath(fixture_dir, "fixture.toml"))
    verify_fixture(fixture_dir, manifest)
    run_dir = TestbedReferenceHarness.smoke_fortran_fixture(
        source_root,
        fixture_dir,
        run_parent,
    )
    comparison = manifest["comparison"]
    reference = joinpath(fixture_dir, manifest["fixture"]["output"]["filename"])
    candidate = joinpath(run_dir, "casaclm_pool_flux_0001_daily.nc")
    report = TestbedNetCDFCompare.compare_netcdf(
        reference,
        candidate;
        reference_selectors = Dict(
            "time" =>
                comparison["reference_time_start"]:comparison["reference_time_stop"],
        ),
        candidate_offsets = Dict("time" => comparison["candidate_time_offset"]),
    )
    TestbedNetCDFCompare.print_report(report) ||
        error("CASA-C fixture parity failed; outputs are in $run_dir")
    println("CASA-C archive parity: exact")
    return run_dir
end

function main(args)
    2 <= length(args) <= 3 || begin
        println(
            stderr,
            "Usage: julia casa_fixture_parity.jl <source-root> <fixture-dir> [run-parent]",
        )
        return 2
    end
    run_parent = length(args) == 3 ? args[3] : tempdir()
    run_parity(args[1], args[2], run_parent)
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main(ARGS))
end

end
