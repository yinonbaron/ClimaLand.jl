module ClassicInactiveStageB

import NCDatasets
import SHA
import TOML

export validate_inactive_stage_b_evidence, write_inactive_stage_b_evidence!

const SHA256_PATTERN = r"^[0-9a-f]{64}$"
const MASK_PATH = "payloads/fixed/static_mineral_mask.bin"
const STAGE_C_EXCLUSIONS = [
    "captured_litter_and_soil_carbon_pool_semantics",
    "captured_peat_and_moss_heterotrophic_flux_semantics",
    "captured_peat_and_moss_pool_update_semantics",
]

file_sha256(path) = bytes2hex(open(SHA.sha256, path))
valid_sha256(value) =
    value isa AbstractString && occursin(SHA256_PATTERN, value)
line_sha256(lines) = bytes2hex(SHA.sha256(join(lines, "\n")))

function exact_boolean_assignment(path, name)
    text = join(
        (first(split(line, '!'; limit = 2)) for line in eachline(path)),
        "\n",
    )
    matches = collect(
        eachmatch(Regex("(?im)\\b$(name)\\s*=\\s*\\.(true|false)\\."), text),
    )
    length(matches) == 1 ||
        throw(ArgumentError("job options must assign $name exactly once"))
    return lowercase(only(matches).captures[1]) == "true"
end

function integer_variable(path, name)
    values, type_name, shape = NCDatasets.NCDataset(path) do dataset
        haskey(dataset, name) ||
            throw(ArgumentError("initial condition lacks $name"))
        variable = dataset[name]
        data = Array(variable[:])
        any(ismissing, data) &&
            throw(ArgumentError("initial $name contains missing values"))
        storage_type = Base.nonmissingtype(eltype(data))
        storage_type <: Integer ||
            throw(ArgumentError("initial $name is not integer-valued"))
        (Int.(vec(data)), string(storage_type), collect(size(data)))
    end
    isempty(values) && throw(ArgumentError("initial $name is empty"))
    return (; values, type_name, shape)
end

function unique_lines(lines, fragment)
    matches = findall(line -> occursin(fragment, line), lines)
    length(matches) == 1 || throw(
        ArgumentError(
            "source guard fragment must occur exactly once: $fragment",
        ),
    )
    return only(matches)
end

function guard_record(root, relative_path, label, fragments)
    path = normpath(joinpath(root, relative_path))
    isfile(path) || throw(ArgumentError("source guard file is missing"))
    relative = relpath(realpath(path), realpath(root))
    startswith(relative, "..") &&
        throw(ArgumentError("source guard escapes its source root"))
    lines = readlines(path)
    indices = [unique_lines(lines, fragment) for fragment in fragments]
    first_line, last_line = extrema(indices)
    excerpt = lines[first_line:last_line]
    return Dict(
        "label" => label,
        "path" => relative,
        "file_sha256" => file_sha256(path),
        "first_line" => first_line,
        "last_line" => last_line,
        "excerpt_sha256" => line_sha256(excerpt),
        "required_fragment" => collect(fragments),
    )
end

function source_guards(source_root, instrumentation_path)
    base = joinpath("src", "base")
    driver = joinpath("src", "driver")
    guards = [
        guard_record(
            source_root,
            joinpath(driver, "modelStateDrivers.f90"),
            "initial_peatland_mapping",
            (
                "ipeatland = ncGet2DVar(initid, 'ipeatland'",
                "if (ipeatland(i,j) == 0) then",
                "peatlandTyperow(i,j) = 'Bog'",
                "peatlandTyperow(i,j) = 'Fen'",
                "Unknown peatland type",
            ),
        ),
        guard_record(
            source_root,
            joinpath(driver, "modelStateDrivers.f90"),
            "initial_moss_mapping",
            (
                "imoss = ncGet2DVar(initid, 'imoss'",
                "if (imoss(i,j) == 0) then",
                "mossPresentrow(i,j) = 'Sphagnum'",
                "mossPresentrow(i,j) = 'Feather'",
                "Unknown moss type",
            ),
        ),
        guard_record(
            source_root,
            joinpath(base, "ctemDriver.F90"),
            "v5_mineral_mask_derivation",
            (
                "'static.mineral_mask', merge(1,0,peatlandType(il1:il2) == 'None')",
            ),
        ),
        guard_record(
            source_root,
            joinpath(base, "heterotrophicRespirationMod.f90"),
            "mineral_bare_ground_respiration_guard",
            (
                "if ((peatlandType(i) == 'None') .and. (fg(i) > zero .or. j == iccp2)) then",
                "scresveg(i,j,k) = socmoscl(i,k) * soilcmas(i,j,k) * bsratesc_g",
            ),
        ),
        guard_record(
            source_root,
            joinpath(base, "heterotrophicRespirationMod.f90"),
            "peat_and_sphagnum_respiration_paths",
            (
                "call soilCResPeat(il1, il2, ilg, peatlandType",
                "litresmoss(i,1) =  ltrmoscl(i,1) * litrmsmoss(i,1)",
            ),
        ),
        guard_record(
            source_root,
            joinpath(base, "heterotrophicRespirationMod.f90"),
            "vegetated_mineral_versus_peat_rates",
            (
                "if (peatlandType(i) == 'None') then !uplands",
                "scresveg(i,j,k) = socmoscl(i,k) * soilcmas(i,j,k) * bsratesc_peat",
            ),
        ),
        guard_record(
            source_root,
            joinpath(base, "heterotrophicRespirationMod.f90"),
            "peat_and_moss_flux_aggregation",
            (
                "Adjust for peatland and moss contributions",
                "socres(i) = socres(i) + socres_peat(i)",
                "if (mossPresent(i) /= 'None') then ! moss covered",
                "soilresp(i) = soilresp(i) + litresmoss(i,k) + socres_moss(i,k)",
            ),
        ),
        guard_record(
            source_root,
            joinpath(base, "heterotrophicRespirationMod.f90"),
            "peat_and_moss_pool_updates",
            (
                "For peatlands, we additionally add moss values",
                "if (mossPresent(i) == 'Sphagnum') then",
                "peatSoilC(i)  = peatSoilC(i)  + real(spinfast)",
            ),
        ),
        guard_record(
            source_root,
            joinpath(base, "soilCProcesses.f90"),
            "mineral_only_turbation_guard",
            (
                "if (peatlandType(i) == 'None') then ! turbation only occurs in mineral soils (so not in peatlands)",
            ),
        ),
    ]
    instrumentation_root = dirname(instrumentation_path)
    push!(
        guards,
        guard_record(
            instrumentation_root,
            basename(instrumentation_path),
            "checked_in_v5_mask_writer",
            (
                "'static.mineral_mask', merge(1,0,peatlandType(il1:il2) == 'None')",
            ),
        ),
    )
    return guards
end

function mask_inventory(capture_root, replay, manifest)
    haskey(replay.static_data, "static.mineral_mask") ||
        throw(ArgumentError("capture lacks static.mineral_mask"))
    raw = replay.static_data["static.mineral_mask"]
    raw isa AbstractArray ||
        throw(ArgumentError("static.mineral_mask is not an array"))
    eltype(raw) == Int32 ||
        throw(ArgumentError("static.mineral_mask dtype is not int32"))
    values = Int.(vec(collect(raw)))
    isempty(values) && throw(ArgumentError("static.mineral_mask is empty"))
    count(!iszero, values) == 0 ||
        throw(ArgumentError("capture contains an active mineral tile"))
    fields = [
        field for field in get(manifest, "field", Any[]) if
        get(field, "name", nothing) == "static.mineral_mask"
    ]
    length(fields) == 1 || throw(
        ArgumentError("manifest must declare static.mineral_mask exactly once"),
    )
    field = only(fields)
    get(field, "path", nothing) == MASK_PATH ||
        throw(ArgumentError("mineral-mask payload path differs"))
    get(field, "dtype", nothing) == "int32" ||
        throw(ArgumentError("mineral-mask manifest dtype differs"))
    get(field, "shape", nothing) == collect(size(raw)) ||
        throw(ArgumentError("mineral-mask manifest shape differs"))
    valid_sha256(get(field, "sha256", nothing)) ||
        throw(ArgumentError("mineral-mask payload hash is invalid"))
    payload_path = joinpath(capture_root, MASK_PATH)
    isfile(payload_path) ||
        throw(ArgumentError("mineral-mask payload is missing"))
    file_sha256(payload_path) == field["sha256"] ||
        throw(ArgumentError("mineral-mask payload hash differs"))
    get(field, "bytes", nothing) == filesize(payload_path) == 4length(values) ||
        throw(ArgumentError("mineral-mask payload byte count differs"))
    payload_values = open(payload_path) do io
        collect(read!(io, Vector{Int32}(undef, length(values))))
    end
    Int.(payload_values) == values ||
        throw(ArgumentError("mineral-mask payload values differ from replay"))
    return (;
        values,
        count = length(values),
        nonzero_count = 0,
        minimum = minimum(values),
        maximum = maximum(values),
        dtype = "int32",
        shape = collect(size(raw)),
        path = MASK_PATH,
        sha256 = field["sha256"],
        bytes = filesize(payload_path),
    )
end

function write_document(path, document)
    ispath(path) && throw(ArgumentError("refusing to overwrite $path"))
    mkpath(dirname(path))
    open(path, "w") do io
        TOML.print(io, document; sorted = true)
    end
    return path
end

function write_inactive_stage_b_evidence!(
    path,
    site,
    capture_root,
    replay,
    manifest,
    initial_condition_path,
    job_options_path,
    source_root,
    instrumentation_path;
    step_count,
)
    step_count isa Integer && step_count >= 365 ||
        throw(ArgumentError("inactive proof lacks a complete seasonal cycle"))
    get(manifest, "endianness", nothing) == "little" ||
        throw(ArgumentError("inactive proof requires little-endian payloads"))
    mask = mask_inventory(capture_root, replay, manifest)
    peat = integer_variable(initial_condition_path, "ipeatland")
    all(value -> value in (1, 2), peat.values) || throw(
        ArgumentError("peatland configuration contains a mineral/unknown tile"),
    )
    moss = integer_variable(initial_condition_path, "imoss")
    all(==(1), moss.values) ||
        throw(ArgumentError("inactive Stage-B moss proof requires Sphagnum"))
    length(peat.values) == mask.count == length(moss.values) || throw(
        ArgumentError("peat, moss, and mineral-mask tile inventories differ"),
    )
    peatland_type = [value == 1 ? "Bog" : "Fen" for value in peat.values]
    configuration = Dict(
        "do_peat_outputs" =>
            exact_boolean_assignment(job_options_path, "doPeatOutputs"),
        "use_static_peat_depth" =>
            exact_boolean_assignment(job_options_path, "useStaticPeatDep"),
        "turbation_switch_requested" =>
            exact_boolean_assignment(job_options_path, "turbationON"),
    )
    evidence = Dict(
        "schema_version" => 1,
        "evidence_status" => "complete",
        "site" => site,
        "stage_b_status" => "inactive",
        "reason" => "all_tiles_are_peatland_and_v5_mineral_mask_is_zero",
        "replay_claimed" => false,
        "replay_result" => "not_applicable_inactive_path",
        "complete_seasonal_cycle" => true,
        "step_count" => step_count,
        "stage_c_semantics_excluded" => true,
        "deferred_issue" => 108,
        "stage_c_exclusion" => STAGE_C_EXCLUSIONS,
        "initial_condition_sha256" => file_sha256(initial_condition_path),
        "initial_ipeatland_dtype" => peat.type_name,
        "initial_ipeatland_shape" => peat.shape,
        "ipeatland" => peat.values,
        "peatland_type" => peatland_type,
        "initial_imoss_dtype" => moss.type_name,
        "initial_imoss_shape" => moss.shape,
        "imoss" => moss.values,
        "moss_type" => fill("Sphagnum", length(moss.values)),
        "job_options_sha256" => file_sha256(job_options_path),
        "configuration" => configuration,
        "mineral_mask_path" => mask.path,
        "mineral_mask_payload_sha256" => mask.sha256,
        "mineral_mask_payload_bytes" => mask.bytes,
        "mineral_mask_dtype" => mask.dtype,
        "mineral_mask_shape" => mask.shape,
        "mineral_mask" => mask.values,
        "mineral_mask_count" => mask.count,
        "mineral_mask_nonzero_count" => mask.nonzero_count,
        "mineral_mask_minimum" => mask.minimum,
        "mineral_mask_maximum" => mask.maximum,
        "source_guard" => source_guards(source_root, instrumentation_path),
    )
    write_document(path, evidence)
    validate_inactive_stage_b_evidence(
        path,
        site,
        capture_root,
        manifest;
        expected_step_count = step_count,
        expected_initial_condition_sha256 = file_sha256(initial_condition_path),
        expected_job_options_sha256 = file_sha256(job_options_path),
    )
    return (; stage_b_status = "inactive", path, evidence)
end

function expected_guard_contract()
    return Dict(
        "initial_peatland_mapping" => (
            "src/driver/modelStateDrivers.f90",
            [
                "ipeatland = ncGet2DVar(initid, 'ipeatland'",
                "if (ipeatland(i,j) == 0) then",
                "peatlandTyperow(i,j) = 'Bog'",
                "peatlandTyperow(i,j) = 'Fen'",
                "Unknown peatland type",
            ],
        ),
        "initial_moss_mapping" => (
            "src/driver/modelStateDrivers.f90",
            [
                "imoss = ncGet2DVar(initid, 'imoss'",
                "if (imoss(i,j) == 0) then",
                "mossPresentrow(i,j) = 'Sphagnum'",
                "mossPresentrow(i,j) = 'Feather'",
                "Unknown moss type",
            ],
        ),
        "v5_mineral_mask_derivation" => (
            "src/base/ctemDriver.F90",
            [
                "'static.mineral_mask', merge(1,0,peatlandType(il1:il2) == 'None')",
            ],
        ),
        "mineral_bare_ground_respiration_guard" => (
            "src/base/heterotrophicRespirationMod.f90",
            [
                "if ((peatlandType(i) == 'None') .and. (fg(i) > zero .or. j == iccp2)) then",
                "scresveg(i,j,k) = socmoscl(i,k) * soilcmas(i,j,k) * bsratesc_g",
            ],
        ),
        "peat_and_sphagnum_respiration_paths" => (
            "src/base/heterotrophicRespirationMod.f90",
            [
                "call soilCResPeat(il1, il2, ilg, peatlandType",
                "litresmoss(i,1) =  ltrmoscl(i,1) * litrmsmoss(i,1)",
            ],
        ),
        "vegetated_mineral_versus_peat_rates" => (
            "src/base/heterotrophicRespirationMod.f90",
            [
                "if (peatlandType(i) == 'None') then !uplands",
                "scresveg(i,j,k) = socmoscl(i,k) * soilcmas(i,j,k) * bsratesc_peat",
            ],
        ),
        "peat_and_moss_flux_aggregation" => (
            "src/base/heterotrophicRespirationMod.f90",
            [
                "Adjust for peatland and moss contributions",
                "socres(i) = socres(i) + socres_peat(i)",
                "if (mossPresent(i) /= 'None') then ! moss covered",
                "soilresp(i) = soilresp(i) + litresmoss(i,k) + socres_moss(i,k)",
            ],
        ),
        "peat_and_moss_pool_updates" => (
            "src/base/heterotrophicRespirationMod.f90",
            [
                "For peatlands, we additionally add moss values",
                "if (mossPresent(i) == 'Sphagnum') then",
                "peatSoilC(i)  = peatSoilC(i)  + real(spinfast)",
            ],
        ),
        "mineral_only_turbation_guard" => (
            "src/base/soilCProcesses.f90",
            [
                "if (peatlandType(i) == 'None') then ! turbation only occurs in mineral soils (so not in peatlands)",
            ],
        ),
        "checked_in_v5_mask_writer" => (
            "generate_fortran_instrumentation.jl",
            [
                "'static.mineral_mask', merge(1,0,peatlandType(il1:il2) == 'None')",
            ],
        ),
    )
end

const CANONICAL_GUARD_METADATA = Dict(
    "initial_peatland_mapping" => (
        "cd02b68c39816b4a84ba8dc98a72ef5a829099887335d8f2af8e7d7c4b0304ac",
        952,
        1310,
        "61ee3626d2a6faa50cb2bb2a7a4ece9c60c8e546bb0c13e98c1d33a834d87204",
    ),
    "initial_moss_mapping" => (
        "cd02b68c39816b4a84ba8dc98a72ef5a829099887335d8f2af8e7d7c4b0304ac",
        953,
        1292,
        "26eca9ddc93e96fb83716a2a7cbea246bec36602d2e39197690b5b9f308dc0ab",
    ),
    "v5_mineral_mask_derivation" => (
        "a6609693eeb1c049f201f32a5e9827e905ce9bc8dfd50f630752b46aa20eab4f",
        1130,
        1130,
        "afd1f3cf41ea2c88d66167b574e3c422c4f6a877b2563ad495e17a6c6647b6c1",
    ),
    "mineral_bare_ground_respiration_guard" => (
        "f161c80c735e0d71bf3b0385e074f970be194012acf7a881c2e30d725ec28a7c",
        272,
        280,
        "9035e7af5b6406b8424e6ba35a1292a4f7c57f56f66a3c51c48e3e34cb51a428",
    ),
    "peat_and_sphagnum_respiration_paths" => (
        "f161c80c735e0d71bf3b0385e074f970be194012acf7a881c2e30d725ec28a7c",
        297,
        312,
        "9f36cad55e3f9f74fd20544760097bf300d88deb8ef0b54da423a3d8fc5aec48",
    ),
    "vegetated_mineral_versus_peat_rates" => (
        "f161c80c735e0d71bf3b0385e074f970be194012acf7a881c2e30d725ec28a7c",
        353,
        359,
        "44ceabd4036b18f514ebf4851207791e7ad82052fa978630a1bf7c00c147bb7b",
    ),
    "peat_and_moss_flux_aggregation" => (
        "f161c80c735e0d71bf3b0385e074f970be194012acf7a881c2e30d725ec28a7c",
        777,
        802,
        "c918614ac897287afc8bf86f3d3c7c9411346f73692d4cd6b3d6bbe86a2fe8ae",
    ),
    "peat_and_moss_pool_updates" => (
        "f161c80c735e0d71bf3b0385e074f970be194012acf7a881c2e30d725ec28a7c",
        895,
        925,
        "ab60b28c1310f03ba0363b592d5360c14e63f4fb05fe7b71118171b31537cb5e",
    ),
    "mineral_only_turbation_guard" => (
        "ceadc563381c5b72d7f748332db35541188d2bd7563a9aa31ec64636cf11f147",
        85,
        85,
        "3da577a84d542386d4e43e5001ccfa8191b5a963b6fc7331fc87d64856866b54",
    ),
    "checked_in_v5_mask_writer" => (
        "95051769824d8224174a727b87ed5f8aab349f4138b36d348eb9bd95ac804c0a",
        149,
        149,
        "afd1f3cf41ea2c88d66167b574e3c422c4f6a877b2563ad495e17a6c6647b6c1",
    ),
)

function guard_contract(guards)
    return Dict(
        guard["label"] => Dict(
            "path" => guard["path"],
            "file_sha256" => guard["file_sha256"],
            "first_line" => guard["first_line"],
            "last_line" => guard["last_line"],
            "excerpt_sha256" => guard["excerpt_sha256"],
            "required_fragment" => guard["required_fragment"],
        ) for guard in guards
    )
end

function canonical_guard_contract()
    base = expected_guard_contract()
    return Dict(
        label => Dict(
            "path" => base[label][1],
            "required_fragment" => base[label][2],
            "file_sha256" => metadata[1],
            "first_line" => metadata[2],
            "last_line" => metadata[3],
            "excerpt_sha256" => metadata[4],
        ) for (label, metadata) in CANONICAL_GUARD_METADATA
    )
end

const CANONICAL_GUARD_CONTRACT = canonical_guard_contract()

function independently_decode_mask(capture_root, manifest)
    fields = [
        field for field in get(manifest, "field", Any[]) if
        get(field, "name", nothing) == "static.mineral_mask"
    ]
    length(fields) == 1 ||
        throw(ArgumentError("manifest mask inventory differs"))
    field = only(fields)
    get(field, "path", nothing) == MASK_PATH ||
        throw(ArgumentError("manifest mask path differs"))
    get(field, "dtype", nothing) == "int32" ||
        throw(ArgumentError("manifest mask dtype differs"))
    shape = get(field, "shape", Any[])
    count = prod(shape; init = 1)
    count > 0 || throw(ArgumentError("manifest mask is empty"))
    payload = joinpath(capture_root, MASK_PATH)
    isfile(payload) || throw(ArgumentError("manifest mask payload is missing"))
    get(field, "bytes", nothing) == filesize(payload) == 4count ||
        throw(ArgumentError("manifest mask byte count differs"))
    file_sha256(payload) == get(field, "sha256", nothing) ||
        throw(ArgumentError("manifest mask hash differs"))
    values = open(payload) do io
        Int.(read!(io, Vector{Int32}(undef, count)))
    end
    return (; field, shape, count, values)
end

function validate_inactive_stage_b_evidence(
    path,
    site,
    capture_root,
    manifest;
    expected_step_count,
    expected_initial_condition_sha256,
    expected_job_options_sha256,
)
    evidence = TOML.parsefile(path)
    decoded = independently_decode_mask(capture_root, manifest)
    mask = get(evidence, "mineral_mask", Any[])
    peat = get(evidence, "ipeatland", Any[])
    moss = get(evidence, "imoss", Any[])
    gates = (
        get(evidence, "schema_version", nothing) == 1,
        get(evidence, "evidence_status", nothing) == "complete",
        get(evidence, "site", nothing) == site,
        get(evidence, "stage_b_status", nothing) == "inactive",
        get(evidence, "reason", nothing) ==
        "all_tiles_are_peatland_and_v5_mineral_mask_is_zero",
        get(evidence, "replay_claimed", nothing) === false,
        get(evidence, "replay_result", nothing) ==
        "not_applicable_inactive_path",
        get(evidence, "complete_seasonal_cycle", nothing) === true,
        get(evidence, "step_count", nothing) == expected_step_count,
        expected_step_count isa Integer,
        expected_step_count >= 365,
        get(evidence, "stage_c_semantics_excluded", nothing) === true,
        get(evidence, "deferred_issue", nothing) == 108,
        get(evidence, "stage_c_exclusion", nothing) == STAGE_C_EXCLUSIONS,
        get(evidence, "mineral_mask_path", nothing) == MASK_PATH,
        get(evidence, "mineral_mask_payload_sha256", nothing) ==
        decoded.field["sha256"],
        get(evidence, "mineral_mask_dtype", nothing) == "int32",
        get(evidence, "mineral_mask_shape", nothing) == decoded.shape,
        get(evidence, "mineral_mask_payload_bytes", nothing) ==
        decoded.field["bytes"],
        get(evidence, "mineral_mask_count", nothing) == decoded.count,
        get(evidence, "mineral_mask_nonzero_count", nothing) == 0,
        get(evidence, "mineral_mask_minimum", nothing) == 0,
        get(evidence, "mineral_mask_maximum", nothing) == 0,
        mask == decoded.values,
        length(mask) == length(peat) == length(moss) == decoded.count,
        all(iszero, mask),
        all(value -> value in (1, 2), peat),
        all(==(1), moss),
        get(evidence, "peatland_type", nothing) ==
        [value == 1 ? "Bog" : "Fen" for value in peat],
        get(evidence, "moss_type", nothing) == fill("Sphagnum", decoded.count),
        get(evidence, "initial_condition_sha256", nothing) ==
        expected_initial_condition_sha256,
        get(evidence, "job_options_sha256", nothing) ==
        expected_job_options_sha256,
        prod(get(evidence, "initial_ipeatland_shape", Any[]); init = 1) ==
        decoded.count,
        prod(get(evidence, "initial_imoss_shape", Any[]); init = 1) ==
        decoded.count,
        get(evidence, "initial_ipeatland_dtype", nothing) == "Int32",
        get(evidence, "initial_imoss_dtype", nothing) == "Int32",
        get(evidence, "configuration", nothing) == Dict(
            "do_peat_outputs" => true,
            "use_static_peat_depth" => true,
            "turbation_switch_requested" => true,
        ),
    )
    all(gates) ||
        throw(ArgumentError("inactive Stage-B evidence gate failed for $site"))
    valid_sha256(expected_initial_condition_sha256) &&
    valid_sha256(expected_job_options_sha256) ||
        throw(ArgumentError("trusted inactive hashes are invalid"))
    any(
        name -> startswith(name, "replay") && endswith(name, ".toml"),
        readdir(dirname(path)),
    ) && throw(ArgumentError("inactive package contains replay evidence"))
    guards = get(evidence, "source_guard", Any[])
    guard_contract(guards) == CANONICAL_GUARD_CONTRACT ||
        throw(ArgumentError("inactive evidence source-guard contract differs"))
    contract = expected_guard_contract()
    labels = getindex.(guards, "label")
    Set(labels) == Set(keys(contract)) &&
    length(unique(labels)) == length(labels) ||
        throw(ArgumentError("inactive source-guard labels differ"))
    path_hashes = Dict{String, String}()
    for guard in guards
        expected_path, expected_fragments = contract[guard["label"]]
        get(guard, "path", nothing) == expected_path ||
            throw(ArgumentError("inactive source-guard path differs"))
        get(guard, "required_fragment", nothing) == expected_fragments ||
            throw(ArgumentError("inactive source-guard fragments differ"))
        valid_sha256(get(guard, "file_sha256", nothing)) &&
        valid_sha256(get(guard, "excerpt_sha256", nothing)) ||
            throw(ArgumentError("inactive source-guard hash is invalid"))
        first_line = get(guard, "first_line", nothing)
        last_line = get(guard, "last_line", nothing)
        first_line isa Integer &&
        last_line isa Integer &&
        1 <= first_line <= last_line ||
            throw(ArgumentError("inactive source-guard range is invalid"))
        if haskey(path_hashes, guard["path"])
            path_hashes[guard["path"]] == guard["file_sha256"] ||
                throw(ArgumentError("inactive source file hashes differ"))
        else
            path_hashes[guard["path"]] = guard["file_sha256"]
        end
    end
    return true
end

end
