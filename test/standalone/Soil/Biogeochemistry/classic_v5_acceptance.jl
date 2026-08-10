using Test
import ClimaLand
using ClimaLand.Soil.Biogeochemistry

include("classic_v5_reference.jl")
using .CLASSICV5Reference

const CLASSIC = Biogeochemistry.CLASSIC

function v5_parameter(field)
    return only(field)
end

function v5_transfer(snapshot, prefix)
    return CLASSIC.StageBTransfer(
        read_field(snapshot, prefix * "_delta_litter"),
        read_field(snapshot, prefix * "_delta_soil"),
    )
end

function v5_parameters(snapshot)
    field(name) = read_field(snapshot, "static." * name)
    return CLASSIC.CLASSICParameters(;
        thpor = field("thpor"),
        psisat = field("psisat"),
        bi = field("bi"),
        isand = field("isand"),
        zbotw = field("zbotw"),
        zbot = vec(field("zbot")),
        delzw = field("delzw"),
        sort = vec(field("sort")),
        bsratelt = vec(field("bsratelt")),
        bsratesc = vec(field("bsratesc")),
        humicfac = vec(field("humicfac")),
        bsratelt_g = v5_parameter(field("bsratelt_g")),
        bsratesc_g = v5_parameter(field("bsratesc_g")),
        humicfac_bg = v5_parameter(field("humicfac_bg")),
        tanhq10 = vec(field("tanhq10")),
        deltat = v5_parameter(field("deltat")),
        tfrez = v5_parameter(field("tfrez")),
        zero = v5_parameter(field("zero")),
        tcrit = v5_parameter(field("tcrit")),
        frozered = v5_parameter(field("frozered")),
        r_depthredu = v5_parameter(field("r_depthredu")),
        cryodiffus = v5_parameter(field("cryodiffus")),
        biodiffus = v5_parameter(field("biodiffus")),
        kterm = v5_parameter(field("kterm")),
        spinfast = v5_parameter(field("spinfast")),
        turbation_on = !iszero(v5_parameter(field("turbation_on"))),
    )
end

function v5_forcing(snapshot)
    field(name) = read_field(snapshot, "forcing." * name)
    return CLASSIC.CLASSICForcing(;
        tbar = field("tbar"),
        thliq = field("thliq"),
        thice = field("thice"),
        fcancmx = field("fcancmx"),
        fg = vec(field("fg")),
        rmrveg = field("rmrveg"),
        rmr = vec(field("rmr")),
        max_annual_active_layer = vec(field("max_annual_active_layer")),
        competition = v5_transfer(snapshot, "forcing.pre_resp_competition"),
        land_use = v5_transfer(snapshot, "forcing.pre_resp_land_use"),
        harvest = v5_transfer(snapshot, "forcing.pre_resp_harvest"),
        turnover = v5_transfer(snapshot, "forcing.post_resp_turnover"),
        mortality = v5_transfer(snapshot, "forcing.post_resp_mortality"),
        disturbance = v5_transfer(snapshot, "forcing.post_resp_disturbance"),
    )
end

function comparison_error(actual, expected)
    absolute = abs.(actual .- expected)
    maximum_absolute = maximum(absolute)
    relative = map(absolute, expected) do error, value
        iszero(value) ? (iszero(error) ? 0.0 : Inf) : error / abs(value)
    end
    return (; maximum_absolute, maximum_relative = maximum(relative))
end

function required_v5_snapshot_root(environment = ENV)
    configured = get(environment, "CLASSIC_V5_SNAPSHOT_ROOT", nothing)
    (isnothing(configured) || isempty(strip(configured))) && throw(
        ArgumentError(
            "set CLASSIC_V5_SNAPSHOT_ROOT to the v5 snapshot directory",
        ),
    )
    root = abspath(configured)
    isdir(root) ||
        throw(ArgumentError("CLASSIC v5 evidence root does not exist: $root"))
    return root
end

@testset "CLASSIC v5 snapshot root is explicit" begin
    @test_throws ArgumentError required_v5_snapshot_root(Dict{String, String}())
    mktempdir() do directory
        @test required_v5_snapshot_root(
            Dict("CLASSIC_V5_SNAPSHOT_ROOT" => directory),
        ) == abspath(directory)
    end
end

function budget_terms(pre, after_pre, after_pool, before_turbation, post)
    return (
        litter_pre = sum(pre.litrmass),
        litter_pre_transfer = sum(after_pre.litrmass) - sum(pre.litrmass),
        litter_respiration_update = sum(after_pool.litrmass) -
                                    sum(after_pre.litrmass),
        litter_post_transfer = sum(before_turbation.litrmass) -
                               sum(after_pool.litrmass),
        litter_turbation = sum(post.litrmass) - sum(before_turbation.litrmass),
        litter_post = sum(post.litrmass),
        soil_pre = sum(pre.soilcmas),
        soil_pre_transfer = sum(after_pre.soilcmas) - sum(pre.soilcmas),
        soil_respiration_update = sum(after_pool.soilcmas) -
                                  sum(after_pre.soilcmas),
        soil_post_transfer = sum(before_turbation.soilcmas) -
                             sum(after_pool.soilcmas),
        soil_turbation = sum(post.soilcmas) - sum(before_turbation.soilcmas),
        soil_post = sum(post.soilcmas),
    )
end

function run_v5_acceptance()
    @testset "v5 ordinary native-geometry parity" begin
        evidence_root = required_v5_snapshot_root()
        snapshot = load_ordinary_snapshot(evidence_root)
        @test_throws ArgumentError load_ordinary_snapshot(
            joinpath(evidence_root, "missing"),
        )
        tolerance = (; atol = 0.0, rtol = 0.0)
        @test snapshot.receipt["status"] == "complete"
        pre = CLASSIC.CLASSICState(
            read_field(snapshot, "pre.litrmass"),
            read_field(snapshot, "pre.soilcmas"),
        )
        forcing = v5_forcing(snapshot)
        parameters = v5_parameters(snapshot)
        transition = CLASSIC.advance_stage_b(pre, parameters, forcing)

        expected = Dict(
            "intermediate.after_pool_update_litrmass" =>
                transition.phases.after_pool_update.litrmass,
            "intermediate.after_pool_update_soilcmas" =>
                transition.phases.after_pool_update.soilcmas,
            "intermediate.before_turbation_litrmass" =>
                transition.phases.before_turbation.litrmass,
            "intermediate.before_turbation_soilcmas" =>
                transition.phases.before_turbation.soilcmas,
            "post.litrmass" => transition.state.litrmass,
            "post.soilcmas" => transition.state.soilcmas,
            "audit.ltresveg" => transition.audit.ltresveg,
            "audit.scresveg" => transition.audit.scresveg,
            "audit.hetrsveg" => transition.audit.hetrsveg,
            "audit.litres" => transition.audit.litres,
            "audit.socres" => transition.audit.socres,
            "audit.hetrores" => transition.audit.hetrores,
            "audit.soilresp" => transition.audit.soilresp,
            "audit.humtrsvg" => transition.audit.humtrsvg,
            "audit.humiftrs" => transition.audit.humiftrs,
            "audit.turbation_delta_litter" =>
                transition.audit.turbation_litter_delta,
            "audit.turbation_delta_soil" =>
                transition.audit.turbation_soil_delta,
        )
        achieved = Dict{String, NamedTuple}()
        for (name, actual) in expected
            reference = read_field(snapshot, name)
            error = comparison_error(actual, reference)
            achieved[name] = error
            @test error.maximum_absolute <= tolerance.atol
            @test error.maximum_relative <= tolerance.rtol
        end

        after_pre_reference = CLASSIC.CLASSICState(
            pre.litrmass +
            forcing.competition.litter +
            forcing.land_use.litter +
            forcing.harvest.litter,
            pre.soilcmas +
            forcing.competition.soil +
            forcing.land_use.soil +
            forcing.harvest.soil,
        )
        reference_terms = budget_terms(
            pre,
            after_pre_reference,
            CLASSIC.CLASSICState(
                read_field(snapshot, "intermediate.after_pool_update_litrmass"),
                read_field(snapshot, "intermediate.after_pool_update_soilcmas"),
            ),
            CLASSIC.CLASSICState(
                read_field(snapshot, "intermediate.before_turbation_litrmass"),
                read_field(snapshot, "intermediate.before_turbation_soilcmas"),
            ),
            CLASSIC.CLASSICState(
                read_field(snapshot, "post.litrmass"),
                read_field(snapshot, "post.soilcmas"),
            ),
        )
        actual_terms = budget_terms(
            pre,
            transition.phases.after_pre_transfers,
            transition.phases.after_pool_update,
            transition.phases.before_turbation,
            transition.state,
        )
        budget_achieved = Dict{Symbol, NamedTuple}()
        for name in propertynames(actual_terms)
            error =
                comparison_error([actual_terms[name]], [reference_terms[name]])
            budget_achieved[name] = error
            @test error.maximum_absolute <= tolerance.atol
            @test error.maximum_relative <= tolerance.rtol
        end
        @test all(iszero, transition.audit.litter_clamp_correction)
        @test all(iszero, transition.audit.soil_clamp_correction)
        @test all(diff(parameters.zbot) .> 0.0)
        model = CLASSIC.CLASSICSoilModel(
            parameters;
            drivers = CLASSIC.ConstantForcingProvider(forcing),
        )
        top_edges = [0.0; parameters.zbot[1:(end - 1)]]
        expected_centers = -reverse((top_edges + parameters.zbot) ./ 2.0)
        @test vec(parent(model.domain.fields.z)) == expected_centers
        Y, _, _ = ClimaLand.initialize(model)
        CLASSIC.set_prognostic_state!(Y, pre)
        callback = only(
            ClimaLand.get_model_callbacks(
                model;
                t0 = 0.0,
                Δt = model.callback_period,
            ),
        )
        callback.affect!((; u = Y, t = model.callback_period))
        callback_state = CLASSIC.state_from_prognostic(Y)
        @test callback_state.litrmass == read_field(snapshot, "post.litrmass")
        @test callback_state.soilcmas == read_field(snapshot, "post.soilcmas")

        @info "CLASSIC v5 ordinary parity" receipt_sha256 =
            COMPLETE_RECEIPT_SHA256 tolerance achieved budget_achieved
    end
    return nothing
end
run_v5_acceptance()
