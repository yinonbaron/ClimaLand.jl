using Test
import SHA
import TOML

include("process_stress_matrix.jl")
using .CLASSICProcessStressMatrix

function write_fixture(path, contents)
    mkpath(dirname(path))
    write(path, contents)
    return path
end

@testset "process-stress matrix contract" begin
    matrix = TOML.parsefile(joinpath(@__DIR__, "selection_matrix.toml"))
    metrics_path = joinpath(@__DIR__, "site_metrics.toml")
    receipts_path = joinpath(@__DIR__, "input_receipts.toml")
    metrics_inventory = TOML.parsefile(metrics_path)
    receipt_inventory = TOML.parsefile(receipts_path)
    @test matrix["schema_version"] == 1
    @test matrix["inventory"]["site_count"] == 59
    @test receipt_inventory["schema_version"] == 2
    @test receipt_inventory["path_root"] == "CLASSIC_REFERENCE_ROOT"
    @test metrics_inventory["site_count"] == 59
    @test receipt_inventory["site_count"] == 59
    @test length(unique(site["site"] for site in metrics_inventory["site"])) ==
          59
    @test length(unique(site["site"] for site in receipt_inventory["site"])) ==
          59
    @test matrix["inventory"]["site_metrics_sha256"] ==
          bytes2hex(open(SHA.sha256, metrics_path))
    @test matrix["inventory"]["input_receipts_sha256"] ==
          bytes2hex(open(SHA.sha256, receipts_path))
    @test matrix["acceptance"]["status"] == "ready_for_acceptance"
    @test matrix["acceptance"]["seasonal_parity_claimed"] === true
    @test matrix["acceptance"]["approval_status"] ==
          "direct_user_approval_recorded"
    manifest_path = joinpath(@__DIR__, "canonical_archives.toml")
    @test matrix["acceptance"]["canonical_archive_manifest"] ==
          "canonical_archives.toml"
    @test matrix["acceptance"]["canonical_archive_manifest_sha256"] ==
          bytes2hex(open(SHA.sha256, manifest_path))
    @test !haskey(matrix["acceptance"], "blocked_reason")

    selections = matrix["selection"]
    @test Set(s["class"] for s in selections) == Set((
        "tropical_warm_wet",
        "seasonal_dry",
        "wet_mineral",
        "cold_freeze_thaw",
    ))
    @test length(unique(s["site"] for s in selections)) == 4
    @test all(s["criteria_passed"] for s in selections)

    for receipt in receipt_inventory["site"]
        @test receipt["raw_data_embedded"] == false
        @test all(!isabspath(path) for path in values(receipt["input_path"]))
        @test all(
            !isabspath(path) && !startswith(normpath(path), "..") for
            path in values(receipt["input_path"])
        )
        @test all(
            occursin(r"^[0-9a-f]{64}$", hash) for
            hash in values(receipt["input_sha256"])
        )
    end

    for selection in selections
        metrics = selection["metrics"]
        class = selection["class"]
        @test metrics["record_count"] > 0
        @test metrics["air_temperature_min_c"] <=
              metrics["air_temperature_mean_c"] <=
              metrics["air_temperature_max_c"]
        @test metrics["annual_precipitation_mean_mm"] >= 0
        @test metrics["maximum_dry_spell_days"] >= 0
        @test metrics["freeze_thaw_transition_count"] >= 0
        @test metrics["mineral_layer_fraction"] >= 0
        @test metrics["mineral_layer_fraction"] <= 1
        @test selection_passes(class, metrics, matrix["criteria"][class])
    end
end

@testset "selection rules fail closed" begin
    criteria = Dict(
        "absolute_latitude_max_deg" => 23.5,
        "mean_air_temperature_min_c" => 20.0,
        "annual_precipitation_min_mm" => 1000.0,
        "dry_month_fraction_max" => 0.25,
    )
    passing = Dict(
        "absolute_latitude_deg" => 5.0,
        "air_temperature_mean_c" => 24.0,
        "annual_precipitation_mean_mm" => 2000.0,
        "dry_month_fraction" => 0.1,
    )
    @test selection_passes("tropical_warm_wet", passing, criteria)
    @test !selection_passes(
        "tropical_warm_wet",
        merge(passing, Dict("dry_month_fraction" => 0.5)),
        criteria,
    )
    @test_throws ArgumentError selection_passes(
        "tropical_warm_wet",
        delete!(copy(passing), "dry_month_fraction"),
        criteria,
    )
    @test_throws ArgumentError selection_passes("unknown", passing, criteria)
end

@testset "receipt hashes all released inputs without embedding raw data" begin
    mktempdir() do directory
        source = write_fixture(
            joinpath(directory, "source.toml"),
            "site = \"XX-Aaa\"\n",
        )
        temperature = write_fixture(joinpath(directory, "ta.nc"), "temperature")
        precipitation =
            write_fixture(joinpath(directory, "pr.nc"), "precipitation")
        initialization =
            write_fixture(joinpath(directory, "init.nc"), "initialization")
        output = joinpath(directory, "receipt.toml")

        write_input_receipt(
            output,
            "XX-Aaa",
            Dict(
                "site_metadata" => source,
                "air_temperature_forcing" => temperature,
                "precipitation_forcing" => precipitation,
                "prepared_initialization" => initialization,
            ),
            directory,
        )
        receipt = TOML.parsefile(output)
        @test receipt["schema_version"] == 2
        @test receipt["path_root"] == "CLASSIC_REFERENCE_ROOT"
        @test receipt["site"] == "XX-Aaa"
        @test receipt["raw_data_embedded"] == false
        @test all(!isabspath(path) for path in values(receipt["input_path"]))
        @test Set(keys(receipt["input_sha256"])) == Set((
            "site_metadata",
            "air_temperature_forcing",
            "precipitation_forcing",
            "prepared_initialization",
        ))
        @test receipt["input_sha256"]["air_temperature_forcing"] ==
              bytes2hex(SHA.sha256("temperature"))

        @test verify_input_receipt(output, directory)
        @test_throws MethodError verify_input_receipt(output)

        write(temperature, "changed")
        @test_throws ArgumentError verify_input_receipt(output, directory)
    end
end

@testset "matrix acceptance requires real issue-103 seasonal archives" begin
    matrix_path = joinpath(@__DIR__, "selection_matrix.toml")
    manifest_path = joinpath(@__DIR__, "canonical_archives.toml")
    tolerance_path = joinpath(@__DIR__, "tolerances.toml")
    schema_path = joinpath(@__DIR__, "..", "trajectory_bundle", "schema.toml")
    matrix = TOML.parsefile(matrix_path)
    checked_paths = (
        matrix_path = matrix_path,
        manifest_path = manifest_path,
        tolerance_path = tolerance_path,
        schema_path = schema_path,
    )
    @test !matrix_acceptance_ready(matrix, nothing; checked_paths...)

    ready_matrix = deepcopy(matrix)
    ready_matrix["acceptance"]["status"] = "ready_for_acceptance"
    ready_matrix["acceptance"]["seasonal_parity_claimed"] = true
    selected_sites = [selection["site"] for selection in matrix["selection"]]
    manifest = TOML.parsefile(manifest_path)
    manifest_sites = Dict(site["site"] => site for site in manifest["site"])
    site_results = [
        Dict(
            "name" => site,
            "status" => "pass",
            "archive_sha256" => manifest_sites[site]["archive_sha256"],
            "archive_receipt_sha256" =>
                manifest_sites[site]["receipt_sha256"],
            "max_state_errors" => Dict("state" => 0.0),
            "max_flux_errors" => Dict("flux" => 0.0),
            "max_budget_errors" => Dict("budget" => 0.0),
            "max_drift_errors" => Dict("accumulated_drift" => 0.0),
            "failure_localization" => Any[],
        ) for site in selected_sites
    ]

    mktempdir() do directory
        receipt_path = joinpath(directory, "seasonal-receipt.toml")
        function write_receipt(receipt)
            open(receipt_path, "w") do io
                TOML.print(io, receipt; sorted = true)
            end
            return receipt_path
        end
        function is_ready(receipt, candidate = ready_matrix)
            write_receipt(receipt)
            return matrix_acceptance_ready(
                candidate,
                receipt_path;
                checked_paths...,
            )
        end
        write(
            receipt_path,
            "schema_version = 1\nstatus = \"complete\"\nreference_kind = \"synthetic\"\nsite_count = 4\n",
        )
        @test !matrix_acceptance_ready(
            ready_matrix,
            receipt_path;
            checked_paths...,
        )

        write(
            receipt_path,
            "schema_version = 1\nstatus = \"complete\"\nreference_kind = \"fresh_local_fortran\"\nsite_count = 4\n",
        )
        @test !matrix_acceptance_ready(
            ready_matrix,
            receipt_path;
            checked_paths...,
        )

        receipt = Dict(
            "schema_version" => 1,
            "status" => "complete",
            "reference_kind" => "fresh_local_fortran",
            "site_count" => 4,
            "oracle_contract" => "stage_b_v5",
            "synthetic_data_used" => false,
            "sites" => selected_sites,
            "state_comparisons_passed" => true,
            "flux_comparisons_passed" => true,
            "budget_comparisons_passed" => true,
            "drift_comparisons_passed" => true,
            "tolerance_rationale" => "bit-exact v5",
            "matrix_selection_sha256" =>
                bytes2hex(open(SHA.sha256, matrix_path)),
            "archive_manifest_sha256" =>
                bytes2hex(open(SHA.sha256, manifest_path)),
            "tolerance_contract_sha256" =>
                bytes2hex(open(SHA.sha256, tolerance_path)),
            "trajectory_schema_sha256" =>
                bytes2hex(open(SHA.sha256, schema_path)),
            "tolerances" => Dict(
                "contract_sha256" =>
                    bytes2hex(open(SHA.sha256, tolerance_path)),
            ),
            "site" => site_results,
        )
        @test is_ready(receipt)

        for key in (
            "matrix_selection_sha256",
            "archive_manifest_sha256",
            "tolerance_contract_sha256",
            "trajectory_schema_sha256",
        )
            forged = deepcopy(receipt)
            forged[key] = repeat("0", 64)
            @test !is_ready(forged)
        end
        forged = deepcopy(receipt)
        forged["tolerances"]["contract_sha256"] = repeat("0", 64)
        @test !is_ready(forged)
        forged = deepcopy(receipt)
        first(forged["site"])["archive_sha256"] = repeat("0", 64)
        @test !is_ready(forged)
        forged = deepcopy(receipt)
        first(forged["site"])["archive_receipt_sha256"] = repeat("0", 64)
        @test !is_ready(forged)

        forged_matrix = deepcopy(ready_matrix)
        forged_matrix["inventory"]["site_count"] = 58
        @test !is_ready(receipt, forged_matrix)
        forged = deepcopy(receipt)
        forged["drift_comparisons_passed"] = false
        @test !is_ready(forged)
        forged = deepcopy(receipt)
        delete!(first(forged["site"]), "max_drift_errors")
        @test !is_ready(forged)
        blocked_matrix = deepcopy(ready_matrix)
        blocked_matrix["acceptance"]["status"] = "blocked"
        @test !is_ready(receipt, blocked_matrix)
    end
end
