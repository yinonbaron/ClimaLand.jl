using Test
using NCDatasets
import ClimaLand
import ClimaComms
import ClimaCore
ClimaComms.@import_required_backends
using ClimaLand.Soil.Biogeochemistry
using ClimaLand.Domains: Plane, Point
import ClimaTimeSteppers as CTS

include("../../../testbed_validation/model_architecture.jl")

const CASA = Biogeochemistry.CASA
const FORWARD_EULER = CTS.ExplicitAlgorithm(
    CTS.ExplicitTableau(;
        a = zeros(Int, 1, 1),
        b = ones(Int, 1),
        c = zeros(Int, 1),
    ),
)

function carbon_kernel_allocations(
    litter,
    soil,
    litter_inputs,
    litter_rates,
    soil_rates,
    transfers,
)
    CASA.carbon_tendencies(
        litter,
        soil,
        litter_inputs,
        litter_rates,
        soil_rates,
        transfers,
    )
    return @allocated CASA.carbon_tendencies(
        litter,
        soil,
        litter_inputs,
        litter_rates,
        soil_rates,
        transfers,
    )
end

function nitrogen_kernel_allocations(arguments...)
    CASA.nitrogen_tendencies(arguments...)
    return @allocated CASA.nitrogen_tendencies(arguments...)
end

for FT in (Float32, Float64)
    @testset "CASA environmental kernels, FT = $FT" begin
        freezing_temperature = FT(273.15)
        optimum_temperature = freezing_temperature + FT(35)
        @test @inferred(
            CASA.temperature_factor(
                FT(1.72),
                optimum_temperature,
                freezing_temperature,
            )
        ) == one(FT)
        @test @inferred(CASA.moisture_factor(FT(0.55), false)) == one(FT)
        @test CASA.moisture_factor(FT(0.2), true) == one(FT)

        factors = @inferred CASA.environmental_factors(
            FT(1.72),
            FT(0.4),
            FT(0.1034),
            optimum_temperature,
            FT(0.55),
            one(FT),
            freezing_temperature,
            false,
        )
        @test factors.relative_saturation == FT(0.55)
        @test factors.temperature == one(FT)
        @test factors.moisture == one(FT)
        @test factors.litter == FT(0.4)
        @test factors.soil == FT(0.1034)

        transfer_parameters = CASA.CarbonTransferParameters{FT}(;
            lignin_leaf = FT(0.2),
            lignin_wood = FT(0.4),
            cue_metabolic_to_microbial = FT(0.45),
            cue_structural_to_microbial = FT(0.45),
            cue_structural_to_slow = FT(0.7),
            cue_cwd_to_microbial = FT(0.4),
            cue_cwd_to_slow = FT(0.7),
            cue_microbial_to_slow = one(FT),
            cue_microbial_to_passive = one(FT),
            cue_slow_to_passive = FT(0.45),
        )
        @test isbits(transfer_parameters)
        transfers = @inferred CASA.transfer_fractions(
            transfer_parameters,
            FT(0.2),
            FT(0.1),
        )
        rates = @inferred CASA.decomposition_rates(
            FT(0.4),
            FT(0.1),
            (FT(0.05), FT(0.02), FT(0.01)),
            (FT(0.1), FT(0.01), FT(0.001)),
            transfer_parameters.lignin_leaf,
            FT(0.2),
            FT(0.1),
            false,
        )
        litter = (FT(2), FT(3), FT(4))
        soil = (FT(5), FT(6), FT(7))
        litter_inputs = (FT(0.1), FT(0.2), FT(0.3))
        tendencies = @inferred CASA.carbon_tendencies(
            litter,
            soil,
            litter_inputs,
            rates.litter,
            rates.soil,
            transfers,
        )
        @test carbon_kernel_allocations(
            litter,
            soil,
            litter_inputs,
            rates.litter,
            rates.soil,
            transfers,
        ) == 0
        stock_change = sum(tendencies.litter) + sum(tendencies.soil)
        @test stock_change + tendencies.heterotrophic_respiration ≈
              sum(litter_inputs) atol = 8eps(FT)

        @test CASA.nitrogen_limitation(
            FT(0.5),
            FT(0.5),
            FT(2),
            litter,
            FT(157),
            FT(107),
        ) == zero(FT)
        @test CASA.nitrogen_limitation(
            FT(1.25),
            FT(0.5),
            FT(2),
            litter,
            FT(157),
            FT(107),
        ) == FT(0.5)
        @test CASA.nitrogen_limitation(
            FT(0.5),
            FT(0.5),
            FT(2),
            (FT(200), FT(100), zero(FT)),
            FT(157),
            FT(107),
        ) == one(FT)

        minimum_ratios = (inv(FT(8)), inv(FT(20)), inv(FT(20)))
        maximum_ratios = (inv(FT(6.17)), inv(FT(16.63)), inv(FT(16.63)))
        soil_nitrogen_ratios = @inferred CASA.new_soil_nitrogen_ratios(
            one(FT),
            minimum_ratios,
            maximum_ratios,
            FT(2),
        )
        @test all(
            soil_nitrogen_ratios .≈
            minimum_ratios .+ (maximum_ratios .- minimum_ratios) ./ FT(2),
        )

        litter_nitrogen = (FT(0.2), FT(0.1), FT(0.05))
        soil_nitrogen = (FT(0.4), FT(0.3), FT(0.2))
        litter_nitrogen_inputs = (FT(0.01), FT(0.02), FT(0.03))
        deposition = FT(0.001)
        fixation = FT(0.002)
        uptake = FT(0.003)
        nitrogen_arguments = (
            litter,
            soil,
            litter_nitrogen,
            soil_nitrogen,
            litter_nitrogen_inputs,
            rates.litter,
            rates.soil,
            transfers,
            soil_nitrogen_ratios,
            one(FT),
            deposition,
            fixation,
            uptake,
            FT(0.05),
            FT(0.5) / FT(365),
            FT(280),
        )
        nitrogen = @inferred CASA.nitrogen_tendencies(nitrogen_arguments...)
        @test nitrogen_kernel_allocations(nitrogen_arguments...) == 0
        nitrogen_stock_change =
            sum(nitrogen.litter) + sum(nitrogen.soil) + nitrogen.mineral
        @test nitrogen_stock_change + nitrogen.gaseous_loss +
              nitrogen.leaching + uptake ≈
              sum(litter_nitrogen_inputs) + deposition + fixation atol =
            32eps(FT)

        moisture_values = map(
            saturation -> CASA.moisture_factor(saturation, false),
            range(zero(FT), one(FT); length = 101),
        )
        @test all(zero(FT) .<= moisture_values .<= one(FT))
    end
end

@testset "CASA productive-cell nitrogen transitions" begin
    fixture_dir = normpath(
        joinpath(
            @__DIR__,
            "../../../testbed_validation/fixtures/casa_cn_cell_11060",
        ),
    )
    output_path = joinpath(fixture_dir, "casa_1901_1905_cell_11060.nc")
    transfer_parameters = CASA.CarbonTransferParameters{Float64}(;
        lignin_leaf = 0.2,
        lignin_wood = 0.4,
        cue_metabolic_to_microbial = 0.45,
        cue_structural_to_microbial = 0.45,
        cue_structural_to_slow = 0.7,
        cue_cwd_to_microbial = 0.4,
        cue_cwd_to_slow = 0.7,
        cue_microbial_to_slow = 1.0,
        cue_microbial_to_passive = 1.0,
        cue_slow_to_passive = 0.45,
    )
    transfers =
        CASA.transfer_fractions(transfer_parameters, 0.21805, 0.13224)
    litter_base_rates =
        (1 / (365 * 0.04), 1 / (365 * 0.23), 1 / (365 * 0.824))
    soil_base_rates =
        (1 / (365 * 0.137), 1 / (365 * 5), 1 / (365 * 222.22))
    minimum_ratios = (1 / 8, 1 / 20, 1 / 20)
    maximum_ratios = (1 / 6.17, 1 / 16.63, 1 / 16.63)

    NCDataset(output_path) do output
        value(name, day) = Float64(output[name][1, 1, day])
        daily_carbon_inputs = fill((0.0, 0.0, 0.0), 365)
        daily_nitrogen_inputs = fill((0.0, 0.0, 0.0), 365)
        for day in 2:365
            litter_carbon = ntuple(
                pool -> value(("clitmetb", "clitstr", "clitcwd")[pool], day - 1),
                3,
            )
            soil_carbon = ntuple(
                pool ->
                    value(
                        ("csoilmic", "csoilslow", "csoilpass")[pool],
                        day - 1,
                    ),
                3,
            )
            litter_nitrogen = ntuple(
                pool -> value(("nlitmetb", "nlitstr", "nlitcwd")[pool], day - 1),
                3,
            )
            soil_nitrogen = ntuple(
                pool ->
                    value(
                        ("nsoilmic", "nsoilslow", "nsoilpass")[pool],
                        day - 1,
                    ),
                3,
            )
            mineral_nitrogen = value("nMineral", day - 1)
            limitation = CASA.nitrogen_limitation(
                mineral_nitrogen,
                0.5,
                2.0,
                litter_carbon,
                157.0,
                107.0,
            )
            rates = CASA.decomposition_rates(
                0.4 * value("fT", day) * value("fW", day) * limitation,
                0.10343498 * value("fT", day) * value("fW", day),
                litter_base_rates,
                soil_base_rates,
                transfer_parameters.lignin_leaf,
                0.21805,
                0.13224,
                false,
            )
            expected_litter_carbon = ntuple(
                pool ->
                    value(("clitmetb", "clitstr", "clitcwd")[pool], day),
                3,
            )
            daily_carbon_inputs[day] = ntuple(
                pool ->
                    expected_litter_carbon[pool] - litter_carbon[pool] +
                    rates.litter[pool] * litter_carbon[pool],
                3,
            )
            soil_nitrogen_ratios = CASA.new_soil_nitrogen_ratios(
                mineral_nitrogen,
                minimum_ratios,
                maximum_ratios,
                2.0,
            )
            expected_litter = ntuple(
                pool -> value(("nlitmetb", "nlitstr", "nlitcwd")[pool], day),
                3,
            )
            # The legacy `nLitInptStruc` diagnostic is not a valid oracle:
            # `casa_delsoil` adds the uninitialized local `nwd2str` to it.
            # Recover the three plant boundary inputs from the archived litter
            # state transition; soil and mineral N remain independent checks.
            litter_nitrogen_inputs = ntuple(
                pool ->
                    expected_litter[pool] - litter_nitrogen[pool] +
                    rates.litter[pool] * litter_nitrogen[pool],
                3,
            )
            daily_nitrogen_inputs[day] = litter_nitrogen_inputs
            @test litter_nitrogen_inputs[1] ≈ value("nLitInptMet", day) rtol =
                3e-5 atol = 2e-7
            @test all(litter_nitrogen_inputs .>= -2e-7)
            tendencies = CASA.nitrogen_tendencies(
                litter_carbon,
                soil_carbon,
                litter_nitrogen,
                soil_nitrogen,
                litter_nitrogen_inputs,
                rates.litter,
                rates.soil,
                transfers,
                soil_nitrogen_ratios,
                mineral_nitrogen,
                value("nMinDep", day),
                value("nMinFix", day),
                value("nMinUptake", day),
                0.05,
                10 * 0.05 / 365,
                value("tsoilC", day) + 273.15,
            )
            predicted_soil = soil_nitrogen .+ tendencies.soil
            expected_soil = ntuple(
                pool ->
                    value(
                        ("nsoilmic", "nsoilslow", "nsoilpass")[pool],
                        day,
                    ),
                3,
            )
            @test all(isapprox.(predicted_soil, expected_soil; rtol = 3e-6))
            @test mineral_nitrogen + tendencies.mineral ≈
                  value("nMineral", day) rtol = 3e-6
            for (field, variable) in (
                (:litter_mineralization, "nLitMineralization"),
                (:soil_mineralization, "nSoilMineralization"),
                (:soil_immobilization, "nSoilImmob"),
                (:net_mineralization, "nNetMineralization"),
                (:gaseous_loss, "nMinLoss"),
                (:leaching, "nMinLeach"),
            )
                @test getproperty(tendencies, field) ≈ value(variable, day) rtol =
                    3e-6
            end
        end

        seconds_per_day = 86400.0
        parameters = CASA.CASASoilModelParameters{
            Float64,
            typeof(transfer_parameters),
        }(;
            q10 = 1.72,
            litter_optimum = 0.4,
            soil_optimum = 0.10343498,
            porosity = 0.41312,
            clay = 0.21805,
            silt = 0.13224,
            freezing_temperature = 273.15,
            litter_base_rates = litter_base_rates ./ seconds_per_day,
            soil_base_rates = soil_base_rates ./ seconds_per_day,
            transfers = transfer_parameters,
        )
        nitrogen_parameters = CASA.CASANitrogenParameters{Float64}(;
            limitation_minimum = 0.5e-3,
            limitation_maximum = 2e-3,
            maximum_fine_litter = 0.157,
            maximum_cwd = 0.107,
            soil_nitrogen_ratio_minimum = minimum_ratios,
            soil_nitrogen_ratio_maximum = maximum_ratios,
            loss_threshold = 2e-3,
            loss_fraction = 0.05,
            leach_rate = (10 * 0.05 / 365) / seconds_per_day,
        )
        driver_day(t) = min(div(round(Int, t), 86400) + 2, 365)
        carbon_rate(t, pool) =
            daily_carbon_inputs[driver_day(t)][pool] * 1e-3 / seconds_per_day
        nitrogen_rate(t, pool) =
            daily_nitrogen_inputs[driver_day(t)][pool] * 1e-3 /
            seconds_per_day
        drivers = CASA.PrescribedDrivers(
            t -> value("tsoilC", driver_day(t)) + 273.15,
            t -> value("thetaLiq", driver_day(t)) * parameters.porosity,
            t -> carbon_rate(t, 1),
            t -> carbon_rate(t, 2),
            t -> carbon_rate(t, 3),
        )
        nitrogen_drivers = CASA.NitrogenPrescribedDrivers(
            t -> nitrogen_rate(t, 1),
            t -> nitrogen_rate(t, 2),
            t -> nitrogen_rate(t, 3),
            t -> value("nMinDep", driver_day(t)) * 1e-3 / seconds_per_day,
            t -> value("nMinFix", driver_day(t)) * 1e-3 / seconds_per_day,
            t -> value("nMinUptake", driver_day(t)) * 1e-3 / seconds_per_day,
        )
        domain = Point(; z_sfc = 0.0, context = ClimaComms.context())
        model = CASA.CASASoilModel{Float64}(;
            configuration = CASA.CarbonNitrogen(),
            parameters,
            nitrogen_parameters,
            drivers,
            nitrogen_drivers,
            domain,
        )
        Y, p, _ = ClimaLand.initialize(model)
        output_names = (
            "clitmetb",
            "clitstr",
            "clitcwd",
            "csoilmic",
            "csoilslow",
            "csoilpass",
            "nlitmetb",
            "nlitstr",
            "nlitcwd",
            "nsoilmic",
            "nsoilslow",
            "nsoilpass",
            "nMineral",
        )
        initial = map(name -> value(name, 1) * 1e-3, output_names)
        expected = map(name -> value(name, 365) * 1e-3, output_names)
        for (name, state) in zip(ClimaLand.prognostic_vars(model), initial)
            getproperty(Y.casa_soil, name) .= state
        end
        tendency! = ClimaLand.make_exp_tendency(model)
        ClimaLand.make_set_initial_cache(model)(p, Y, 0.0)
        problem = CTS.ODEProblem(
            CTS.ClimaODEFunction((T_exp!) = tendency!),
            Y,
            (0.0, 364seconds_per_day),
            p,
        )
        integrator = CTS.init(
            problem,
            FORWARD_EULER;
            dt = seconds_per_day,
            save_everystep = false,
        )
        CTS.step!(integrator)
        one_step = map(ClimaLand.prognostic_vars(model)) do name
            Array(parent(getproperty(integrator.u.casa_soil, name)))[1]
        end
        expected_one_step =
            map(name -> value(name, 2) * 1e-3, output_names)
        for (candidate, reference) in zip(one_step, expected_one_step)
            @test candidate ≈ reference rtol = 5e-5 atol = 2e-8
        end
        for _ in 2:364
            CTS.step!(integrator)
        end
        actual = map(ClimaLand.prognostic_vars(model)) do name
            Array(parent(getproperty(integrator.u.casa_soil, name)))[1]
        end
        for (name, candidate, reference) in
            zip(ClimaLand.prognostic_vars(model), actual, expected)
            if name == :n_mineral
                # Reconstructed N litter drivers inherit Float32 archive
                # rounding and the corrupt structural-input diagnostic. The
                # nonlinear mineral-N feedback accumulates that uncertainty.
                @test candidate ≈ reference rtol = 2e-3 atol = 2.1e-4
            else
                @test candidate ≈ reference rtol = 2e-3
            end
        end
    end
end

@testset "CASA standalone carbon-nitrogen model" begin
    for FT in (Float32, Float64)
        day = FT(86400)
        transfers = CASA.CarbonTransferParameters{FT}(;
            lignin_leaf = FT(0.2),
            lignin_wood = FT(0.4),
            cue_metabolic_to_microbial = FT(0.45),
            cue_structural_to_microbial = FT(0.45),
            cue_structural_to_slow = FT(0.7),
            cue_cwd_to_microbial = FT(0.4),
            cue_cwd_to_slow = FT(0.7),
            cue_microbial_to_slow = one(FT),
            cue_microbial_to_passive = one(FT),
            cue_slow_to_passive = FT(0.45),
        )
        parameters = CASA.CASASoilModelParameters{FT, typeof(transfers)}(;
            q10 = FT(1.72),
            litter_optimum = FT(0.4),
            soil_optimum = FT(0.10343498),
            porosity = FT(0.41312),
            clay = FT(0.21805),
            silt = FT(0.13224),
            freezing_temperature = FT(273.15),
            litter_base_rates = (
                inv(FT(365 * 0.04) * day),
                inv(FT(365 * 0.23) * day),
                inv(FT(365 * 0.824) * day),
            ),
            soil_base_rates = (
                inv(FT(365 * 0.137) * day),
                inv(FT(365 * 5) * day),
                inv(FT(365 * 222.22) * day),
            ),
            transfers,
        )
        nitrogen_parameters = CASA.CASANitrogenParameters{FT}(;
            limitation_minimum = FT(0.5e-3),
            limitation_maximum = FT(2e-3),
            maximum_fine_litter = FT(0.157),
            maximum_cwd = FT(0.107),
            soil_nitrogen_ratio_minimum =
                (inv(FT(8)), inv(FT(20)), inv(FT(20))),
            soil_nitrogen_ratio_maximum =
                (inv(FT(6.17)), inv(FT(16.63)), inv(FT(16.63))),
            loss_threshold = FT(2e-3),
            loss_fraction = FT(0.05),
            leach_rate = FT(10 * 0.05 / 365) / day,
        )
        carbon_inputs = (FT(1e-7), FT(2e-7), FT(3e-7))
        nitrogen_inputs = (FT(1e-9), FT(2e-9), FT(3e-9))
        deposition = FT(4e-10)
        fixation = FT(5e-10)
        uptake = FT(6e-10)
        drivers = CASA.PrescribedDrivers(
            t -> FT(280),
            t -> FT(0.2),
            t -> carbon_inputs[1],
            t -> carbon_inputs[2],
            t -> carbon_inputs[3],
        )
        nitrogen_drivers = CASA.NitrogenPrescribedDrivers(
            t -> nitrogen_inputs[1],
            t -> nitrogen_inputs[2],
            t -> nitrogen_inputs[3],
            t -> deposition,
            t -> fixation,
            t -> uptake,
        )
        domain = Point(; z_sfc = zero(FT), context = ClimaComms.context())
        model = CASA.CASASoilModel{FT}(;
            configuration = CASA.CarbonNitrogen(),
            parameters,
            nitrogen_parameters,
            drivers,
            nitrogen_drivers,
            domain,
        )
        @test length(ClimaLand.prognostic_vars(model)) == 13
        Y, p, _ = ClimaLand.initialize(model)
        initial = (
            FT(0.02),
            FT(0.03),
            FT(0.04),
            FT(0.5),
            FT(6),
            FT(7),
            FT(0.002),
            FT(0.003),
            FT(0.004),
            FT(0.05),
            FT(0.3),
            FT(0.35),
            FT(0.001),
        )
        for (name, value) in zip(ClimaLand.prognostic_vars(model), initial)
            getproperty(Y.casa_soil, name) .= value
        end
        ClimaLand.make_set_initial_cache(model)(p, Y, zero(FT))
        FT == Float32 && test_model_diagnostics(model, Y, p, zero(FT))
        @test p.casa_soil.nitrogen_limitation[] ≈ FT(1 / 3)
        dY = similar(Y)
        ClimaLand.make_exp_tendency(model)(dY, Y, p, zero(FT))
        point_tendencies = map(ClimaLand.prognostic_vars(model)) do name
            getproperty(dY.casa_soil, name)[]
        end
        nitrogen_tendency = sum(
            Array(parent(getproperty(dY.casa_soil, name)))[1] for
            name in ClimaLand.prognostic_vars(model)[7:13]
        )
        nitrogen_fluxes = p.casa_soil.nitrogen_fluxes[]
        @test nitrogen_tendency + nitrogen_fluxes[12] +
              nitrogen_fluxes[13] + uptake ≈
              sum(nitrogen_inputs) + deposition + fixation atol =
            64eps(FT) * sum(nitrogen_inputs)

        problem = CTS.ODEProblem(
            CTS.ClimaODEFunction((T_exp!) = ClimaLand.make_exp_tendency(model)),
            Y,
            (0.0, Float64(day)),
            p,
        )
        integrator = CTS.init(
            problem,
            FORWARD_EULER;
            dt = Float64(day),
            save_everystep = false,
        )
        CTS.step!(integrator)
        @test all(
            isfinite(
                Array(
                    parent(getproperty(integrator.u.casa_soil, name)),
                )[1],
            ) for name in ClimaLand.prognostic_vars(model)
        )
        if FT == Float32
            test_checkpoint_roundtrip(model, integrator.u, Float64(day))
            plane = Plane(;
                xlim = FT.((0, 2)),
                ylim = FT.((0, 2)),
                nelements = (2, 2),
                context = ClimaComms.context(),
            )
            grid_model = CASA.CASASoilModel{FT}(;
                configuration = CASA.CarbonNitrogen(),
                parameters,
                nitrogen_parameters,
                drivers,
                nitrogen_drivers,
                domain = plane,
            )
            test_gridded_tendency(
                grid_model,
                initial,
                point_tendencies,
                zero(FT),
                64eps(FT),
            )

            x = ClimaCore.Fields.coordinate_field(plane.space.surface).x
            nitrogen_variant = CASA.CASANitrogenParameters{FT}(;
                limitation_minimum = nitrogen_parameters.limitation_minimum,
                limitation_maximum = FT(4e-3),
                maximum_fine_litter = nitrogen_parameters.maximum_fine_litter,
                maximum_cwd = nitrogen_parameters.maximum_cwd,
                soil_nitrogen_ratio_minimum =
                    nitrogen_parameters.soil_nitrogen_ratio_minimum,
                soil_nitrogen_ratio_maximum =
                    nitrogen_parameters.soil_nitrogen_ratio_maximum,
                loss_threshold = nitrogen_parameters.loss_threshold,
                loss_fraction = nitrogen_parameters.loss_fraction,
                leach_rate = nitrogen_parameters.leach_rate,
            )
            spatial_nitrogen_parameters =
                @. ifelse(x < FT(1), nitrogen_parameters, nitrogen_variant)
            @test axes(spatial_nitrogen_parameters) == plane.space.surface
            @test eltype(spatial_nitrogen_parameters) ==
                  typeof(nitrogen_parameters)
            spatial_model = CASA.CASASoilModel{FT}(;
                configuration = CASA.CarbonNitrogen(),
                parameters,
                nitrogen_parameters = spatial_nitrogen_parameters,
                drivers,
                nitrogen_drivers,
                domain = plane,
            )
            spatial_Y, spatial_p, _ = ClimaLand.initialize(spatial_model)
            for (name, value) in
                zip(ClimaLand.prognostic_vars(spatial_model), initial)
                getproperty(spatial_Y.casa_soil, name) .= value
            end
            ClimaLand.make_set_initial_cache(spatial_model)(
                spatial_p,
                spatial_Y,
                zero(FT),
            )
            x_values = Array(parent(x))
            limitation = Array(parent(spatial_p.casa_soil.nitrogen_limitation))
            @test all(limitation[x_values .< FT(1)] .≈ FT(1 / 3))
            @test all(limitation[x_values .>= FT(1)] .≈ FT(1 / 7))
        end
    end
end

@testset "CASA standalone soil model" begin
    for FT in (Float32, Float64)
        day = FT(86400)
        transfer_parameters = CASA.CarbonTransferParameters{FT}(;
            lignin_leaf = FT(0.2),
            lignin_wood = FT(0.4),
            cue_metabolic_to_microbial = FT(0.45),
            cue_structural_to_microbial = FT(0.45),
            cue_structural_to_slow = FT(0.7),
            cue_cwd_to_microbial = FT(0.4),
            cue_cwd_to_slow = FT(0.7),
            cue_microbial_to_slow = one(FT),
            cue_microbial_to_passive = one(FT),
            cue_slow_to_passive = FT(0.45),
        )
        parameter_type =
            CASA.CASASoilModelParameters{FT, typeof(transfer_parameters)}
        parameters = parameter_type(;
            q10 = FT(1.72),
            litter_optimum = FT(0.4),
            soil_optimum = FT(0.1034),
            porosity = FT(0.41312),
            clay = FT(0.21805),
            silt = FT(0.13224),
            freezing_temperature = FT(273.15),
            litter_base_rates = (
                inv(FT(365 * 0.04) * day),
                inv(FT(365 * 0.23) * day),
                inv(FT(365 * 0.824) * day),
            ),
            soil_base_rates = (
                inv(FT(365 * 0.137) * day),
                inv(FT(365 * 5) * day),
                inv(FT(365 * 222.22) * day),
            ),
            transfers = transfer_parameters,
            constant_moisture = FT == Float32,
        )
        inputs = (FT(1e-7), FT(2e-7), FT(3e-7))
        drivers = CASA.PrescribedDrivers(
            t -> FT(280),
            t -> FT(0.2),
            t -> inputs[1],
            t -> inputs[2],
            t -> inputs[3],
        )
        domain = Point(; z_sfc = zero(FT), context = ClimaComms.context())
        model = CASA.CASASoilModel{FT}(; parameters, drivers, domain)
        @test model isa Biogeochemistry.AbstractSoilBiogeochemistryModel{FT}
        @test ClimaComms.context(model) == ClimaComms.context()
        @test ClimaLand.name(model) == :casa_soil
        Y, p, _ = ClimaLand.initialize(model)
        initial = (FT(0.02), FT(0.03), FT(0.04), FT(0.5), FT(6), FT(7))
        for (name, value) in zip(ClimaLand.prognostic_vars(model), initial)
            getproperty(Y.casa_soil, name) .= value
        end

        exp_tendency! = ClimaLand.make_exp_tendency(model)
        set_initial_cache! = ClimaLand.make_set_initial_cache(model)
        set_initial_cache!(p, Y, 0.0)
        @test p.casa_soil.moisture_factor[] == (
            FT == Float32 ? one(FT) :
            CASA.moisture_factor(FT(0.2) / parameters.porosity, false)
        )
        FT == Float32 && test_model_diagnostics(model, Y, p, zero(FT))
        dY = similar(Y)
        exp_tendency!(dY, Y, p, 0.0)
        fluxes = p.casa_soil.carbon_fluxes[]
        tendencies = map(ClimaLand.prognostic_vars(model)) do name
            Array(parent(getproperty(dY.casa_soil, name)))[1]
        end
        @test tendencies == Tuple(fluxes[1:6])
        @test sum(tendencies) + fluxes[7] ≈ sum(inputs) atol =
            32eps(FT) * sum(inputs)

        expected = initial .+ day .* tendencies
        problem = CTS.ODEProblem(
            CTS.ClimaODEFunction((T_exp!) = exp_tendency!),
            Y,
            (0.0, Float64(day)),
            p,
        )
        integrator = CTS.init(
            problem,
            FORWARD_EULER;
            dt = Float64(day),
            save_everystep = false,
        )
        CTS.step!(integrator)
        actual = map(ClimaLand.prognostic_vars(model)) do name
            Array(parent(getproperty(integrator.u.casa_soil, name)))[1]
        end
        @test all(isapprox.(actual, expected; rtol = 16eps(FT)))
        if FT == Float32
            test_checkpoint_roundtrip(model, integrator.u, Float64(day))
            plane = Plane(;
                xlim = FT.((0, 2)),
                ylim = FT.((0, 2)),
                nelements = (2, 2),
                context = ClimaComms.context(),
            )
            grid_model =
                CASA.CASASoilModel{FT}(; parameters, drivers, domain = plane)
            test_gridded_tendency(
                grid_model,
                initial,
                tendencies,
                zero(FT),
                16eps(FT),
            )

            spatial_variant = parameter_type(;
                q10 = parameters.q10,
                litter_optimum = parameters.litter_optimum,
                soil_optimum = 2 * parameters.soil_optimum,
                porosity = FT(0.5),
                clay = FT(0.3),
                silt = parameters.silt,
                freezing_temperature = parameters.freezing_temperature,
                litter_base_rates = parameters.litter_base_rates,
                soil_base_rates = parameters.soil_base_rates,
                transfers = parameters.transfers,
                constant_moisture = false,
            )
            x = ClimaCore.Fields.coordinate_field(plane.space.surface).x
            spatial_parameters =
                @. ifelse(x < FT(1), parameters, spatial_variant)
            @test axes(spatial_parameters) == plane.space.surface
            @test eltype(spatial_parameters) == parameter_type

            spatial_model = CASA.CASASoilModel{FT}(;
                parameters = spatial_parameters,
                drivers,
                domain = plane,
            )
            spatial_Y, spatial_p, _ = ClimaLand.initialize(spatial_model)
            for (name, value) in
                zip(ClimaLand.prognostic_vars(spatial_model), initial)
                getproperty(spatial_Y.casa_soil, name) .= value
            end
            ClimaLand.make_set_initial_cache(spatial_model)(
                spatial_p,
                spatial_Y,
                zero(FT),
            )
            spatial_dY = similar(spatial_Y)
            ClimaLand.make_exp_tendency(spatial_model)(
                spatial_dY,
                spatial_Y,
                spatial_p,
                zero(FT),
            )

            x_values = Array(parent(x))
            left = x_values .< FT(1)
            right = .!left
            relative_saturation =
                Array(parent(spatial_p.casa_soil.relative_saturation))
            @test all(
                relative_saturation[left] .≈ FT(0.2) / parameters.porosity,
            )
            @test all(
                relative_saturation[right] .≈
                FT(0.2) / spatial_variant.porosity,
            )
            right_temperature_factor = CASA.temperature_factor(
                spatial_variant.q10,
                FT(280),
                spatial_variant.freezing_temperature,
            )
            right_moisture_factor = CASA.moisture_factor(
                FT(0.2) / spatial_variant.porosity,
                spatial_variant.constant_moisture,
            )
            right_fluxes = CASA.carbon_fluxes(
                spatial_variant,
                initial...,
                inputs...,
                right_temperature_factor,
                right_moisture_factor,
            )
            spatial_tendency =
                Array(parent(spatial_dY.casa_soil.c_soil_microbial))
            @test all(spatial_tendency[left] .≈ tendencies[4])
            @test all(spatial_tendency[right] .≈ right_fluxes[4])
        end
    end
end

@testset "CASA productive-cell environmental trajectory" begin
    fixture_dir = normpath(
        joinpath(
            @__DIR__,
            "../../../testbed_validation/fixtures/casa_c_cell_11060",
        ),
    )
    driver_path = joinpath(fixture_dir, "met_1901_cell_11060.nc")
    output_path = joinpath(fixture_dir, "casa_1901_1905_cell_11060.nc")

    layer_thicknesses = (0.022, 0.058, 0.154, 0.409, 1.085, 2.872)
    root_fractions = CASA.legacy_root_fractions(2.0, 0.5, layer_thicknesses)
    @test sum(root_fractions) ≈ 1.0 atol = eps(Float64)
    expected_root_fractions = (
        0.0680978366005466,
        0.10516780896791597,
        0.24609214668905355,
        0.4644713965439029,
        0.116170811198581,
        0.0,
    )
    @test all(isapprox.(root_fractions, expected_root_fractions))

    NCDataset(driver_path) do driver
        NCDataset(output_path) do output
            transfer_parameters = CASA.CarbonTransferParameters{Float64}(;
                lignin_leaf = 0.2,
                lignin_wood = 0.4,
                cue_metabolic_to_microbial = 0.45,
                cue_structural_to_microbial = 0.45,
                cue_structural_to_slow = 0.7,
                cue_cwd_to_microbial = 0.4,
                cue_cwd_to_slow = 0.7,
                cue_microbial_to_slow = 1.0,
                cue_microbial_to_passive = 1.0,
                cue_slow_to_passive = 0.45,
            )
            transfers =
                CASA.transfer_fractions(transfer_parameters, 0.21805, 0.13224)
            day_fraction = 1 / 365
            litter_base_rates =
                (day_fraction / 0.04, day_fraction / 0.23, day_fraction / 0.824)
            soil_base_rates =
                (day_fraction / 0.137, day_fraction / 5, day_fraction / 222.22)
            root_temperatures = zeros(365)
            root_moistures = zeros(365)
            daily_litter_inputs = fill((0.0, 0.0, 0.0), 365)
            for day in 1:365
                soil_temperature = ntuple(
                    layer -> Float64(driver["xtsoil"][1, 1, layer, day]),
                    6,
                )
                soil_moisture = ntuple(
                    layer -> min(
                        0.23356,
                        Float64(driver["xmoist"][1, 1, layer, day]),
                    ),
                    6,
                )
                root_temperature =
                    CASA.root_weighted_mean(soil_temperature, root_fractions)
                root_moisture =
                    CASA.root_weighted_mean(soil_moisture, root_fractions)
                root_temperatures[day] = root_temperature
                root_moistures[day] = root_moisture
                factors = CASA.environmental_factors(
                    1.72,
                    0.4,
                    0.1034,
                    root_temperature,
                    root_moisture,
                    0.41312,
                    273.15,
                    false,
                )

                @test Float32(root_temperature - 273.15) ==
                      output["tsoilC"][1, 1, day]
                @test Float32(factors.relative_saturation) ==
                      output["thetaLiq"][1, 1, day]
                @test Float32(factors.temperature) == output["fT"][1, 1, day]
                @test Float32(factors.moisture) == output["fW"][1, 1, day]

                if day > 1
                    litter = (
                        Float64(output["clitmetb"][1, 1, day - 1]),
                        Float64(output["clitstr"][1, 1, day - 1]),
                        Float64(output["clitcwd"][1, 1, day - 1]),
                    )
                    next_litter = (
                        Float64(output["clitmetb"][1, 1, day]),
                        Float64(output["clitstr"][1, 1, day]),
                        Float64(output["clitcwd"][1, 1, day]),
                    )
                    soil = (
                        Float64(output["csoilmic"][1, 1, day - 1]),
                        Float64(output["csoilslow"][1, 1, day - 1]),
                        Float64(output["csoilpass"][1, 1, day - 1]),
                    )
                    next_soil = (
                        Float64(output["csoilmic"][1, 1, day]),
                        Float64(output["csoilslow"][1, 1, day]),
                        Float64(output["csoilpass"][1, 1, day]),
                    )
                    rates = CASA.decomposition_rates(
                        factors.litter,
                        factors.soil,
                        litter_base_rates,
                        soil_base_rates,
                        transfer_parameters.lignin_leaf,
                        0.21805,
                        0.13224,
                        false,
                    )
                    litter_inputs = ntuple(
                        index ->
                            next_litter[index] - litter[index] +
                            rates.litter[index] * litter[index],
                        3,
                    )
                    daily_litter_inputs[day] = litter_inputs
                    tendencies = CASA.carbon_tendencies(
                        litter,
                        soil,
                        litter_inputs,
                        rates.litter,
                        rates.soil,
                        transfers,
                    )
                    predicted_soil =
                        ntuple(index -> soil[index] + tendencies.soil[index], 3)
                    @test all(isapprox.(predicted_soil, next_soil; rtol = 2e-6))
                    @test tendencies.heterotrophic_respiration ≈
                          output["cresp"][1, 1, day] rtol = 2e-4
                    @test tendencies.passive_input ≈
                          output["cpassInpt"][1, 1, day] rtol = 5e-4
                end
            end

            seconds_per_day = 86400.0
            model_parameters = CASA.CASASoilModelParameters{
                Float64,
                typeof(transfer_parameters),
            }(;
                q10 = 1.72,
                litter_optimum = 0.4,
                soil_optimum = 0.1034,
                porosity = 0.41312,
                clay = 0.21805,
                silt = 0.13224,
                freezing_temperature = 273.15,
                litter_base_rates = litter_base_rates ./ seconds_per_day,
                soil_base_rates = soil_base_rates ./ seconds_per_day,
                transfers = transfer_parameters,
            )
            driver_day(t) = min(div(round(Int, t), 86400) + 2, 365)
            carbon_rate(day, pool) =
                daily_litter_inputs[day][pool] * 1e-3 / seconds_per_day
            drivers = CASA.PrescribedDrivers(
                t -> root_temperatures[driver_day(t)],
                t -> root_moistures[driver_day(t)],
                t -> carbon_rate(driver_day(t), 1),
                t -> carbon_rate(driver_day(t), 2),
                t -> carbon_rate(driver_day(t), 3),
            )
            domain = Point(; z_sfc = 0.0, context = ClimaComms.context())
            model = CASA.CASASoilModel{Float64}(;
                parameters = model_parameters,
                drivers,
                domain,
            )
            Y, p, _ = ClimaLand.initialize(model)
            state_names = ClimaLand.prognostic_vars(model)
            output_names = (
                "clitmetb",
                "clitstr",
                "clitcwd",
                "csoilmic",
                "csoilslow",
                "csoilpass",
            )
            initial = map(output_names) do name
                Float64(output[name][1, 1, 1]) * 1e-3
            end
            expected = map(output_names) do name
                Float64(output[name][1, 1, 365]) * 1e-3
            end
            for (name, value) in zip(state_names, initial)
                getproperty(Y.casa_soil, name) .= value
            end
            tendency! = ClimaLand.make_exp_tendency(model)
            set_initial_cache! = ClimaLand.make_set_initial_cache(model)
            set_initial_cache!(p, Y, 0.0)
            problem = CTS.ODEProblem(
                CTS.ClimaODEFunction((T_exp!) = tendency!),
                Y,
                (0.0, 364seconds_per_day),
                p,
            )
            integrator = CTS.init(
                problem,
                FORWARD_EULER;
                dt = seconds_per_day,
                save_everystep = false,
            )
            for _ in 1:364
                CTS.step!(integrator)
            end
            actual = map(state_names) do name
                Array(parent(getproperty(integrator.u.casa_soil, name)))[1]
            end
            @test all(isapprox.(actual, expected; rtol = 5e-5))
        end
    end
end
