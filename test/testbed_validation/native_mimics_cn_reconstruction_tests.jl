using Test
import NCDatasets
import TOML

@testset "native MIMICS-CN reconstruction contract" begin
    stages = TestbedNativeMIMICSCNReconstruction.COMPLETE_STAGES
    @test getproperty.(stages, :name) ==
          (:prespin, :spin, :spin_continuation, :historical)
    @test getproperty.(stages, :forcing_days) ==
          (365, 20 * 365, 20 * 365, 114 * 365)
    @test getproperty.(stages, :repeats) == (100, 499, 499, 1)

    @test TestbedNativeMIMICSCNReconstruction.MIMICS_PARAMETER_SHA256 ==
          "52d12f43e484caec0580198f72fc85f814ccc9c2e9799165859076640c84bb3b"
    @test TestbedNativeMIMICSCNReconstruction.MIMICS_PARAMETER_FILE ==
          "pftlookup_LIDET-MIM-REV_CN_desorb2xKO4_micCN_FI30.csv"
    names =
        Set(first.(TestbedNativeMIMICSCNReconstruction.HISTORICAL_VARIABLES))
    @test all(
        in(names),
        (
            "cleaf",
            "nleaf",
            "cLITm",
            "nLITm",
            "DIN",
            "cOverflow_r",
            "cOverflow_k",
            "nMinUptake",
            "nLitMineralization",
            "nSoilMineralization",
            "nSoilImmob",
            "nMinLeach",
            "nMinLoss",
        ),
    )
    mktempdir() do root
        fallback = joinpath(root, "stages", "04-historical")
        @test TestbedNativeMIMICSCNReconstruction.fresh_reference_root(root) ==
              fallback
        compact = joinpath(root, "fresh_reference")
        mkpath(compact)
        touch(joinpath(compact, "ann_casaclm_pool_flux_1901_2014.nc"))
        @test TestbedNativeMIMICSCNReconstruction.fresh_reference_root(root) ==
              compact
    end
end

@testset "MIMICS-CN long-stage budgets use stable ordered accumulation" begin
    # Saved from the 80-cell Representative spin report. Repeating the mean
    # daily contribution with ordinary Float64 addition alone exceeds the
    # unchanged process-budget tolerance at this stage length.
    stage_steps = 20 * 365 * 499
    saved_external_input_kg_n = 6.426046879622582e13
    daily_input_kg_n = saved_external_input_kg_n / stage_steps
    naive = 0.0
    stable = TestbedNativeWorkflow.CompensatedSum(Float64)
    for _ in 1:stage_steps
        naive += daily_input_kg_n
        TestbedNativeWorkflow.add_term!(stable, daily_input_kg_n)
    end

    @test abs(naive - saved_external_input_kg_n) / saved_external_input_kg_n >
          5e-12
    @test isapprox(
        TestbedNativeWorkflow.compensated_value(stable),
        saved_external_input_kg_n;
        rtol = eps(Float64),
    )
end

@testset "native MIMICS-CN Fortran restart semantics" begin
    casa_value = 0.19582245315201095
    mimics_value = 0.014294174123456
    state = (;
        casa_plant = (;
            c_leaf = [casa_value],
            c_wood = [casa_value],
            c_fine_root = [casa_value],
            c_labile = [casa_value],
            n_leaf = [casa_value],
            n_wood = [casa_value],
            n_fine_root = [casa_value],
        ),
        mimics_soil = (;
            c_litter_cwd = [casa_value],
            n_litter_cwd = [casa_value],
            n_mineral = [casa_value],
            c_litter_metabolic = [mimics_value],
            c_litter_structural = [mimics_value],
            c_microbe_r = [mimics_value],
            c_microbe_k = [mimics_value],
            c_soil_available = [mimics_value],
            c_soil_chemical = [mimics_value],
            c_soil_physical = [mimics_value],
            n_litter_metabolic = [mimics_value],
            n_litter_structural = [mimics_value],
            n_microbe_r = [mimics_value],
            n_microbe_k = [mimics_value],
            n_soil_available = [mimics_value],
            n_soil_chemical = [mimics_value],
            n_soil_physical = [mimics_value],
        ),
    )

    TestbedNativeMIMICSCNReconstruction.quantize_fortran_restart!(state)

    @test state.casa_plant.c_leaf == [0.195822453]
    @test state.casa_plant.c_labile == [0.0]
    @test state.mimics_soil.n_mineral == [0.195822453]
    @test state.mimics_soil.c_litter_metabolic == [0.0142941741]

    mktempdir() do directory
        casa_path = joinpath(directory, "casa_final.csv")
        mimics_path = joinpath(directory, "mimics_final.csv")
        casa_names = [
            name for (name, source, _, _) in
            TestbedNativeMIMICSCNReconstruction.BOUNDARY_VARIABLES if
            source == :casa
        ]
        mimics_names = [
            name for (name, source, _, _) in
            TestbedNativeMIMICSCNReconstruction.BOUNDARY_VARIABLES if
            source == :mimics
        ]
        write(
            casa_path,
            join(casa_names, ",") *
            "\n" *
            join(fill("250", length(casa_names)), ",") *
            "\n",
        )
        write(
            mimics_path,
            join(mimics_names, ",") *
            "\n" *
            join(fill("0.75", length(mimics_names)), ",") *
            "\n",
        )

        TestbedNativeMIMICSCNReconstruction.load_fortran_restart!(
            state,
            casa_path,
            mimics_path,
        )

        @test state.casa_plant.c_leaf == [0.25]
        @test state.casa_plant.c_labile == [0.0]
        @test state.mimics_soil.n_mineral == [0.25]
        @test state.mimics_soil.c_litter_metabolic == [0.75]
        @test state.mimics_soil.n_soil_physical == [0.75]
    end
end

@testset "native MIMICS-CN first-day plant stoichiometry" begin
    grid = [(; pft = 1), (; pft = 2)]
    parameters = Dict(
        1 => (; inactive = false, initial_leaf_phosphorus = 2e-3),
        2 => (; inactive = true, initial_leaf_phosphorus = 0.0),
    )
    ratios = [0.1, 0.2]
    model = (;
        casa_plant = (; parameters = (; leaf_phosphorus_to_nitrogen = ratios),),
    )
    initial_state = (; casa_plant = (; n_leaf = [1e-9, 0.0]))

    fixed =
        TestbedNativeMIMICSCNReconstruction.use_initial_plant_stoichiometry!(
            model,
            grid,
            parameters,
            initial_state,
        )
    @test fixed == [0.1, 0.2]
    @test ratios == [2e-3 / 1e-9, 0.2]

    TestbedNativeMIMICSCNReconstruction.restore_plant_stoichiometry!(
        model,
        fixed,
    )
    @test ratios == [0.1, 0.2]
end

@testset "native MIMICS-CN synthetic handoff" begin
    mktempdir() do output_root
        result =
            TestbedNativeMIMICSCNReconstruction.run_synthetic_case(output_root)
        report = TOML.parsefile(result.report)

        @test getproperty.(result.stages, :name) ==
              (:prespin, :spin, :spin_continuation, :historical)
        @test all(isfile, getproperty.(result.stages, :checkpoint))
        @test all(getproperty.(result.stages, :checkpoint_roundtrip_verified))
        @test report["scientific_configuration"]["mineral_nitrogen_owner"] ==
              "mimics_soil.n_mineral"
        @test report["scientific_configuration"]["parameter_sha256"] ==
              TestbedNativeMIMICSCNReconstruction.MIMICS_PARAMETER_SHA256
        @test report["carbon_budget"]["all_close"]
        @test report["nitrogen_budget"]["all_close"]
        @test TestbedNativeMIMICSCNReconstruction.require_acceptance!(
            result.report,
        ) == result.report
        fresh_only_report = joinpath(output_root, "fresh_only_report.toml")
        report["historical_comparison"]["published_archive"]["all_match"] =
            false
        open(fresh_only_report, "w") do io
            TOML.print(io, report; sorted = true)
        end
        @test TestbedNativeMIMICSCNReconstruction.require_acceptance!(
            fresh_only_report,
        ) == fresh_only_report
        @test_throws ErrorException begin
            TestbedNativeMIMICSCNReconstruction.require_acceptance!(
                fresh_only_report;
                require_archive = true,
            )
        end
        report["historical_comparison"]["published_archive"]["all_match"] = true
        archive_only_report = joinpath(output_root, "archive_only_report.toml")
        report["historical_comparison"]["fresh_fortran"] =
            Dict("required" => false, "status" => "not_available")
        open(archive_only_report, "w") do io
            TOML.print(io, report; sorted = true)
        end
        @test TestbedNativeMIMICSCNReconstruction.require_acceptance!(
            archive_only_report;
            require_fresh = false,
            require_archive = true,
        ) == archive_only_report
        @test Set(keys(report["historical_comparison"])) ==
              Set(("fresh_fortran", "published_archive"))
        NCDatasets.NCDataset(result.output) do output
            @test all(
                haskey(output, name) for name in (
                    "casa_plant__n_leaf",
                    "mimics_soil__n_litter_metabolic",
                    "mimics_soil__n_mineral",
                    "diagnostic__mimics_working_din",
                    "diagnostic__mimics_overflow_r",
                    "diagnostic__mimics_overflow_k",
                    "diagnostic__mimics_litter_mineralization",
                    "diagnostic__mimics_soil_mineralization",
                    "diagnostic__mimics_immobilization",
                )
            )
        end
    end
end
