function synthetic_measurement_receipt(schema, scale)
    state_names = [
        field["name"] for
        field in schema["field"] if field["section"] == "reference_state"
    ]
    flux_names = [
        field["name"] for
        field in schema["field"] if field["section"] == "audit_diagnostics"
    ]
    state = Dict(name => scale for name in state_names)
    flux = Dict(name => 2 * scale for name in flux_names)
    return Dict(
        "schema_version" => 1,
        "status" => "pass",
        "initialization_count" => 1,
        "recurrent_state_replacements" => 0,
        "max_state_error" => maximum(values(state); init = 0.0),
        "max_flux_error" => maximum(values(flux); init = 0.0),
        "max_state_errors" => state,
        "max_flux_errors" => flux,
        "max_carbon_closure" => 3 * scale,
        "accumulated_drift" => -4 * scale,
    )
end

function synthetic_tolerance_contract(directory, schema)
    measurements = Dict{String, Any}[]
    sites = ("DE-Hai", "GF-Guy", "BR-Sa1")
    for (index, scale) in enumerate((1.0e-15, 2.0e-15, 3.0e-15))
        path = joinpath(directory, "measurement_$index.toml")
        write_toml_fixture(path, synthetic_measurement_receipt(schema, scale))
        measurement = Dict(
            "site" => sites[index],
            "evidence_id" => relpath(path, directory),
            "sha256" => bytes2hex(open(SHA.sha256, path)),
        )
        if sites[index] == "BR-Sa1"
            gate_path = joinpath(directory, "br_gate_refinement.toml")
            gate = Dict(
                "schema_version" => 1,
                "site" => "BR-Sa1",
                "status" => "pass",
                "result" => "accepted_split_day_one_gate",
                "source_formula_order_match" => true,
                "model_source_changed" => false,
                "accepted_replay" => Dict(
                    "path" => abspath(path),
                    "sha256" => measurement["sha256"],
                ),
                "gfortran_probe" => Dict(
                    "libm_sha256" => repeat("a", 64),
                    "libgfortran_sha256" => repeat("b", 64),
                ),
                "pinned_fortran_source" => Dict(
                    "sha256" => repeat("c", 64),
                    "source_commit" => repeat("d", 40),
                ),
            )
            write_toml_fixture(gate_path, gate)
            measurement["gate_refinement_evidence_id"] =
                relpath(gate_path, directory)
            measurement["gate_refinement_sha256"] =
                bytes2hex(open(SHA.sha256, gate_path))
        end
        push!(measurements, measurement)
    end
    state_names = [
        field["name"] for
        field in schema["field"] if field["section"] == "reference_state"
    ]
    flux_names = [
        field["name"] for
        field in schema["field"] if field["section"] == "audit_diagnostics"
    ]
    safety_factor = 10.0
    records = Dict{String, Any}[]
    for (family, names, observed) in (
        ("state", state_names, 3.0e-15),
        ("flux", flux_names, 6.0e-15),
        ("budget", ["carbon_closure"], 3 * 3.0e-15),
        ("drift", ["accumulated_drift"], 4 * 3.0e-15),
    )
        append!(
            records,
            [
                Dict(
                    "name" => name,
                    "family" => family,
                    "observed_maximum_absolute_error" => observed,
                    "safety_factor" => safety_factor,
                    "absolute_tolerance" => observed * safety_factor,
                ) for name in names
            ],
        )
    end
    contract = Dict(
        "schema_version" => 1,
        "oracle_contract" => "stage_b_v5",
        "rationale" => "Synthetic contract used only for loader validation.",
        "measurement_receipt" => measurements,
        "field" => records,
    )
    path = joinpath(directory, "tolerances.toml")
    write_toml_fixture(path, contract)
    return path, contract
end

@testset "tolerance contract is hash-bound and measurement-derived" begin
    schema = Main.ClassicTrajectoryBundle.load_bundle_schema(
        PROCESS_TRAJECTORY_SCHEMA,
    )
    checked = TOML.parsefile(joinpath(@__DIR__, "tolerances.toml"))
    @test length(checked["measurement_receipt"]) == 3
    @test all(
        occursin(r"^[0-9a-f]{64}$", receipt["sha256"]) for
        receipt in checked["measurement_receipt"]
    )
    @test Set(getindex.(checked["measurement_receipt"], "site")) ==
          Set(("DE-Hai", "GF-Guy", "BR-Sa1"))

    mktempdir() do directory
        path, source = synthetic_tolerance_contract(directory, schema)
        loaded =
            load_tolerance_contract(path, schema; evidence_root = directory)
        @test Set(keys(loaded.budget)) == Set(("carbon_closure",))
        @test Set(keys(loaded.drift)) == Set(("accumulated_drift",))
        @test loaded.sha256 == bytes2hex(open(SHA.sha256, path))
        @test length(loaded.measurement_receipts) == 3

        forged = deepcopy(source)
        first(forged["measurement_receipt"])["sha256"] = repeat("f", 64)
        write_toml_fixture(path, forged)
        @test_throws ArgumentError load_tolerance_contract(
            path,
            schema;
            evidence_root = directory,
        )


        forged_gate = deepcopy(source)
        br = only(
            measurement for
            measurement in forged_gate["measurement_receipt"] if
            measurement["site"] == "BR-Sa1"
        )
        br["gate_refinement_sha256"] = repeat("f", 64)
        write_toml_fixture(path, forged_gate)
        @test_throws ArgumentError load_tolerance_contract(
            path,
            schema;
            evidence_root = directory,
        )

        omitted_br = deepcopy(source)
        filter!(
            measurement -> measurement["site"] != "BR-Sa1",
            omitted_br["measurement_receipt"],
        )
        observed_without_br = Dict(
            "state" => 2.0e-15,
            "flux" => 4.0e-15,
            "budget" => 6.0e-15,
            "drift" => 8.0e-15,
        )
        for field in omitted_br["field"]
            field["observed_maximum_absolute_error"] =
                observed_without_br[field["family"]]
            field["absolute_tolerance"] =
                field["observed_maximum_absolute_error"] *
                field["safety_factor"]
        end
        write_toml_fixture(path, omitted_br)
        @test_throws ArgumentError load_tolerance_contract(
            path,
            schema;
            evidence_root = directory,
        )
        fabricated = deepcopy(source)
        field = first(fabricated["field"])
        field["observed_maximum_absolute_error"] *= 2
        field["absolute_tolerance"] =
            field["observed_maximum_absolute_error"] * field["safety_factor"]
        write_toml_fixture(path, fabricated)
        @test_throws ArgumentError load_tolerance_contract(
            path,
            schema;
            evidence_root = directory,
        )

        failed = deepcopy(source)
        receipt_path = joinpath(
            directory,
            first(failed["measurement_receipt"])["evidence_id"],
        )
        receipt = TOML.parsefile(receipt_path)
        receipt["status"] = "fail"
        write_toml_fixture(receipt_path, receipt)
        first(failed["measurement_receipt"])["sha256"] =
            bytes2hex(open(SHA.sha256, receipt_path))
        write_toml_fixture(path, failed)
        @test_throws ArgumentError load_tolerance_contract(
            path,
            schema;
            evidence_root = directory,
        )

        missing = deepcopy(source)
        delete!(missing, "measurement_receipt")
        write_toml_fixture(path, missing)
        @test_throws ArgumentError load_tolerance_contract(
            path,
            schema;
            evidence_root = directory,
        )
    end
end

@testset "tolerance evidence identifiers are root-relative and contained" begin
    schema = Main.ClassicTrajectoryBundle.load_bundle_schema(
        PROCESS_TRAJECTORY_SCHEMA,
    )
    mktempdir() do directory
        @test_throws ArgumentError Main.ClassicToleranceContract.evidence_root_from_env(
            Dict{String, String}(),
        )
        @test Main.ClassicToleranceContract.evidence_root_from_env(
            Dict("CLASSIC_TOLERANCE_EVIDENCE_ROOT" => directory),
        ) == realpath(directory)
        linked_root =
            joinpath(dirname(directory), basename(directory) * "-link")
        symlink(directory, linked_root)
        @test_throws ArgumentError Main.ClassicToleranceContract.evidence_root_from_env(
            Dict("CLASSIC_TOLERANCE_EVIDENCE_ROOT" => linked_root),
        )
        path, source = synthetic_tolerance_contract(directory, schema)
        @test_throws ArgumentError load_tolerance_contract(path, schema)

        portable = deepcopy(source)
        write_toml_fixture(path, portable)
        loaded =
            load_tolerance_contract(path, schema; evidence_root = directory)
        @test all(
            !isabspath(receipt.evidence_id) for
            receipt in loaded.measurement_receipts
        )

        absolute = deepcopy(portable)
        first(absolute["measurement_receipt"])["evidence_id"] =
            joinpath(directory, "measurement_1.toml")
        write_toml_fixture(path, absolute)
        @test_throws ArgumentError load_tolerance_contract(
            path,
            schema;
            evidence_root = directory,
        )

        escaped = deepcopy(portable)
        first(escaped["measurement_receipt"])["evidence_id"] =
            joinpath("..", "measurement_1.toml")
        write_toml_fixture(path, escaped)
        @test_throws ArgumentError load_tolerance_contract(
            path,
            schema;
            evidence_root = directory,
        )

        mktempdir() do outside
            receipt = first(portable["measurement_receipt"])
            cp(
                joinpath(directory, receipt["evidence_id"]),
                joinpath(outside, "receipt.toml"),
            )
            symlink(outside, joinpath(directory, "escape"))
            symlink_escape = deepcopy(portable)
            first(symlink_escape["measurement_receipt"])["evidence_id"] =
                joinpath("escape", "receipt.toml")
            write_toml_fixture(path, symlink_escape)
            @test_throws ArgumentError load_tolerance_contract(
                path,
                schema;
                evidence_root = directory,
            )
        end
    end
end
