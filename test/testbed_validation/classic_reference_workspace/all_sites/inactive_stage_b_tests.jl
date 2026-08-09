using Test
import NCDatasets
import SHA
import TOML

include("inactive_stage_b.jl")
using .ClassicInactiveStageB

function write_inactive_fixture(root; ipeatland = 1, mask = Int32[0])
    init_path = joinpath(root, "site_init.nc")
    NCDatasets.NCDataset(init_path, "c") do dataset
        NCDatasets.defDim(dataset, "tile", length(mask))
        NCDatasets.defVar(
            dataset,
            "ipeatland",
            Int32,
            ("tile",);
            fillvalue = Int32(-999),
        )[:] .= ipeatland
        NCDatasets.defVar(
            dataset,
            "imoss",
            Int32,
            ("tile",);
            fillvalue = Int32(-999),
        )[:] .= 1
    end
    job_path = joinpath(root, "job_options_file.txt")
    write(
        job_path,
        "doPeatOutputs = .true.\nuseStaticPeatDep = .true.\nturbationON = .true.\n",
    )
    source_root = joinpath(root, "CLASSIC")
    mkpath(joinpath(source_root, "src", "base"))
    mkpath(joinpath(source_root, "src", "driver"))
    write(
        joinpath(source_root, "src", "driver", "modelStateDrivers.f90"),
        "ipeatland = ncGet2DVar(initid, 'ipeatland')\n" *
        "imoss = ncGet2DVar(initid, 'imoss')\n" *
        "if (imoss(i,j) == 0) then\n" *
        "mossPresentrow(i,j) = 'Sphagnum'\n" *
        "mossPresentrow(i,j) = 'Feather'\n" *
        "Unknown moss type\n" *
        "if (ipeatland(i,j) == 0) then\n" *
        "peatlandTyperow(i,j) = 'Bog'\n" *
        "peatlandTyperow(i,j) = 'Fen'\n" *
        "Unknown peatland type\n",
    )
    write(
        joinpath(source_root, "src", "base", "ctemDriver.F90"),
        "call sb_write_i1(sb_directory, 'static.mineral_mask', merge(1,0,peatlandType(il1:il2) == 'None'))\n",
    )
    write(
        joinpath(source_root, "src", "base", "heterotrophicRespirationMod.f90"),
        "if ((peatlandType(i) == 'None') .and. (fg(i) > zero .or. j == iccp2)) then\n" *
        "scresveg(i,j,k) = socmoscl(i,k) * soilcmas(i,j,k) * bsratesc_g\n" *
        "call soilCResPeat(il1, il2, ilg, peatlandType\n" *
        "if (mossPresent(i) == 'Sphagnum' .and. peatlandType(i) /= 'None') then\n" *
        "litresmoss(i,1) =  ltrmoscl(i,1) * litrmsmoss(i,1)\n" *
        "if (peatlandType(i) == 'None') then !uplands\n" *
        "scresveg(i,j,k) = socmoscl(i,k) * soilcmas(i,j,k) * bsratesc_peat\n" *
        "Adjust for peatland and moss contributions\n" *
        "socres(i) = socres(i) + socres_peat(i)\n" *
        "if (mossPresent(i) /= 'None') then ! moss covered\n" *
        "soilresp(i) = soilresp(i) + litresmoss(i,k) + socres_moss(i,k)\n" *
        "For peatlands, we additionally add moss values\n" *
        "if (mossPresent(i) == 'Sphagnum') then\n" *
        "peatSoilC(i)  = peatSoilC(i)  + real(spinfast)\n",
    )
    write(
        joinpath(source_root, "src", "base", "soilCProcesses.f90"),
        "if (peatlandType(i) == 'None') then ! turbation only occurs in mineral soils (so not in peatlands)\n",
    )
    instrumentation_path = joinpath(root, "generate_fortran_instrumentation.jl")
    write(
        instrumentation_path,
        "call sb_write_i1(sb_directory, 'static.mineral_mask', merge(1,0,peatlandType(il1:il2) == 'None'))\n",
    )
    payload = joinpath(root, "payloads", "fixed", "static_mineral_mask.bin")
    mkpath(dirname(payload))
    open(payload, "w") do io
        write(io, mask)
    end
    mask_sha256 = bytes2hex(open(SHA.sha256, payload))
    manifest = Dict(
        "endianness" => "little",
        "field" => [
            Dict(
                "name" => "static.mineral_mask",
                "path" => "payloads/fixed/static_mineral_mask.bin",
                "sha256" => mask_sha256,
                "dtype" => "int32",
                "shape" => collect(size(mask)),
                "bytes" => filesize(payload),
            ),
        ],
    )
    replay = (; static_data = Dict("static.mineral_mask" => mask))
    return (;
        init_path,
        job_path,
        source_root,
        instrumentation_path,
        manifest,
        replay,
        mask_sha256,
    )
end

function canonical_guard_records()
    return [
        merge(Dict("label" => label), deepcopy(record)) for
        (label, record) in ClassicInactiveStageB.CANONICAL_GUARD_CONTRACT
    ]
end

function write_canonical_evidence_fixture(root, fixture; step_count = 365)
    path = joinpath(root, "inactive_stage_b.toml")
    @test_throws ArgumentError write_inactive_stage_b_evidence!(
        path,
        "CA-Mer",
        root,
        fixture.replay,
        fixture.manifest,
        fixture.init_path,
        fixture.job_path,
        fixture.source_root,
        fixture.instrumentation_path;
        step_count,
    )
    receipt = TOML.parsefile(path)
    receipt["source_guard"] = canonical_guard_records()
    open(path, "w") do io
        TOML.print(io, receipt; sorted = true)
    end
    @test validate_inactive_stage_b_evidence(
        path,
        "CA-Mer",
        root,
        fixture.manifest;
        expected_step_count = step_count,
        expected_initial_condition_sha256 = bytes2hex(
            open(SHA.sha256, fixture.init_path),
        ),
        expected_job_options_sha256 = bytes2hex(
            open(SHA.sha256, fixture.job_path),
        ),
    )
    return path
end

@testset "peat configuration proves mineral Stage B inactive" begin
    mktempdir() do root
        fixture = write_inactive_fixture(root)
        path = write_canonical_evidence_fixture(root, fixture)
        receipt = TOML.parsefile(path)

        @test receipt["evidence_status"] == "complete"
        @test receipt["stage_b_status"] == "inactive"
        @test receipt["replay_claimed"] === false
        @test receipt["complete_seasonal_cycle"] === true
        @test receipt["ipeatland"] == [1]
        @test receipt["peatland_type"] == ["Bog"]
        @test receipt["mineral_mask"] == [0]
        @test receipt["mineral_mask_nonzero_count"] == 0
        @test receipt["stage_c_semantics_excluded"] === true
        @test receipt["deferred_issue"] == 108
        @test Set(getindex.(receipt["source_guard"], "label")) == Set((
            "initial_peatland_mapping",
            "initial_moss_mapping",
            "v5_mineral_mask_derivation",
            "mineral_bare_ground_respiration_guard",
            "peat_and_sphagnum_respiration_paths",
            "vegetated_mineral_versus_peat_rates",
            "peat_and_moss_flux_aggregation",
            "peat_and_moss_pool_updates",
            "mineral_only_turbation_guard",
            "checked_in_v5_mask_writer",
        ))
    end
end

@testset "inactive proof rejects a mineral tile or None configuration" begin
    mktempdir() do root
        fixture = write_inactive_fixture(root; mask = Int32[1])
        @test_throws ArgumentError write_inactive_stage_b_evidence!(
            joinpath(root, "evidence.toml"),
            "CA-Mer",
            root,
            fixture.replay,
            fixture.manifest,
            fixture.init_path,
            fixture.job_path,
            fixture.source_root,
            fixture.instrumentation_path;
            step_count = 365,
        )
    end
    mktempdir() do root
        fixture = write_inactive_fixture(root; ipeatland = 0)
        @test_throws ArgumentError write_inactive_stage_b_evidence!(
            joinpath(root, "evidence.toml"),
            "CA-Mer",
            root,
            fixture.replay,
            fixture.manifest,
            fixture.init_path,
            fixture.job_path,
            fixture.source_root,
            fixture.instrumentation_path;
            step_count = 365,
        )
    end
end

@testset "inactive evidence validation is hash bound and fail closed" begin
    mktempdir() do root
        fixture = write_inactive_fixture(root)
        path = write_canonical_evidence_fixture(root, fixture)
        receipt = TOML.parsefile(path)
        receipt["stage_c_semantics_excluded"] = false
        open(path, "w") do io
            TOML.print(io, receipt; sorted = true)
        end
        @test_throws ArgumentError validate_inactive_stage_b_evidence(
            path,
            "CA-Mer",
            root,
            fixture.manifest;
            expected_step_count = 365,
            expected_initial_condition_sha256 = bytes2hex(
                open(SHA.sha256, fixture.init_path),
            ),
            expected_job_options_sha256 = bytes2hex(
                open(SHA.sha256, fixture.job_path),
            ),
        )
    end
end

function validate_fixture(
    path,
    root,
    fixture;
    step_count = 365,
    init_sha = bytes2hex(open(SHA.sha256, fixture.init_path)),
    job_sha = bytes2hex(open(SHA.sha256, fixture.job_path)),
)
    validate_inactive_stage_b_evidence(
        path,
        "CA-Mer",
        root,
        fixture.manifest;
        expected_step_count = step_count,
        expected_initial_condition_sha256 = init_sha,
        expected_job_options_sha256 = job_sha,
    )
end

@testset "inactive applicability rejects forged receipt semantics" begin
    mktempdir() do root
        fixture = write_inactive_fixture(root)
        original = write_canonical_evidence_fixture(root, fixture)
        canonical = TOML.parsefile(original)
        tampered = [
            ("reason", "forged"),
            ("step_count", 364),
            ("stage_c_exclusion", ["forged"]),
            ("mineral_mask", [0, 0]),
            ("mineral_mask_count", 2),
            ("peatland_type", ["None"]),
            ("moss_type", ["Feather"]),
            ("configuration", Dict("do_peat_outputs" => false)),
            ("initial_ipeatland_dtype", "Int64"),
            ("initial_imoss_shape", [2]),
        ]
        for (index, (key, value)) in enumerate(tampered)
            receipt = deepcopy(canonical)
            receipt[key] = value
            path = joinpath(root, "tampered_$(index).toml")
            open(path, "w") do io
                TOML.print(io, receipt; sorted = true)
            end
            @test_throws ArgumentError validate_fixture(path, root, fixture)
        end

        for (index, key) in enumerate((
            "label",
            "path",
            "required_fragment",
            "file_sha256",
            "first_line",
        ))
            receipt = deepcopy(canonical)
            guard = first(receipt["source_guard"])
            guard[key] =
                key == "first_line" ? 0 :
                key == "required_fragment" ? ["forged"] :
                key == "file_sha256" ? repeat("0", 64) : "forged"
            path = joinpath(root, "guard_tampered_$(index).toml")
            open(path, "w") do io
                TOML.print(io, receipt; sorted = true)
            end
            @test_throws ArgumentError validate_fixture(path, root, fixture)
        end

        forged_range = deepcopy(canonical)
        forged_range["source_guard"][1]["first_line"] += 1
        forged_range["source_guard"][1]["last_line"] += 1
        forged_range["source_guard"][1]["excerpt_sha256"] = repeat("1", 64)
        forged_range_path = joinpath(root, "forged_range.toml")
        open(forged_range_path, "w") do io
            TOML.print(io, forged_range; sorted = true)
        end
        @test_throws ArgumentError validate_fixture(
            forged_range_path,
            root,
            fixture,
        )

        @test_throws ArgumentError validate_fixture(
            original,
            root,
            fixture;
            step_count = 366,
        )
        @test_throws ArgumentError validate_fixture(
            original,
            root,
            fixture;
            init_sha = repeat("0", 64),
        )
        @test_throws ArgumentError validate_fixture(
            original,
            root,
            fixture;
            job_sha = repeat("0", 64),
        )
        write(joinpath(root, "replay_receipt.toml"), "unexpected")
        @test_throws ArgumentError validate_fixture(original, root, fixture)
    end
end

@testset "inactive applicability independently verifies mask bytes" begin
    mktempdir() do root
        fixture = write_inactive_fixture(root)
        path = write_canonical_evidence_fixture(root, fixture)
        open(
            joinpath(root, "payloads", "fixed", "static_mineral_mask.bin"),
            "w",
        ) do io
            write(io, Int32[1])
        end
        @test_throws ArgumentError validate_fixture(path, root, fixture)
    end
end
