import SHA
import TOML
using Dates

const SYNTHETIC_SHA = repeat("a", 64)
const SYNTHETIC_COMMIT = repeat("b", 40)

function synthetic_values(field, dimensions)
    shape = Tuple(dimensions[name] for name in field["dimensions"])
    dtype = Dict("float64" => Float64, "int32" => Int32)[field["dtype"]]
    return fill(dtype(1), shape)
end

function write_payload(root, relative_path, values)
    path = joinpath(root, relative_path)
    mkpath(dirname(path))
    open(path, "w") do io
        write(io, values)
    end
    return bytes2hex(SHA.sha256(read(path)))
end

function synthetic_record(root, field, dimensions, suffix)
    values = synthetic_values(field, dimensions)
    relative_path = joinpath(
        "payloads",
        suffix,
        replace(field["name"], "." => "_") * ".bin",
    )
    return Dict(
        "name" => field["name"],
        "section" => field["section"],
        "role" => field["role"],
        "units" => field["units"],
        "dtype" => field["dtype"],
        "dimensions" => field["dimensions"],
        "shape" => collect(size(values)),
        "sampling" => field["sampling"],
        "application_phase" => field["application_phase"],
        "path" => relative_path,
        "bytes" => sizeof(eltype(values)) * length(values),
        "sha256" => write_payload(root, relative_path, values),
    )
end

function write_synthetic_bundle(
    root,
    schema_path;
    step_count = 2,
    shared_step_payloads = false,
)
    mkpath(root)
    schema = load_bundle_schema(schema_path)
    dimensions = Dict(
        "tile" => 1,
        "pft" => 12,
        "pft_and_bare" => 13,
        "soil_layer" => 20,
        "parameter_pft" => 15,
        "q10_parameter" => 4,
    )
    static_fields = filter(
        field -> field["section"] in ("static_data", "initial_state"),
        schema["field"],
    )
    step_fields = filter(
        field -> field["section"] in
        ("drivers", "reference_state", "audit_diagnostics"),
        schema["field"],
    )
    records = [
        synthetic_record(root, field, dimensions, "fixed") for
        field in static_fields
    ]
    shared_records =
        shared_step_payloads ?
        [
            synthetic_record(root, field, dimensions, "step_00000001") for
            field in step_fields
        ] : Dict{String, Any}[]
    steps = Dict{String, Any}[]
    start = DateTime(2000, 1, 1)
    for index in 1:step_count
        stop = start + Day(1)
        push!(
            steps,
            Dict(
                "index" => index,
                "time_start" => string(start),
                "time_end" => string(stop),
                "duration_days" => 1.0,
                "field" =>
                    shared_step_payloads ? shared_records :
                    [
                        synthetic_record(
                            root,
                            field,
                            dimensions,
                            "step_$index",
                        ) for field in step_fields
                    ],
            ),
        )
        start = stop
    end
    manifest = Dict(
        "schema_version" => 1,
        "storage_order" => "fortran_column_major",
        "endianness" => "little",
        "trajectory" => Dict(
            "site" => "DE-Hai",
            "calendar" => "proleptic_gregorian",
            "time_standard" => "UTC",
            "timestamp_format" => "ISO-8601",
            "evidence_status" => "synthetic",
        ),
        "provenance" => Dict(
            "source_archive_sha256" => SYNTHETIC_SHA,
            "source_commit" => SYNTHETIC_COMMIT,
            "source_tree_sha256" => SYNTHETIC_SHA,
            "executable_sha256" => SYNTHETIC_SHA,
            "parameter_namelist_sha256" => SYNTHETIC_SHA,
            "job_options_sha256" => SYNTHETIC_SHA,
            "initial_condition_sha256" => SYNTHETIC_SHA,
            "instrumentation_patch_sha256" => SYNTHETIC_SHA,
            "schema_sha256" => bytes2hex(SHA.sha256(read(schema_path))),
        ),
        "dimensions" => dimensions,
        "field" => records,
        "step" => steps,
    )
    open(joinpath(root, "manifest.toml"), "w") do io
        TOML.print(io, manifest; sorted = true)
    end
    return root
end

function rewrite_manifest(f, root)
    path = joinpath(root, "manifest.toml")
    manifest = TOML.parsefile(path)
    f(manifest)
    open(path, "w") do io
        TOML.print(io, manifest; sorted = true)
    end
end

callback_zero_transfer() = zeros(Float64, 1, 13, 20)

function callback_static_data()
    return Dict{String, Any}(
        "static.thpor" => fill(0.5, 1, 20),
        "static.psisat" => fill(4.0, 1, 20),
        "static.zbotw" => reshape(collect(0.1:0.1:2.0), 1, :),
        "static.zbot" => collect(0.1:0.1:2.0),
        "static.delzw" => fill(0.1, 1, 20),
        "static.bi" => fill(1.0, 1, 20),
        "static.isand" => zeros(Int32, 1, 20),
        "static.sort" => collect(Int32, 1:12),
        "static.mineral_mask" => Int32[1],
        "parameter.deltat_days" => [1.0],
        "parameter.tfrez" => [273.16],
        "parameter.zero" => [1.0e-20],
        "parameter.frozered" => [0.1],
        "parameter.humicfac_bg" => [0.0],
        "parameter.kterm" => [3.0],
        "parameter.tanhq10" => [2.16, 0.67, 0.075, 28.1],
        "parameter.bsratelt" => zeros(15),
        "parameter.bsratesc" => zeros(15),
        "parameter.bsratelt_g" => [0.0],
        "parameter.bsratesc_g" => [0.0],
        "parameter.r_depthredu" => [8.3],
        "parameter.tcrit" => [-1.0],
        "parameter.humicfac" => zeros(15),
        "parameter.cryodiffus" => [1.26873e-6],
        "parameter.biodiffus" => [3.57059e-7],
        "parameter.spinfast" => Int32[1],
        "parameter.turbation_on" => Int32[0],
    )
end

function callback_drivers(; competition = 0.0)
    competition_litter = callback_zero_transfer()
    competition_litter[1, 1, 1] = competition
    zero = callback_zero_transfer()
    return Dict{String, Any}(
        "driver.tbar" => fill(288.16, 1, 20),
        "driver.thliq" => fill(0.5, 1, 20),
        "driver.thice" => zeros(1, 20),
        "driver.fcancmx" => zeros(1, 12),
        "driver.fg" => [0.0],
        "driver.rmrveg" => zeros(1, 12),
        "driver.rmr" => [0.0],
        "driver.max_annual_active_layer" => [2.0],
        "driver.pre_resp_competition_delta_litter" => competition_litter,
        "driver.pre_resp_competition_delta_soil" => copy(zero),
        "driver.pre_resp_land_use_delta_litter" => copy(zero),
        "driver.pre_resp_land_use_delta_soil" => copy(zero),
        "driver.pre_resp_harvest_delta_litter" => copy(zero),
        "driver.pre_resp_harvest_delta_soil" => copy(zero),
        "driver.post_resp_turnover_delta_litter" => copy(zero),
        "driver.post_resp_turnover_delta_soil" => copy(zero),
        "driver.post_resp_mortality_delta_litter" => copy(zero),
        "driver.post_resp_mortality_delta_soil" => copy(zero),
        "driver.post_resp_disturbance_delta_litter" => copy(zero),
        "driver.post_resp_disturbance_delta_soil" => copy(zero),
    )
end

function callback_zero_audits()
    return Dict(
        "audit.ltresveg" => zeros(1, 13, 20),
        "audit.scresveg" => zeros(1, 13, 20),
        "audit.humtrsvg" => zeros(1, 13, 20),
        "audit.hetrsveg" => zeros(1, 13),
        "audit.litres" => zeros(1),
        "audit.socres" => zeros(1),
        "audit.hetrores" => zeros(1),
        "audit.soilresp" => zeros(1),
        "audit.humiftrs" => zeros(1),
        "audit.litter_clamp_correction" => zeros(1, 13, 20),
        "audit.soil_clamp_correction" => zeros(1, 13, 20),
        "audit.turbation_delta_litter" => zeros(1, 13, 20),
        "audit.turbation_delta_soil" => zeros(1, 13, 20),
        "audit.turbation_litter_column_residual" => zeros(1, 13),
        "audit.turbation_soil_column_residual" => zeros(1, 13),
    )
end

function callback_replay()
    initial_litter = zeros(1, 13, 20)
    initial_soil = zeros(1, 13, 20)
    expected_litter = copy(initial_litter)
    expected_litter[1, 1, 1] = 1.0
    reference = Dict(
        "reference.after_pool_update_litrmass" => expected_litter,
        "reference.after_pool_update_soilcmas" => initial_soil,
        "reference.before_turbation_litrmass" => expected_litter,
        "reference.before_turbation_soilcmas" => initial_soil,
        "reference.post_litrmass" => expected_litter,
        "reference.post_soilcmas" => initial_soil,
    )
    start = DateTime(2000, 1, 1)
    steps = [
        ClassicTrajectoryBundle.TrajectoryStep(
            index,
            start + Day(index - 1),
            start + Day(index),
            callback_drivers(; competition = index == 1 ? 1.0 : 0.0),
            deepcopy(reference),
            callback_zero_audits(),
        ) for index in 1:2
    ]
    return ClassicTrajectoryBundle.TrajectoryReplay(
        Dict{String, Any}(),
        callback_static_data(),
        Dict(
            "initial.litrmass" => initial_litter,
            "initial.soilcmas" => initial_soil,
        ),
        steps,
        "synthetic",
    )
end

function callback_initial_state(replay)
    return Dict(
        "litrmass" => copy(replay.initial_state["initial.litrmass"]),
        "soilcmas" => copy(replay.initial_state["initial.soilcmas"]),
    )
end
