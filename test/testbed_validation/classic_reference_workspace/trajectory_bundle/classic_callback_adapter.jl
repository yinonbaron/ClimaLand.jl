module ClassicCallbackAdapter

import ClimaLand
using ClimaLand.Soil.Biogeochemistry

export classic_callback_transition

const CLASSIC = Biogeochemistry.CLASSIC

scalar(values) = only(values)

function parameters_from_static(static)
    return CLASSIC.CLASSICParameters(;
        thpor = static["static.thpor"],
        psisat = static["static.psisat"],
        bi = static["static.bi"],
        isand = static["static.isand"],
        zbotw = static["static.zbotw"],
        zbot = vec(static["static.zbot"]),
        delzw = static["static.delzw"],
        sort = vec(static["static.sort"]),
        bsratelt = vec(static["parameter.bsratelt"]),
        bsratesc = vec(static["parameter.bsratesc"]),
        humicfac = vec(static["parameter.humicfac"]),
        bsratelt_g = scalar(static["parameter.bsratelt_g"]),
        bsratesc_g = scalar(static["parameter.bsratesc_g"]),
        humicfac_bg = scalar(static["parameter.humicfac_bg"]),
        tanhq10 = vec(static["parameter.tanhq10"]),
        deltat = scalar(static["parameter.deltat_days"]),
        tfrez = scalar(static["parameter.tfrez"]),
        zero = scalar(static["parameter.zero"]),
        tcrit = scalar(static["parameter.tcrit"]),
        frozered = scalar(static["parameter.frozered"]),
        r_depthredu = scalar(static["parameter.r_depthredu"]),
        cryodiffus = scalar(static["parameter.cryodiffus"]),
        biodiffus = scalar(static["parameter.biodiffus"]),
        kterm = scalar(static["parameter.kterm"]),
        spinfast = scalar(static["parameter.spinfast"]),
        turbation_on = !iszero(scalar(static["parameter.turbation_on"])),
    )
end

function transfer(drivers, prefix)
    return CLASSIC.StageBTransfer(
        drivers[prefix * "_delta_litter"],
        drivers[prefix * "_delta_soil"],
    )
end

function forcing_from_drivers(drivers)
    return CLASSIC.CLASSICForcing(;
        tbar = drivers["driver.tbar"],
        thliq = drivers["driver.thliq"],
        thice = drivers["driver.thice"],
        fcancmx = drivers["driver.fcancmx"],
        fg = vec(drivers["driver.fg"]),
        rmrveg = drivers["driver.rmrveg"],
        rmr = vec(drivers["driver.rmr"]),
        max_annual_active_layer = vec(
            drivers["driver.max_annual_active_layer"],
        ),
        competition = transfer(drivers, "driver.pre_resp_competition"),
        land_use = transfer(drivers, "driver.pre_resp_land_use"),
        harvest = transfer(drivers, "driver.pre_resp_harvest"),
        turnover = transfer(drivers, "driver.post_resp_turnover"),
        mortality = transfer(drivers, "driver.post_resp_mortality"),
        disturbance = transfer(drivers, "driver.post_resp_disturbance"),
    )
end

function transition_result(transition)
    audit = transition.audit
    litter_residual =
        dropdims(sum(audit.turbation_litter_delta; dims = 3); dims = 3)
    soil_residual =
        dropdims(sum(audit.turbation_soil_delta; dims = 3); dims = 3)
    return (
        state = Dict(
            "litrmass" => copy(transition.state.litrmass),
            "soilcmas" => copy(transition.state.soilcmas),
        ),
        checkpoints = Dict(
            "reference.after_pool_update_litrmass" =>
                transition.phases.after_pool_update.litrmass,
            "reference.after_pool_update_soilcmas" =>
                transition.phases.after_pool_update.soilcmas,
            "reference.before_turbation_litrmass" =>
                transition.phases.before_turbation.litrmass,
            "reference.before_turbation_soilcmas" =>
                transition.phases.before_turbation.soilcmas,
        ),
        audits = Dict(
            "audit.ltresveg" => audit.ltresveg,
            "audit.scresveg" => audit.scresveg,
            "audit.humtrsvg" => audit.humtrsvg,
            "audit.hetrsveg" => audit.hetrsveg,
            "audit.litres" => audit.litres,
            "audit.socres" => audit.socres,
            "audit.hetrores" => audit.hetrores,
            "audit.soilresp" => audit.soilresp,
            "audit.humiftrs" => audit.humiftrs,
            "audit.litter_clamp_correction" => audit.litter_clamp_correction,
            "audit.soil_clamp_correction" => audit.soil_clamp_correction,
            "audit.turbation_delta_litter" => audit.turbation_litter_delta,
            "audit.turbation_delta_soil" => audit.turbation_soil_delta,
            "audit.turbation_litter_column_residual" => litter_residual,
            "audit.turbation_soil_column_residual" => soil_residual,
        ),
    )
end

mutable struct CallbackTransition{M, Y, C, D}
    model::M
    prognostic::Y
    callback::C
    drivers::D
    next_index::Int
end

function (adapter::CallbackTransition)(state, _, drivers, _, _)
    adapter.next_index <= length(adapter.drivers) ||
        throw(ArgumentError("callback transition has no remaining forcing"))
    current = CLASSIC.state_from_prognostic(adapter.prognostic)
    current.litrmass == state["litrmass"] &&
    current.soilcmas == state["soilcmas"] ||
        throw(ArgumentError("caller attempted recurrent state replacement"))
    expected = adapter.drivers[adapter.next_index]
    all(
        haskey(drivers, name) && drivers[name] == values for
        (name, values) in expected
    ) ||
        throw(ArgumentError("driver chronology differs from callback provider"))
    time = adapter.next_index * adapter.model.callback_period
    transition = adapter.callback.affect!((; u = adapter.prognostic, t = time))
    adapter.next_index += 1
    return transition_result(transition)
end

"""
    classic_callback_transition(replay)

Create one initialized CLASSIC model and its accepted daily callback for a full
trajectory. The returned callable advances only its Julia prognostic state;
reference states are used solely by the comparison reporter.
"""
function classic_callback_transition(replay)
    parameters = parameters_from_static(replay.static_data)
    drivers = Tuple(step.drivers for step in replay.steps)
    forcings = Tuple(forcing_from_drivers(driver) for driver in drivers)
    period = 24.0 * 60.0 * 60.0
    times = Tuple(index * period for index in eachindex(forcings))
    provider = CLASSIC.PrescribedDailyForcingProvider(times, forcings)
    model = CLASSIC.CLASSICSoilModel(
        parameters;
        drivers = provider,
        callback_period = period,
    )
    prognostic, _, _ = ClimaLand.initialize(model)
    initial = CLASSIC.CLASSICState(
        copy(replay.initial_state["initial.litrmass"]),
        copy(replay.initial_state["initial.soilcmas"]),
    )
    CLASSIC.set_prognostic_state!(prognostic, initial)
    callback = only(ClimaLand.get_model_callbacks(model; t0 = 0.0, Δt = period))
    return CallbackTransition(model, prognostic, callback, drivers, 1)
end

end
