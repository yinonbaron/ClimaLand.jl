using Test

include("record_comparison_receipt.jl")

@testset "comparison receipt binds exact comparator evidence" begin
    mktempdir() do directory
        reference = joinpath(directory, "reference")
        candidate = joinpath(directory, "candidate")
        mkpath(reference)
        mkpath(candidate)
        for index in 1:57
            filename = "output-$(lpad(index, 2, '0')).nc"
            write(joinpath(reference, filename), "same-$index")
            write(joinpath(candidate, filename), "same-$index")
        end
        log = joinpath(directory, "comparison.log")
        comparator = joinpath(directory, "comparator.jl")
        patch = joinpath(directory, "instrumentation.patch")
        binary = joinpath(directory, "CLASSIC_serial")
        job = joinpath(directory, "job.txt")
        parameters = joinpath(directory, "params.nml")
        initialization = joinpath(directory, "init.nc")
        write(log, "57 files compared\noverall: PASS\n")
        foreach(
            path -> write(path, basename(path)),
            (comparator, patch, binary, job, parameters, initialization),
        )
        receipt_path = joinpath(directory, "comparison.toml")
        receipt = record_receipt(
            receipt_path,
            reference,
            candidate,
            log,
            comparator,
            patch,
            binary,
            job,
            parameters,
            initialization,
        )
        @test receipt["result"] == "pass"
        @test receipt["compared_files"] == 57
        @test receipt["comparison_log_sha256"] == sha256sum(log)

        write(log, "overall: FAIL\n")
        @test_throws ErrorException record_receipt(
            joinpath(directory, "rejected.toml"),
            reference,
            candidate,
            log,
            comparator,
            patch,
            binary,
            job,
            parameters,
            initialization,
        )
    end
end
