using Test

@testset "candidate reconstruction" begin
    @testset "CASA PFT field mutation" begin
        source = [
            "prefix,unchanged\n",
            ",N/Cleafmi,N/Cleafmx,nfixrate,\n",
            "vegtype,g N/g C,g N/g C,g N/m2/yr,\n",
            "1,0.02,0.024,0.08,\n",
            "2,0.025,0.048,2.6,\n",
        ]
        mutation = Dict(
            "type" => "casa_pft_field",
            "section" => "N/Cleafmi",
            "pft" => 1,
            "field" => "nfixrate",
            "before" => "0.08",
            "after" => "0.21",
        )

        derived, record = apply_mutation(source, mutation)

        @test derived[4] == "1,0.02,0.024,0.21,\n"
        @test derived[[1, 2, 3, 5]] == source[[1, 2, 3, 5]]
        @test record["line"] == 4
        @test record["field"] == "nfixrate"
        @test record["before"] == "0.08"
        @test record["after"] == "0.21"
        @test record["changed"]

        wrong = copy(mutation)
        wrong["before"] = "0.09"
        @test_throws ErrorException apply_mutation(source, wrong)

        absent = copy(mutation)
        absent["pft"] = 3
        later_section = [source..., ",other,field,nfixrate,\n", "3,x,y,0.08,\n"]
        @test_throws ErrorException apply_mutation(later_section, absent)
    end

    @testset "named MIMICS parameter mutation" begin
        source = [
            "4,KO(1),description\r\n",
            "4,KO(2),description\r\n",
            "0.30,FI(struc) ,description\r\n",
        ]
        mutation = Dict(
            "type" => "named_parameter",
            "name" => "KO(2)",
            "before" => "4",
            "after" => "6",
        )

        derived, record = apply_mutation(source, mutation)

        @test derived == [source[1], "6,KO(2),description\r\n", source[3]]
        @test record["line"] == 2
        @test record["name"] == "KO(2)"
    end

    @testset "control line mutation" begin
        source = ["4263 !! points\n", "2 !! soil model\n", "2 !! cycle\n"]
        mutation = Dict(
            "type" => "control_line",
            "line" => 3,
            "field" => "cycle",
            "before" => "2",
            "after" => "1",
        )

        derived, record = apply_mutation(source, mutation)

        @test derived[3] == "1 !! cycle\n"
        @test record["field"] == "cycle"
        @test record["changed"]
    end

    @testset "auditable candidate set" begin
        mktempdir() do root
            source_root = joinpath(root, "source")
            output_root = joinpath(root, "output")
            mkpath(source_root)
            write(joinpath(source_root, "parameters.csv"), "4,KO(1),x\n")
            spec = Dict(
                "schema_version" => 1,
                "source_commit" => "unavailable-in-unit-test",
                "candidate" => [
                    Dict(
                        "id" => "ko6",
                        "kind" => "mimics_parameter",
                        "source" => "parameters.csv",
                        "destination" => "parameters/ko6.candidate.csv",
                        "confidence" => "high",
                        "evidence" => ["README: KO=6"],
                        "rejected_alternative" =>
                            ["KO=9 belongs to another branch"],
                        "mutation" => [
                            Dict(
                                "type" => "named_parameter",
                                "name" => "KO(1)",
                                "before" => "4",
                                "after" => "6",
                            ),
                        ],
                    ),
                ],
            )
            spec_path = joinpath(root, "spec.toml")
            open(spec_path, "w") do io
                TOML.print(io, spec; sorted = true)
            end

            report_path = derive_candidates(source_root, output_root, spec_path)
            report = TOML.parsefile(report_path)
            candidate = only(report["candidate"])

            @test read(
                joinpath(output_root, "parameters", "ko6.candidate.csv"),
                String,
            ) == "6,KO(1),x\n"
            @test report["schema_version"] == 1
            @test candidate["id"] == "ko6"
            @test candidate["source_sha256"] != candidate["derived_sha256"]
            @test candidate["confidence"] == "high"
            @test candidate["evidence"] == ["README: KO=6"]
            @test candidate["rejected_alternative"] ==
                  ["KO=9 belongs to another branch"]
            @test only(candidate["diff"])["changed"]

            single_path = joinpath(root, "single", "ko6.csv")
            single =
                derive_candidate(source_root, "ko6", single_path, spec_path)
            @test read(single_path, String) == "6,KO(1),x\n"
            @test single["id"] == "ko6"
            @test_throws ErrorException derive_candidate(
                source_root,
                "missing-candidate",
                joinpath(root, "missing.csv"),
                spec_path,
            )

            @test_throws ErrorException derive_candidates(
                source_root,
                source_root,
                spec_path,
            )
            @test_throws ErrorException derive_candidates(
                source_root,
                root,
                spec_path,
            )

            symlink_root = joinpath(root, "symlink-output")
            mkpath(symlink_root)
            symlink(source_root, joinpath(symlink_root, "parameters"))
            @test_throws ErrorException derive_candidates(
                source_root,
                symlink_root,
                spec_path,
            )

            @test_throws ErrorException assert_disjoint_roots(
                source_root,
                joinpath(source_root, "runs"),
                "source",
                "run",
            )
            symlink_run = joinpath(root, "symlink-run")
            symlink(source_root, symlink_run)
            @test_throws ErrorException assert_disjoint_roots(
                source_root,
                symlink_run,
                "source",
                "run",
            )

            candidate_path =
                joinpath(output_root, "parameters", "ko6.candidate.csv")
            valid_candidate = read(candidate_path, String)
            spec["candidate"][1]["mutation"][1]["after"] = "7"
            spec["candidate"][1]["expected_derived_sha256"] = "wrong"
            open(spec_path, "w") do io
                TOML.print(io, spec; sorted = true)
            end
            @test_throws ErrorException derive_candidates(
                source_root,
                output_root,
                spec_path,
            )
            @test read(candidate_path, String) == valid_candidate

            spec["candidate"][1]["expected_source_sha256"] = "wrong"
            open(spec_path, "w") do io
                TOML.print(io, spec; sorted = true)
            end
            @test_throws ErrorException derive_candidates(
                source_root,
                joinpath(root, "wrong-hash-output"),
                spec_path,
            )
        end
    end

    @testset "validation input hashes" begin
        mktempdir() do root
            input = joinpath(root, "input.txt")
            write(input, "pinned\n")
            spec = Dict(
                "validation_input" => [
                    Dict("path" => "input.txt", "sha256" => sha256sum(input)),
                ],
            )

            records = verify_validation_inputs(root, spec)
            @test only(records)["path"] == "input.txt"
            @test only(records)["sha256"] == sha256sum(input)

            write(input, "modified\n")
            @test_throws ErrorException verify_validation_inputs(root, spec)
        end
    end

    @testset "fixture input hashes" begin
        mktempdir() do root
            fixture = Dict{String, Any}()
            for key in ("grid", "soil", "driver")
                path = joinpath(root, "$key.dat")
                write(path, "$key\n")
                fixture[key] = Dict(
                    "filename" => basename(path),
                    "bytes" => filesize(path),
                    "sha256" => sha256sum(path),
                )
            end
            open(joinpath(root, "fixture.toml"), "w") do io
                TOML.print(io, Dict("fixture" => fixture); sorted = true)
            end

            records = verify_fixture_inputs(root)
            @test Set(record["id"] for record in records) ==
                  Set(("grid", "soil", "driver"))

            write(joinpath(root, "soil.dat"), "modified\n")
            @test_throws ErrorException verify_fixture_inputs(root)
        end
    end

    @testset "production specification" begin
        spec = TOML.parsefile(CANDIDATE_SPEC_PATH)
        candidates = Dict(item["id"] => item for item in spec["candidate"])

        @test spec["source_commit"] ==
              "27ae1a0b673411642cd780ecad66d1c8f84e6a58"
        @test Set(keys(candidates)) >= Set((
            "casa_boreal_nfix",
            "mimics_ko6_fi30",
            "mimics_ko6_fi10",
            "mimics_ko6_fi05",
            "casa_cn_prespin",
            "mimics_cn_prespin_fi30",
            "mimics_cn_prespin_fi10",
            "mimics_cn_prespin_fi05",
            "casa_c_prespin",
            "mimics_c_prespin",
        ))
        @test candidates["casa_boreal_nfix"]["confidence"] == "high"
        @test all(
            haskey(candidate, "expected_source_sha256") &&
            haskey(candidate, "expected_derived_sha256") for
            candidate in values(candidates)
        )
        @test length(spec["validation_input"]) >= 6
        @test length(candidates["mimics_ko6_fi30"]["mutation"]) == 2
        @test length(candidates["mimics_ko6_fi10"]["mutation"]) == 3
        @test length(candidates["mimics_ko6_fi05"]["mutation"]) == 3
        case_cycles =
            Dict(case.id => string(case.cycle) for case in validation_cases())
        @test all(
            candidate["kind"] != "control" || any(
                mutation ->
                    get(mutation, "field", "") == "cycle" &&
                        mutation["after"] == case_cycles[candidate["id"]],
                candidate["mutation"],
            ) for candidate in values(candidates)
        )
        cn_control_ids = (
            "casa_cn_prespin",
            "mimics_cn_prespin_fi30",
            "mimics_cn_prespin_fi10",
            "mimics_cn_prespin_fi05",
        )
        @test all(
            any(
                mutation ->
                    get(mutation, "field", "") == "casa_parameters" &&
                        occursin(".candidate.csv", mutation["after"]),
                candidates[id]["mutation"],
            ) for id in cn_control_ids
        )
        @test all(
            any(
                mutation ->
                    get(mutation, "field", "") == "mimics_parameters" &&
                        occursin(".candidate.csv", mutation["after"]),
                candidates[id]["mutation"],
            ) for id in cn_control_ids[2:end]
        )
    end

    @testset "reduced-prespin validation matrix" begin
        cases = Dict(item.id => item for item in validation_cases())
        spec = TOML.parsefile(CANDIDATE_SPEC_PATH)
        candidates = Dict(item["id"] => item for item in spec["candidate"])

        @test Set(keys(cases)) == Set(keys(candidates))
        @test cases["casa_boreal_nfix"].soil_model == 1
        @test cases["casa_boreal_nfix"].cycle == 2
        @test cases["mimics_ko6_fi30"].soil_model == 2
        @test cases["mimics_ko6_fi30"].cycle == 2
        @test cases["casa_cn_prespin"].soil_model == 1
        @test cases["casa_cn_prespin"].cycle == 2
        @test !isnothing(cases["casa_cn_prespin"].control_candidate)
        @test cases["mimics_cn_prespin_fi30"].soil_model == 2
        @test cases["mimics_cn_prespin_fi30"].cycle == 2
        @test !isnothing(cases["mimics_cn_prespin_fi30"].control_candidate)
        @test cases["casa_c_prespin"].cycle == 1
        @test cases["mimics_c_prespin"].cycle == 1
        @test all(
            (candidates[id]["kind"] == "control") ==
            !isnothing(case.control_candidate) for (id, case) in cases
        )
    end


    @testset "control candidate reduction" begin
        harness = reference_harness_module()
        mktempdir() do root
            source = harness.write_smoke_control(
                root;
                points = 4263,
                loops = 17,
                initialization = 2,
                years = (1901, 2014),
                soil_model = 1,
                cycle = 1,
            )
            destination = joinpath(root, "reduced.lst")
            case = only(
                filter(item -> item.id == "casa_c_history", validation_cases()),
            )

            record = write_reduced_candidate_control(source, destination, case)
            reduced = harness.parse_control(destination)

            @test reduced[:points] == 1
            @test reduced[:loops] == 1
            @test reduced[:initialization] == 0
            @test reduced[:soil_model] == 1
            @test reduced[:cycle] == 1
            @test record["source_sha256"] == sha256sum(source)
            @test record["derived_sha256"] == sha256sum(destination)
            reduced_fields = Set(item["field"] for item in record["diff"])
            @test !isempty(reduced_fields)
            @test length(reduced_fields) < length(harness.CONTROL_FIELDS)
            @test !in("soil_model", reduced_fields)
            @test !in("cycle", reduced_fields)
            @test reduced[:vegetation_types] ==
                  harness.parse_control(source)[:vegetation_types]
            @test reduced[:netcdf_interval] ==
                  harness.parse_control(source)[:netcdf_interval]
        end
    end
end
