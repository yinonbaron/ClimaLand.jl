module CompleteStageBEvidence

import SHA
import TOML

using ..StageBSnapshots
using ..StageBTimeIndexReceipt
using ..StageBExecutionReceipt

export canonical_fields, promote_complete_receipt, verify_complete_evidence

const SOURCE_COMMIT = "7dd82c9a48a7c8beb6455a229888c90ba20d8eff"
const SOURCE_SHA256 = "6ef1fa32466d7e73e3b59b4686d14bda52bc3af30b6f92bdc022f45677d66feb"
const JOB_SHA256 = "f775e4085d7393a9f6b2ad04e99cdeae0999a51f07e9cb4a4575cf381aa96a06"
const PARAMETER_SHA256 = "9f3ff5bdbf8e10e5825f4a07e57028cdd376690f7c7bcf765734ea1ab47e16ce"
const INITIALIZATION_SHA256 = "2f466cf7b02c17590c86e04490c72493e33789eb5b9c18e2a1a189a5c36c6291"
const EXACT_CRITERIA = "exact values, coordinates, masks, dimensions, types, and units"
const MEASURED_PRE_RESP_CAPTURE = "measured_at_process_calls"
const LEGACY_LITERAL_ZERO_PATCH_SHA256 = "0ffb2a475b6e5be6225e2074488b60fb05a8556f55d54d5068a54b99edff3cac"
const PRE_RESP_PROCESS_SWITCHES =
    ("PFTCompetition", "lnduseon", "timberHarvest")

sha256sum(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

function canonical_fields()
    fields = Dict{String, NamedTuple}()
    add(names, dtype, shape, phase, role, units) = foreach(
        name -> fields[name] = (; dtype, shape, phase, role, units),
        names,
    )
    stock = (
        "pre.litrmass",
        "pre.soilcmas",
        "post.litrmass",
        "post.soilcmas",
        "intermediate.after_pool_update_litrmass",
        "intermediate.after_pool_update_soilcmas",
        "intermediate.before_turbation_litrmass",
        "intermediate.before_turbation_soilcmas",
    )
    add(
        stock[1:2],
        "float64",
        (1, 13, 20),
        "pre_state",
        "owned_state",
        "kg C m-2",
    )
    add(
        stock[3:4],
        "float64",
        (1, 13, 20),
        "post_state",
        "reference_state",
        "kg C m-2",
    )
    add(
        stock[5:8],
        "float64",
        (1, 13, 20),
        "intermediate_state",
        "reference_state",
        "kg C m-2",
    )
    pre_processes = ("competition", "land_use", "harvest")
    post_processes = ("turnover", "mortality", "disturbance")
    transfer_names = [
        "forcing.pre_resp_$(process)_delta_$(pool)" for
        process in pre_processes for pool in ("litter", "soil")
    ]
    append!(
        transfer_names,
        [
            "forcing.post_resp_$(process)_delta_$(pool)" for
            process in post_processes for pool in ("litter", "soil")
        ],
    )
    add(
        transfer_names,
        "float64",
        (1, 13, 20),
        "forcing",
        "external_forcing",
        "kg C m-2 step-1",
    )
    add(
        ("forcing.tbar",),
        "float64",
        (1, 20),
        "forcing",
        "external_forcing",
        "K",
    )
    add(
        ("forcing.thliq", "forcing.thice"),
        "float64",
        (1, 20),
        "forcing",
        "external_forcing",
        "m3 m-3",
    )
    add(
        ("forcing.fcancmx",),
        "float64",
        (1, 12),
        "forcing",
        "external_forcing",
        "1",
    )
    add(("forcing.fg",), "float64", (1,), "forcing", "external_forcing", "1")
    add(
        ("forcing.max_annual_active_layer",),
        "float64",
        (1,),
        "forcing",
        "external_forcing",
        "m",
    )
    add(
        ("forcing.rmr",),
        "float64",
        (1,),
        "forcing",
        "external_forcing",
        "umol CO2 m-2 s-1",
    )
    add(
        ("forcing.rmrveg",),
        "float64",
        (1, 12),
        "forcing",
        "external_forcing",
        "umol CO2 m-2 s-1",
    )
    add(
        ("audit.ltresveg", "audit.scresveg", "audit.humtrsvg"),
        "float64",
        (1, 13, 20),
        "audit",
        "audit_diagnostic",
        "umol CO2 m-2 s-1",
    )
    add(
        ("audit.hetrsveg",),
        "float64",
        (1, 13),
        "audit",
        "audit_diagnostic",
        "umol CO2 m-2 s-1",
    )
    add(
        ("audit.litres", "audit.socres", "audit.hetrores", "audit.humiftrs"),
        "float64",
        (1,),
        "audit",
        "audit_diagnostic",
        "umol CO2 m-2 s-1",
    )
    add(
        ("audit.soilresp",),
        "float64",
        (1,),
        "audit",
        "audit_diagnostic",
        "kg C m-2 step-1",
    )
    add(
        ("audit.turbation_delta_litter", "audit.turbation_delta_soil"),
        "float64",
        (1, 13, 20),
        "audit",
        "audit_diagnostic",
        "kg C m-2 step-1",
    )
    add(
        ("static.thpor", "static.bi"),
        "float64",
        (1, 20),
        "forcing",
        "parameter",
        "1",
    )
    fields["static.thpor"] = (;
        dtype = "float64",
        shape = (1, 20),
        phase = "forcing",
        role = "parameter",
        units = "m3 m-3",
    )
    add(("static.zbot",), "float64", (20,), "forcing", "parameter", "m")
    add(
        ("static.psisat", "static.zbotw", "static.delzw"),
        "float64",
        (1, 20),
        "forcing",
        "parameter",
        "m",
    )
    add(("static.isand",), "int32", (1, 20), "forcing", "parameter", "1")
    add(("static.sort",), "int32", (12,), "forcing", "parameter", "1")
    add(
        ("static.spinfast", "static.mineral_mask", "static.turbation_on"),
        "int32",
        (1,),
        "forcing",
        "parameter",
        "1",
    )
    add(
        ("static.bsratelt", "static.bsratesc"),
        "float64",
        (15,),
        "forcing",
        "parameter",
        "kg C kgC-1 yr-1",
    )
    add(("static.humicfac",), "float64", (15,), "forcing", "parameter", "1")
    add(("static.tanhq10",), "float64", (4,), "forcing", "parameter", "1")
    add(
        ("static.biodiffus", "static.cryodiffus"),
        "float64",
        (1,),
        "forcing",
        "parameter",
        "m2 d-1",
    )
    add(
        ("static.bsratelt_g", "static.bsratesc_g"),
        "float64",
        (1,),
        "forcing",
        "parameter",
        "kg C kgC-1 yr-1",
    )
    add(("static.r_depthredu",), "float64", (1,), "forcing", "parameter", "m")
    add(("static.deltat",), "float64", (1,), "forcing", "parameter", "d")
    add(("static.tfrez",), "float64", (1,), "forcing", "parameter", "K")
    add(("static.tcrit",), "float64", (1,), "forcing", "parameter", "degC")
    add(
        (
            "static.frozered",
            "static.humicfac_bg",
            "static.kterm",
            "static.zero",
        ),
        "float64",
        (1,),
        "forcing",
        "parameter",
        "1",
    )
    return fields
end

function verify_snapshot_contract(directory, transition)
    report = StageBSnapshots.verify_snapshot(directory)
    issues = copy(report.issues)
    report.ok || return (; ok = false, issues, report)
    expected = canonical_fields()
    records = Dict(field["name"] => field for field in report.manifest["field"])
    Set(keys(records)) == Set(keys(expected)) || push!(
        issues,
        "snapshot field inventory is not the canonical 66-field inventory",
    )
    for (name, contract) in expected
        haskey(records, name) || continue
        record = records[name]
        record["dtype"] == contract.dtype ||
            push!(issues, "$name dtype differs")
        Tuple(record["shape"]) == contract.shape ||
            push!(issues, "$name shape differs")
        record["phase"] == contract.phase ||
            push!(issues, "$name phase differs")
        record["role"] == contract.role || push!(issues, "$name role differs")
        record["units"] == contract.units || push!(issues, "$name units differ")
    end
    metadata = report.manifest["snapshot"]
    metadata["transition"] == transition ||
        push!(issues, "transition label differs")
    metadata["deltat_days"] == 1 || push!(issues, "deltat_days is not one")
    metadata["source_commit"] == SOURCE_COMMIT ||
        push!(issues, "source commit differs")
    metadata["source_sha256"] == SOURCE_SHA256 ||
        push!(issues, "source SHA-256 differs")
    metadata["job_options_sha256"] == JOB_SHA256 ||
        push!(issues, "job-options SHA-256 differs")
    metadata["model_parameters_sha256"] == PARAMETER_SHA256 ||
        push!(issues, "parameter SHA-256 differs")
    metadata["initialization_sha256"] == INITIALIZATION_SHA256 ||
        push!(issues, "initialization SHA-256 differs")
    return (; ok = isempty(issues), issues, report)
end

function scalar(directory, name)
    return only(StageBSnapshots.read_field(directory, name))
end

function verify_complete_evidence(
    ordinary,
    frozen,
    comparison_path,
    generator_receipt_path,
    time_index_path,
    output_directory,
    execution_receipt_path;
    complete_receipt_path = nothing,
)
    ordinary_report = verify_snapshot_contract(ordinary, "ordinary")
    frozen_report = verify_snapshot_contract(frozen, "frozen_soil")
    issues = vcat(
        ["ordinary: $issue" for issue in ordinary_report.issues],
        ["frozen_soil: $issue" for issue in frozen_report.issues],
    )
    if ordinary_report.ok && frozen_report.ok
        om = ordinary_report.report.manifest["snapshot"]
        fm = frozen_report.report.manifest["snapshot"]
        om["time_end"] != fm["time_end"] ||
            push!(issues, "snapshot times are not distinct")
        om["patch_sha256"] == fm["patch_sha256"] ||
            push!(issues, "snapshot patch hashes differ")
        om["executable_sha256"] == fm["executable_sha256"] ||
            push!(issues, "snapshot executable hashes differ")
        tfrez = scalar(ordinary, "static.tfrez")
        tcrit = scalar(ordinary, "static.tcrit")
        ordinary_t = first(StageBSnapshots.read_field(ordinary, "forcing.tbar"))
        frozen_t = first(StageBSnapshots.read_field(frozen, "forcing.tbar"))
        frozen_ice = first(StageBSnapshots.read_field(frozen, "forcing.thice"))
        ordinary_t - tfrez > tcrit ||
            push!(issues, "ordinary snapshot activates frozen inhibition")
        frozen_t - tfrez <= tcrit || push!(
            issues,
            "difficult snapshot does not activate frozen inhibition",
        )
        frozen_ice > 0 ||
            push!(issues, "difficult snapshot has no frozen soil water")
        scalar(ordinary, "static.deltat") == 1.0 ||
            push!(issues, "compiled deltat differs")
        scalar(ordinary, "static.spinfast") == 1 ||
            push!(issues, "spinfast differs")
        scalar(ordinary, "static.turbation_on") == 1 ||
            push!(issues, "turbation is disabled")
        all(
            StageBSnapshots.read_field(ordinary, "static.mineral_mask") .== 1,
        ) || push!(issues, "ordinary snapshot is not mineral soil")
    end

    comparison = TOML.parsefile(comparison_path)
    comparison_ok =
        get(comparison, "result", nothing)=="pass" &&
        get(comparison, "criteria", nothing)==EXACT_CRITERIA &&
        get(comparison, "compared_files", nothing)==57 &&
        get(comparison, "failed_files", nothing)==0 &&
        get(comparison, "record_count_per_daily_file", nothing)==4749
    comparison_ok ||
        push!(issues, "pristine comparison receipt is not an exact pass")
    evidence_directory = dirname(comparison_path)
    for (key, filename) in (
        "comparison_log_sha256" => "pristine-comparison.log",
        "reference_output_manifest_sha256" => "pristine-output.sha256",
        "candidate_output_manifest_sha256" => "instrumented-output.sha256",
    )
        path = joinpath(evidence_directory, filename)
        isfile(path) && comparison[key] == sha256sum(path) ||
            push!(issues, "$filename hash differs")
    end
    generator = TOML.parsefile(generator_receipt_path)
    generator["status"] == "generated" ||
        push!(issues, "generator receipt status is not generated")
    capture_method = get(generator, "pre_resp_transfer_capture", nothing)
    patch_path =
        joinpath(dirname(generator_receipt_path), generator["patch_path"])
    generator["patch_sha256"] == sha256sum(patch_path) ||
        push!(issues, "generated patch hash differs")
    comparison["instrumentation_patch_sha256"] == generator["patch_sha256"] ||
        push!(issues, "comparison patch hash differs")
    if ordinary_report.ok
        metadata = ordinary_report.report.manifest["snapshot"]
        for (comparison_key, metadata_key) in (
            "instrumentation_patch_sha256" => "patch_sha256",
            "instrumented_executable_sha256" => "executable_sha256",
            "job_options_sha256" => "job_options_sha256",
            "model_parameters_sha256" => "model_parameters_sha256",
            "initialization_sha256" => "initialization_sha256",
        )
            comparison[comparison_key] == metadata[metadata_key] ||
                push!(issues, "$comparison_key differs across evidence")
        end
    end
    time_report = StageBTimeIndexReceipt.verify_time_index_receipt(
        time_index_path,
        ordinary,
        frozen,
        output_directory,
    )
    append!(issues, "time index: $issue" for issue in time_report.issues)
    execution_report =
        StageBExecutionReceipt.verify_execution_receipt(execution_receipt_path)
    append!(issues, "execution: $issue" for issue in execution_report.issues)
    if execution_report.ok
        if capture_method == MEASURED_PRE_RESP_CAPTURE
            nothing
        elseif generator["patch_sha256"] == LEGACY_LITERAL_ZERO_PATCH_SHA256
            for name in PRE_RESP_PROCESS_SWITCHES
                get(execution_report.process_switches, name, true) == false ||
                    push!(
                        issues,
                        "legacy literal-zero patch requires $name=false",
                    )
            end
        else
            push!(issues, "pre-respiration transfer capture method is unproven")
        end
        execution = TOML.parsefile(execution_receipt_path)
        execution["binary"]["sha256"] ==
        comparison["instrumented_executable_sha256"] ||
            push!(issues, "execution binary hash differs from comparison")
        execution["instrumentation_patch"]["sha256"] ==
        comparison["instrumentation_patch_sha256"] ||
            push!(issues, "execution patch hash differs from comparison")
    end
    if !isnothing(complete_receipt_path)
        complete = TOML.parsefile(complete_receipt_path)
        complete["status"] == "complete" ||
            push!(issues, "complete receipt is not complete")
        complete["comparison_sha256"] == sha256sum(comparison_path) ||
            push!(issues, "complete receipt comparison hash differs")
        complete["ordinary_manifest_sha256"] ==
        sha256sum(joinpath(ordinary, "manifest.toml")) ||
            push!(issues, "complete receipt ordinary hash differs")
        complete["frozen_manifest_sha256"] ==
        sha256sum(joinpath(frozen, "manifest.toml")) ||
            push!(issues, "complete receipt frozen hash differs")
        complete["time_index_receipt_sha256"] == sha256sum(time_index_path) ||
            push!(issues, "complete receipt time-index hash differs")
        complete["execution_receipt_sha256"] ==
        sha256sum(execution_receipt_path) ||
            push!(issues, "complete receipt execution hash differs")
        complete["canonical_schema_sha256"] ==
        sha256sum(joinpath(@__DIR__, "schema.toml")) ||
            push!(issues, "complete receipt schema hash differs")
    end
    return (; ok = isempty(issues), issues)
end

function promote_complete_receipt(
    destination,
    ordinary,
    frozen,
    comparison,
    generator,
    time_index,
    output_directory,
    execution_receipt,
)
    preflight = verify_complete_evidence(
        ordinary,
        frozen,
        comparison,
        generator,
        time_index,
        output_directory,
        execution_receipt,
    )
    preflight.ok || error(
        "cannot promote incomplete evidence: $(join(preflight.issues, "; "))",
    )
    receipt = Dict(
        "schema_version" => 1,
        "status" => "complete",
        "ordinary_manifest_sha256" =>
            sha256sum(joinpath(ordinary, "manifest.toml")),
        "frozen_manifest_sha256" =>
            sha256sum(joinpath(frozen, "manifest.toml")),
        "comparison_sha256" => sha256sum(comparison),
        "generator_receipt_sha256" => sha256sum(generator),
        "time_index_receipt_sha256" => sha256sum(time_index),
        "execution_receipt_sha256" => sha256sum(execution_receipt),
        "canonical_schema_sha256" =>
            sha256sum(joinpath(@__DIR__, "schema.toml")),
    )
    open(destination, "w") do io
        TOML.print(io, receipt; sorted = true)
    end
    final = verify_complete_evidence(
        ordinary,
        frozen,
        comparison,
        generator,
        time_index,
        output_directory,
        execution_receipt;
        complete_receipt_path = destination,
    )
    final.ok || error("promoted receipt failed verification")
    return receipt
end

end
