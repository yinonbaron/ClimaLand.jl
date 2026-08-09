using Test
import ClimaLand
using ClimaLand.Soil.Biogeochemistry
using StaticArrays

const CLASSIC = Biogeochemistry.CLASSIC

allocated_advance(model, Y, time) = @allocated CLASSIC.advance!(model, Y, time)

function test_parameters(
    ::Type{FT} = Float64;
    turbation_on = false,
    humicfac = [FT(0.5); zeros(FT, 14)],
) where {FT}
    return CLASSIC.CLASSICParameters(;
        thpor = fill(FT(0.5), 1, 20),
        psisat = fill(FT(4), 1, 20),
        bi = fill(one(FT), 1, 20),
        isand = fill(Int32(0), 1, 20),
        zbotw = reshape(collect(FT(0.1):FT(0.1):FT(2)), 1, :),
        zbot = cumsum(collect(FT(0.05):FT(0.01):FT(0.24))),
        delzw = reshape(collect(FT(0.05):FT(0.01):FT(0.24)), 1, :),
        sort = Int32[1, 2, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14],
        bsratelt = [one(FT); zeros(FT, 14)],
        bsratesc = [FT(0.5); zeros(FT, 14)],
        humicfac,
        bsratelt_g = zero(FT),
        bsratesc_g = zero(FT),
        humicfac_bg = FT(0.45),
        tanhq10 = FT[2.16, 0.67, 0.075, 28.1],
        deltat = one(FT),
        tfrez = FT(273.16),
        zero = FT(1.0e-20),
        tcrit = -one(FT),
        frozered = FT(0.1),
        r_depthredu = FT(8.3),
        cryodiffus = FT(1.26873e-6),
        biodiffus = FT(3.57059e-7),
        kterm = FT(3),
        spinfast = Int32(1),
        turbation_on,
    )
end

function zero_transfer(::Type{FT} = Float64) where {FT}
    shape = (1, 13, 20)
    return CLASSIC.StageBTransfer(zeros(FT, shape), zeros(FT, shape))
end

test_forcing(transfers = ntuple(_ -> zero_transfer(), 6)) =
    test_forcing(Float64, transfers)

function test_forcing(
    ::Type{FT},
    transfers = ntuple(_ -> zero_transfer(FT), 6),
) where {FT}
    return CLASSIC.CLASSICForcing(;
        tbar = fill(FT(288.16), 1, 20),
        thliq = fill(FT(0.5), 1, 20),
        thice = zeros(FT, 1, 20),
        fcancmx = [one(FT) zeros(FT, 1, 11)],
        fg = [zero(FT)],
        rmrveg = [one(FT) zeros(FT, 1, 11)],
        rmr = [one(FT)],
        max_annual_active_layer = [FT(2)],
        competition = transfers[1],
        land_use = transfers[2],
        harvest = transfers[3],
        turnover = transfers[4],
        mortality = transfers[5],
        disturbance = transfers[6],
    )
end

@testset "CLASSIC exported API is documented" begin
    for name in setdiff(names(CLASSIC), (:CLASSIC,))
        @test Base.Docs.hasdoc(CLASSIC, name)
    end
end

@testset "CLASSIC developer hot paths are documented" begin
    for name in (
        :_respiration!,
        :_update_pools_cached!,
        :_solve_mixing!,
        :_mix_column_cached!,
        :_turbate!,
        :advance_stage_b!,
        :DailyAdvance,
    )
        @test Base.Docs.hasdoc(CLASSIC, name)
    end
end

@testset "CLASSIC supports Float32 and Float64" begin
    for FT in (Float32, Float64)
        parameters = test_parameters(FT)
        forcing = test_forcing(FT)
        state = CLASSIC.CLASSICState(zeros(FT, 1, 13, 20), zeros(FT, 1, 13, 20))
        transition =
            @inferred CLASSIC.advance_stage_b(state, parameters, forcing)
        @test eltype(transition.state.litrmass) == FT
        @test eltype(transition.audit.ltresveg) == FT
        model = CLASSIC.CLASSICSoilModel(
            parameters;
            drivers = CLASSIC.ConstantForcingProvider(forcing),
        )
        @test model isa Biogeochemistry.AbstractSoilBiogeochemistryModel{FT}
        @test ClimaLand.prognostic_types(model) ==
              (SVector{13, FT}, SVector{13, FT})
    end
end

@testset "CLASSIC typed Stage B interface" begin
    parameters = test_parameters()
    provider = CLASSIC.ConstantForcingProvider(test_forcing())
    model = CLASSIC.CLASSICSoilModel(parameters; drivers = provider)
    @test model isa Biogeochemistry.AbstractSoilBiogeochemistryModel{Float64}
    @test ClimaLand.name(model) == :classic_soil
    @test ClimaLand.prognostic_vars(model) == (:litrmass, :soilcmas)
    @test ClimaLand.prognostic_types(model) ==
          (SVector{13, Float64}, SVector{13, Float64})
    @test ClimaLand.prognostic_domain_names(model) == (:subsurface, :subsurface)
    @test length(ClimaLand.get_model_callbacks(model; t0 = 0.0, Δt = 3600.0)) ==
          1
    centers = vec(parent(model.domain.fields.z))
    top_edges = [0.0; vec(parameters.zbot)[1:(end - 1)]]
    expected_centers = -reverse((top_edges + vec(parameters.zbot)) ./ 2.0)
    @test centers == expected_centers
    Y, _, _ = ClimaLand.initialize(model)
    @test eltype(Y.classic_soil.litrmass) == SVector{13, Float64}
    @test length(parent(Y.classic_soil.litrmass)) == 13 * 20
    state = CLASSIC.CLASSICState(
        zeros(Float64, 1, 13, 20),
        zeros(Float64, 1, 13, 20),
    )
    state.litrmass .= reshape(collect(1.0:260.0), 1, 13, 20)
    state.soilcmas .= 2.0 .* state.litrmass
    CLASSIC.set_prognostic_state!(Y, state)
    recovered = CLASSIC.state_from_prognostic(Y)
    @test recovered.litrmass == state.litrmass
    @test recovered.soilcmas == state.soilcmas
    initial = CLASSIC.CLASSICState(
        zeros(Float64, 1, 13, 20),
        zeros(Float64, 1, 13, 20),
    )
    initial.litrmass[1, 1, 1] = 1.0
    initial.soilcmas[1, 1, 1] = 2.0
    CLASSIC.set_prognostic_state!(Y, initial)
    expected = CLASSIC.advance_stage_b(initial, parameters, provider.forcing)
    transition = CLASSIC.advance!(model, Y, model.callback_period)
    advanced = CLASSIC.state_from_prognostic(Y)
    @test advanced.litrmass == expected.state.litrmass
    @test advanced.soilcmas == expected.state.soilcmas
    @test transition.audit.hetrores == expected.audit.hetrores
    CLASSIC.set_prognostic_state!(Y, initial)
    CLASSIC.advance!(model, Y, 2 * model.callback_period)
    CLASSIC.set_prognostic_state!(Y, initial)
    allocated_advance(model, Y, 3 * model.callback_period)
    @test allocated_advance(model, Y, 4 * model.callback_period) == 0
    @test @inferred(CLASSIC.forcing_at(provider, 0.0)) === provider.forcing
    @test size(state.litrmass) == (1, 13, 20)
    @test_throws ArgumentError CLASSIC.CLASSICState(
        zeros(Float64, 1, 12, 20),
        zeros(Float64, 1, 12, 20),
    )
end

@testset "one synthetic Stage B transition" begin
    litter = zeros(Float64, 1, 13, 20)
    soil = zeros(Float64, 1, 13, 20)
    litter[1, 1, 1] = 1.0
    soil[1, 1, 1] = 2.0
    transfers = collect(ntuple(_ -> zero_transfer(), 6))
    transfers[1].litter[1, 1, 1] = 0.1
    transfers[4].litter[1, 1, 1] = 0.2
    transfers[5].litter[1, 1, 1] = 0.3
    transfers[6].soil[1, 1, 1] = 0.4
    transition = CLASSIC.advance_stage_b(
        CLASSIC.CLASSICState(litter, soil),
        test_parameters(),
        test_forcing(Tuple(transfers)),
    )
    litter_rate = 1.1 * 2.64
    soil_rate = 2.0 * 0.5 * 2.64
    litter_step = litter_rate / 963.62
    soil_step = soil_rate / 963.62
    humification = 0.5 * litter_step
    expected_litter = 1.1 - litter_step * 1.5 + 0.2 + 0.3
    expected_soil = 2.0 + (humification - soil_step) + 0.4
    @test transition.phases.after_pre_transfers.litrmass[1, 1, 1] == 1.1
    @test transition.phases.after_pool_update.litrmass[1, 1, 1] ==
          1.1 - litter_step * 1.5
    @test transition.phases.before_turbation.litrmass[1, 1, 1] ==
          expected_litter
    @test transition.state.litrmass[1, 1, 1] == expected_litter
    @test transition.state.soilcmas[1, 1, 1] == expected_soil
    @test count(!iszero, transition.state.litrmass) == 1
    @test count(!iszero, transition.state.soilcmas) == 1
    audit = transition.audit
    @test audit.ltresveg[1, 1, 1] == litter_rate
    @test audit.scresveg[1, 1, 1] == soil_rate
    @test audit.hetrsveg[1, 1] == litter_rate + soil_rate
    @test audit.litres == [litter_rate]
    @test audit.socres == [soil_rate]
    @test audit.hetrores == [litter_rate + soil_rate]
    @test audit.soilresp == [(litter_rate + soil_rate + 1.0) / 963.62]
    @test audit.humtrsvg[1, 1, 1] == 0.5 * litter_rate
    @test audit.humiftrs == [0.5 * litter_rate]
    @test all(iszero, audit.litter_clamp_correction)
    @test all(iszero, audit.soil_clamp_correction)
    @test all(iszero, audit.turbation_litter_delta)
    @test all(iszero, audit.turbation_soil_delta)
    @test @inferred(
        CLASSIC.advance_stage_b(
            CLASSIC.CLASSICState(litter, soil),
            test_parameters(),
            test_forcing(Tuple(transfers)),
        )
    ) isa CLASSIC.CLASSICTransition
end

@testset "CLASSIC turbation is column-conservative" begin
    litter = zeros(Float64, 1, 13, 20)
    soil = zeros(Float64, 1, 13, 20)
    litter[1, 1, 1] = 1.0
    soil[1, 1, 1] = 2.0
    transition = CLASSIC.advance_stage_b(
        CLASSIC.CLASSICState(litter, soil),
        test_parameters(; turbation_on = true),
        test_forcing(),
    )
    before = transition.phases.before_turbation
    @test sum(transition.state.litrmass[1, 1, :]) ≈
          sum(before.litrmass[1, 1, :]) atol = 1e-14
    @test sum(transition.state.soilcmas[1, 1, :]) ≈
          sum(before.soilcmas[1, 1, :]) atol = 1e-14
    @test any(!iszero, transition.audit.turbation_litter_delta[1, 1, :])
    @test any(!iszero, transition.audit.turbation_soil_delta[1, 1, :])
end

@testset "CLASSIC cached turbation is allocation-free" begin
    parameters = test_parameters(; turbation_on = true)
    forcing = test_forcing()
    model = CLASSIC.CLASSICSoilModel(
        parameters;
        drivers = CLASSIC.ConstantForcingProvider(forcing),
    )
    Y, _, _ = ClimaLand.initialize(model)
    state = CLASSIC.CLASSICState(
        zeros(Float64, 1, 13, 20),
        zeros(Float64, 1, 13, 20),
    )
    state.litrmass[1, 1, 1] = 1.0
    state.soilcmas[1, 1, 1] = 2.0
    CLASSIC.set_prognostic_state!(Y, state)
    CLASSIC.advance!(model, Y, model.callback_period)
    CLASSIC.set_prognostic_state!(Y, state)
    allocated_advance(model, Y, 2 * model.callback_period)
    CLASSIC.set_prognostic_state!(Y, state)
    @test allocated_advance(model, Y, 3 * model.callback_period) == 0
end

@testset "real transition evidence status" begin
    @test CLASSIC.REAL_TRANSITION_EVIDENCE_STATUS == :accepted_issue_101_v5
    @test CLASSIC.real_transition_is_accepted()
end


@testset "GF-Guy source-grouped litter pool update" begin
    litter = zeros(Float64, 1, 13, 20)
    litter[1, 3, 6] = 0.0035929696646960297
    litter[1, 3, 8] = 0.0014862349030113906
    litter[1, 3, 10] = 0.0006412567358375548
    state = CLASSIC.CLASSICState(litter, zeros(Float64, 1, 13, 20))
    litter_rate = zeros(Float64, 1, 13, 20)
    litter_rate[1, 3, 6] = 0.013786722898668937
    litter_rate[1, 3, 8] = 0.005611819080719647
    litter_rate[1, 3, 10] = 0.0023813514779529835
    humicfac = zeros(15)
    humicfac[4] = 0.44

    CLASSIC._update_pools!(
        state,
        test_parameters(; humicfac),
        test_forcing(),
        litter_rate,
        zeros(Float64, 1, 13, 20),
    )

    @test state.litrmass[1, 3, 6] === 0.0035723672685501594
    @test state.litrmass[1, 3, 8] === 0.0014778487969984019
    @test state.litrmass[1, 3, 10] === 0.0006376981275394162
end

@testset "SD-Dem zero-threshold pool clamp" begin
    parameters = test_parameters()
    state = CLASSIC.CLASSICState(
        zeros(Float64, 1, 13, 20),
        zeros(Float64, 1, 13, 20),
    )
    state.litrmass[1, 9, 11] = 8.197828980008096e-21
    state.soilcmas[1, 9, 11] = 1.2938854150920733e-23

    CLASSIC._update_pools!(
        state,
        parameters,
        test_forcing(),
        zeros(Float64, 1, 13, 20),
        zeros(Float64, 1, 13, 20),
    )

    @test state.litrmass[1, 9, 11] === 0.0
    @test state.soilcmas[1, 9, 11] === 0.0
end

@testset "SD-Dem left-grouped respiration aggregation" begin
    forcing = test_forcing()
    forcing.fcancmx[1, 9] = 1.0
    state = CLASSIC.CLASSICState(fill(10.0, 1, 13, 20), fill(10.0, 1, 13, 20))
    litter_rate = zeros(Float64, 1, 13, 20)
    soil_rate = zeros(Float64, 1, 13, 20)
    litter_rate[1, 9, :] .= [
        0.5000176154656089,
        0.10965584486127578,
        0.06951007581091653,
        0.044228323058674066,
        0.028927700007824853,
        0.018767928080630554,
        0.012223062774599506,
        0.00788741946522017,
        0.005108186186339821,
        0.0032868358338255465,
        2.266934297620043e-20,
        zeros(9)...,
    ]
    soil_rate[1, 9, :] .= [
        0.1442555699004788,
        0.11192724417930353,
        0.08588470124145252,
        0.023960456501726603,
        0.015743121411282295,
        0.01032027527123857,
        0.006748052487460512,
        0.004380501097883774,
        0.0028476886086890372,
        0.0018435092912690246,
        zeros(10)...,
    ]

    audit = CLASSIC._update_pools!(
        state,
        test_parameters(),
        forcing,
        litter_rate,
        soil_rate,
    )

    @test audit[1][1, 9] === 1.2075241115357
end
