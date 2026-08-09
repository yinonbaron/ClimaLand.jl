using Test
using TOML

import NCDatasets

include("campaign.jl")
using .ClassicAllSitesCampaign:
    compare_published_site,
    discover_sites,
    write_campaign_summary,
    write_site_receipt

function write_test_output(path, values; units = "kg C m-2")
    NCDatasets.NCDataset(path, "c") do dataset
        NCDatasets.defDim(dataset, "lon", 1)
        NCDatasets.defDim(dataset, "lat", 1)
        NCDatasets.defDim(dataset, "time", length(values))

        lon = NCDatasets.defVar(dataset, "longitude", Float64, ("lon",))
        lon.attrib["units"] = "degrees_east"
        lon[:] = [10.0]
        lat = NCDatasets.defVar(dataset, "latitude", Float64, ("lat",))
        lat.attrib["units"] = "degrees_north"
        lat[:] = [51.0]
        time = NCDatasets.defVar(dataset, "time", Float64, ("time",))
        time.attrib["units"] = "days since 2000-01-01 00:00"
        time.attrib["calendar"] = "standard"
        time[:] = collect(1:length(values))

        stock =
            NCDatasets.defVar(dataset, "cSoil", Float64, ("time", "lat", "lon"))
        stock.attrib["units"] = units
        stock[:] = reshape(values, length(values), 1, 1)
    end
end

function write_artifact(path, contents = basename(path))
    mkpath(dirname(path))
    write(path, contents)
    return path
end

function write_sha_manifest(path, files)
    lines = [
        "$(ClassicAllSitesCampaign.sha256_file(file))  $(abspath(file))" for
        file in files
    ]
    write(path, join(lines, "\n") * "\n")
    return path
end

function write_test_site_receipt(
    root,
    site;
    comparison_exit_code = 0,
    comparison_status = "mismatch",
)
    evidence = joinpath(root, "evidence", site)
    run_site = joinpath(root, "run", site)
    output = joinpath(root, "run", "outputFiles", site, "netCDF")
    mkpath.((evidence, run_site, output))

    command =
        write_artifact(joinpath(evidence, "command.txt"), "classic options\n")
    run_log = write_artifact(joinpath(evidence, "run.log"), "completed\n")
    job_options =
        write_artifact(joinpath(run_site, "job_options_file.txt"), "options\n")
    initialization =
        write_artifact(joinpath(run_site, "$(site)_init.nc"), "initial state\n")
    restart = write_artifact(joinpath(run_site, "rsfile.nc"), "final state\n")
    output_file = write_artifact(joinpath(output, "cSoil_daily.nc"), "output\n")
    prepared = write_sha_manifest(
        joinpath(evidence, "prepared-inputs.sha256"),
        [job_options, initialization],
    )
    initial = joinpath(evidence, "initial-restart.sha256")
    write(
        initial,
        "$(ClassicAllSitesCampaign.sha256_file(initialization))  $(abspath(restart))\n",
    )
    final = write_sha_manifest(
        joinpath(evidence, "final-restart.sha256"),
        [restart],
    )
    outputs =
        write_sha_manifest(joinpath(evidence, "outputs.sha256"), [output_file])
    comparison = write_artifact(
        joinpath(evidence, "published-comparison.toml"),
        "schema_version = 1\nsite = \"$site\"\nstatus = \"$comparison_status\"\ncandidate_kind = \"fresh_local_fortran\"\nreference_kind = \"published_benchmark\"\npublished_parity_claimed = false\ncandidate_directory = \"$(abspath(output))\"\n",
    )

    receipt_path = joinpath(evidence, "receipt.toml")
    write_site_receipt(
        site,
        evidence,
        run_site,
        output,
        receipt_path;
        run_exit_code = 0,
        comparison_exit_code,
    )
    return (;
        evidence,
        run_site,
        output,
        receipt_path,
        command,
        run_log,
        prepared,
        initial,
        final,
        outputs,
        comparison,
        job_options,
        initialization,
        restart,
        output_file,
    )
end

@testset "campaign site inventory is fail closed" begin
    mktempdir() do root
        configurations = joinpath(root, "configurations")
        published = joinpath(root, "published")
        for site in ("AA-One", "BB-Two")
            mkpath(joinpath(configurations, site))
            mkpath(joinpath(published, site, "netCDF"))
        end

        @test discover_sites(configurations, published; expected_count = 2) ==
              ["AA-One", "BB-Two"]
        @test_throws ArgumentError discover_sites(
            configurations,
            published;
            expected_count = 59,
        )

        mkpath(joinpath(published, "CC-OnlyPublished", "netCDF"))
        error = try
            discover_sites(configurations, published; expected_count = 3)
            nothing
        catch exception
            exception
        end
        @test error isa ArgumentError
        @test occursin("published-only", sprint(showerror, error))
    end
end

@testset "published comparison records mismatch without relabeling the oracle" begin
    mktempdir() do root
        published = joinpath(root, "published")
        local_fortran = joinpath(root, "local")
        mkpath.((published, local_fortran))
        write_test_output(joinpath(published, "cSoil_daily.nc"), [1.0, 2.0])
        write_test_output(joinpath(local_fortran, "cSoil_daily.nc"), [1.0, 3.0])

        summary_path = joinpath(root, "published-comparison.toml")
        summary = compare_published_site(
            "AA-One",
            published,
            local_fortran,
            summary_path,
        )
        recorded = TOML.parsefile(summary_path)

        @test summary.status == "mismatch"
        @test summary.compared_files == 1
        @test summary.failed_files == 1
        @test recorded["reference_kind"] == "published_benchmark"
        @test recorded["candidate_kind"] == "fresh_local_fortran"
        @test recorded["published_parity_claimed"] == false
        @test recorded["status"] == "mismatch"
        @test recorded["file"][1]["values_match"] == false
    end
end

@testset "site receipts retain and verify the local oracle evidence" begin
    mktempdir() do root
        evidence = joinpath(root, "evidence", "AA-One")
        run_site = joinpath(root, "run", "AA-One")
        output = joinpath(root, "run", "outputFiles", "AA-One", "netCDF")
        mkpath.((evidence, run_site, output))

        write_artifact(
            joinpath(evidence, "command.txt"),
            "classic job_options_file.txt\n",
        )
        write_artifact(joinpath(evidence, "run.log"), "completed\n")
        write_artifact(joinpath(evidence, "prepared-inputs.sha256"), "inputs\n")
        write_artifact(
            joinpath(evidence, "initial-restart.sha256"),
            "initial\n",
        )
        write_artifact(joinpath(evidence, "final-restart.sha256"), "final\n")
        write_artifact(joinpath(evidence, "outputs.sha256"), "outputs\n")
        write_artifact(
            joinpath(evidence, "published-comparison.toml"),
            "status = \"mismatch\"\n",
        )
        write_artifact(joinpath(run_site, "job_options_file.txt"), "options\n")
        write_artifact(joinpath(run_site, "AA-One_init.nc"), "initial state\n")
        write_artifact(joinpath(run_site, "rsfile.nc"), "final state\n")
        write_artifact(joinpath(output, "cSoil_daily.nc"), "output\n")

        receipt_path = joinpath(evidence, "receipt.toml")
        receipt = write_site_receipt(
            "AA-One",
            evidence,
            run_site,
            output,
            receipt_path;
            run_exit_code = 0,
            comparison_exit_code = 0,
        )
        recorded = TOML.parsefile(receipt_path)

        @test receipt.local_oracle_status == "available"
        @test recorded["local_oracle_kind"] == "fresh_local_fortran"
        @test recorded["local_oracle_status"] == "available"
        @test recorded["published_comparison_status"] == "mismatch"
        @test Set(keys(recorded["evidence_sha256"])) == Set((
            "command.txt",
            "run.log",
            "prepared-inputs.sha256",
            "initial-restart.sha256",
            "final-restart.sha256",
            "outputs.sha256",
            "published-comparison.toml",
            "job_options_file.txt",
            "AA-One_init.nc",
            "rsfile.nc",
        ))

        rm(joinpath(evidence, "run.log"))
        @test_throws ArgumentError write_site_receipt(
            "AA-One",
            evidence,
            run_site,
            output,
            receipt_path;
            run_exit_code = 0,
            comparison_exit_code = 0,
        )
    end
end

@testset "campaign summary revalidates every retained evidence hash" begin
    for field in (
        :command,
        :run_log,
        :prepared,
        :initial,
        :final,
        :outputs,
        :comparison,
        :job_options,
        :initialization,
        :restart,
    )
        mktempdir() do root
            fixture = write_test_site_receipt(root, "AA-One")
            summary_path = joinpath(root, "campaign-summary.toml")
            @test write_campaign_summary(
                ["AA-One"],
                joinpath(root, "evidence"),
                summary_path,
            ).ok

            open(getproperty(fixture, field), "a") do io
                write(io, "tampered\n")
            end
            @test_throws ArgumentError write_campaign_summary(
                ["AA-One"],
                joinpath(root, "evidence"),
                summary_path,
            )
        end
    end
end

@testset "campaign completion rejects missing output evidence" begin
    mktempdir() do root
        fixture = write_test_site_receipt(root, "AA-One")
        rm(fixture.output_file)
        @test_throws ArgumentError write_campaign_summary(
            ["AA-One"],
            joinpath(root, "evidence"),
            joinpath(root, "campaign-summary.toml"),
        )
    end
end

@testset "published mismatch requires a successful comparison command" begin
    mktempdir() do root
        write_test_site_receipt(root, "AA-One"; comparison_exit_code = 2)
        @test_throws ArgumentError write_campaign_summary(
            ["AA-One"],
            joinpath(root, "evidence"),
            joinpath(root, "campaign-summary.toml"),
        )
    end
end

@testset "receipt paths cannot be redirected after recording" begin
    mktempdir() do root
        fixture = write_test_site_receipt(root, "AA-One")
        receipt = TOML.parsefile(fixture.receipt_path)
        receipt["run_site_directory"] = joinpath(root, "run", "elsewhere")
        open(fixture.receipt_path, "w") do io
            TOML.print(io, receipt; sorted = true)
        end
        @test_throws ArgumentError write_campaign_summary(
            ["AA-One"],
            joinpath(root, "evidence"),
            joinpath(root, "campaign-summary.toml"),
        )
    end
end

@testset "campaign summary requires every site and separates statuses" begin
    mktempdir() do root
        evidence = joinpath(root, "evidence")
        write_test_site_receipt(root, "AA-One"; comparison_status = "match")
        write_test_site_receipt(root, "BB-Two")

        summary_path = joinpath(root, "campaign-summary.toml")
        summary =
            write_campaign_summary(["AA-One", "BB-Two"], evidence, summary_path)
        recorded = TOML.parsefile(summary_path)
        @test summary.ok
        @test summary.local_oracle_available == 2
        @test summary.published_matches == 1
        @test summary.published_mismatches == 1
        @test recorded["campaign_status"] == "complete"
        @test recorded["published_parity_claimed"] == false

        rm(joinpath(evidence, "BB-Two", "receipt.toml"))
        @test_throws ArgumentError write_campaign_summary(
            ["AA-One", "BB-Two"],
            evidence,
            summary_path,
        )
    end
end
