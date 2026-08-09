using Test
import TOML

include("execution_receipt.jl")
using .StageBExecutionReceipt

@testset "execution receipt binds toolchain and forcing inputs" begin
    mktempdir() do directory
        source = joinpath(directory, "source.tar.gz")
        container = joinpath(directory, "container.tar.gz")
        sif = joinpath(directory, "container.sif")
        toolchain = joinpath(directory, "toolchain.log")
        build = joinpath(directory, "make.log")
        makefile = joinpath(directory, "Makefile")
        binary = joinpath(directory, "CLASSIC_serial")
        patch = joinpath(directory, "instrumentation.patch")
        forcing = joinpath(directory, "forcing.nc")
        job_options = joinpath(directory, "job_options_file.txt")
        for path in (source, container, sif, makefile, binary, patch, forcing)
            write(path, basename(path))
        end
        write(toolchain, "GNU Fortran (GCC) 12.2.0\n")
        write(
            build,
            "gfortran -O3 -fdefault-real-8 -ffree-line-length-none -fbacktrace -ffpe-trap=invalid,zero,overflow -fbounds-check\n",
        )
        write(
            job_options,
            """
PFTCompetition = .false.,
lnduseon = .false.,
timberHarvest = .false.,
dofire = .false.,
prescribedFire = .false.,
""",
        )
        receipt = joinpath(directory, "execution.toml")
        record_execution_receipt(
            receipt,
            source,
            container,
            sif,
            toolchain,
            build,
            makefile,
            binary,
            patch,
            [forcing, job_options],
        )
        @test verify_execution_receipt(receipt).ok
        report = verify_execution_receipt(receipt)
        @test report.process_switches["PFTCompetition"] == false
        @test haskey(TOML.parsefile(receipt), "process_configuration")

        unbound = joinpath(directory, "unbound.toml")
        unbound_receipt = TOML.parsefile(receipt)
        delete!(unbound_receipt, "process_configuration")
        open(unbound, "w") do io
            TOML.print(io, unbound_receipt; sorted = true)
        end
        unbound_report = verify_execution_receipt(unbound)
        @test !unbound_report.ok
        @test "execution receipt does not bind process configuration" in
              unbound_report.issues

        write(forcing, "changed")
        report = verify_execution_receipt(receipt)
        @test !report.ok
        @test "forcing input 1 hash differs" in report.issues
    end
end

@testset "execution receipt rejects incomplete compiler evidence" begin
    mktempdir() do directory
        paths = [joinpath(directory, "file-$index") for index in 1:7]
        foreach(path -> write(path, "x"), paths)
        toolchain = joinpath(directory, "toolchain.log")
        build = joinpath(directory, "make.log")
        write(toolchain, "GNU Fortran\n")
        write(build, "gfortran -O3\n")
        @test_throws ErrorException record_execution_receipt(
            joinpath(directory, "receipt.toml"),
            paths[1],
            paths[2],
            paths[3],
            toolchain,
            build,
            paths[4],
            paths[5],
            paths[6],
            [paths[7]],
        )
    end
end
