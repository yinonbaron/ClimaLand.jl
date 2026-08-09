import SHA
import TOML

sha256sum(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

const INTEGER_FIELDS = Set((
    "static.isand",
    "static.sort",
    "static.spinfast",
    "static.mineral_mask",
    "static.turbation_on",
))

function field_role(name)
    startswith(name, "pre.") && return ("pre_state", "owned_state")
    startswith(name, "post.") && return ("post_state", "reference_state")
    startswith(name, "intermediate.") &&
        return ("intermediate_state", "reference_state")
    startswith(name, "audit.") && return ("audit", "audit_diagnostic")
    startswith(name, "static.") && return ("forcing", "parameter")
    startswith(name, "forcing.") && return ("forcing", "external_forcing")
    error("unclassified raw field: $name")
end

function field_units(name)
    if occursin("litrmass", name) || occursin("soilcmas", name)
        return "kg C m-2"
    end
    if occursin("delta_litter", name) ||
       occursin("delta_soil", name) ||
       occursin("turbation_delta", name)
        return "kg C m-2 step-1"
    end
    name == "forcing.tbar" && return "K"
    name in ("forcing.thliq", "forcing.thice", "static.thpor") &&
        return "m3 m-3"
    name in (
        "forcing.max_annual_active_layer",
        "static.psisat",
        "static.zbot",
        "static.zbotw",
        "static.delzw",
    ) && return "m"
    name in (
        "forcing.rmr",
        "forcing.rmrveg",
        "audit.ltresveg",
        "audit.scresveg",
        "audit.humtrsvg",
        "audit.hetrsveg",
        "audit.litres",
        "audit.socres",
        "audit.hetrores",
        "audit.humiftrs",
    ) && return "umol CO2 m-2 s-1"
    name == "audit.soilresp" && return "kg C m-2 step-1"
    name in ("static.biodiffus", "static.cryodiffus") && return "m2 d-1"
    name in (
        "static.bsratelt",
        "static.bsratesc",
        "static.bsratelt_g",
        "static.bsratesc_g",
    ) && return "kg C kgC-1 yr-1"
    name == "static.r_depthredu" && return "m"
    name == "static.deltat" && return "d"
    name == "static.tfrez" && return "K"
    name == "static.tcrit" && return "degC"
    return "1"
end

function seal_raw_snapshot(
    directory;
    transition,
    time_start,
    time_end,
    source_commit,
    source_sha256,
    patch_sha256,
    executable_sha256,
    job_options_sha256,
    model_parameters_sha256,
    initialization_sha256,
)
    isfile(joinpath(directory, "manifest.toml")) &&
        error("snapshot already sealed")
    payloads = sort!(filter(name -> endswith(name, ".bin"), readdir(directory)))
    isempty(payloads) && error("raw snapshot has no payloads")
    records = Dict{String, Any}[]
    names = String[]
    for payload in payloads
        name = payload[1:(end - 4)]
        shape_path = joinpath(directory, name * ".shape")
        isfile(shape_path) || error("missing shape for $name")
        shape = parse.(Int, split(strip(read(shape_path, String))))
        phase, role = field_role(name)
        dtype = name in INTEGER_FIELDS ? "int32" : "float64"
        bytes_per_value = dtype == "int32" ? 4 : 8
        path = joinpath(directory, payload)
        filesize(path) == prod(shape) * bytes_per_value ||
            error("payload byte count is inconsistent for $name")
        push!(names, name)
        push!(
            records,
            Dict(
                "name" => name,
                "phase" => phase,
                "role" => role,
                "units" => field_units(name),
                "dtype" => dtype,
                "shape" => shape,
                "order" => "fortran_column_major",
                "endianness" => "little",
                "path" => payload,
                "bytes" => filesize(path),
                "sha256" => sha256sum(path),
            ),
        )
    end
    manifest = Dict(
        "schema_version" => 1,
        "snapshot" => Dict(
            "site" => "DE-Hai",
            "transition" => transition,
            "time_start" => time_start,
            "time_end" => time_end,
            "deltat_days" => 1,
            "source_commit" => source_commit,
            "source_sha256" => source_sha256,
            "patch_sha256" => patch_sha256,
            "executable_sha256" => executable_sha256,
            "job_options_sha256" => job_options_sha256,
            "model_parameters_sha256" => model_parameters_sha256,
            "initialization_sha256" => initialization_sha256,
            "required_fields" => names,
        ),
        "field" => records,
    )
    open(joinpath(directory, "manifest.toml"), "w") do io
        TOML.print(io, manifest; sorted = true)
    end
    return manifest
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 11 || error(
        "usage: seal_raw_snapshot.jl DIR TRANSITION START END COMMIT SOURCE_SHA PATCH_SHA EXE_SHA JOB_SHA PARAM_SHA INIT_SHA",
    )
    seal_raw_snapshot(
        ARGS[1];
        transition = ARGS[2],
        time_start = ARGS[3],
        time_end = ARGS[4],
        source_commit = ARGS[5],
        source_sha256 = ARGS[6],
        patch_sha256 = ARGS[7],
        executable_sha256 = ARGS[8],
        job_options_sha256 = ARGS[9],
        model_parameters_sha256 = ARGS[10],
        initialization_sha256 = ARGS[11],
    )
end
