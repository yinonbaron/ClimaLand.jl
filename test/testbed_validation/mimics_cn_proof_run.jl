module TestbedMIMICSCNProofRun

import SHA
import TOML

const MODEL = "MIMICS-CN"
const STAGES = ("prespin", "spin", "spin_continuation", "historical")
const COMPARISON_CHECKS = (
    "fresh_fortran_boundaries",
    "historical",
    "carbon_budget",
    "nitrogen_budget",
)
const DEFAULT_SCOPE =
    joinpath(@__DIR__, "validation", "scopes", "representative.toml")

struct ProofError <: Exception
    message::String
end

Base.showerror(io::IO, error::ProofError) = print(io, error.message)

fail(message) = throw(ProofError(message))

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

valid_sha256(value) =
    value isa AbstractString && occursin(r"^[0-9a-f]{64}$", value)

function read_document(path, description)
    isfile(path) || fail("$description is missing at $path")
    try
        return TOML.parsefile(path)
    catch error
        fail("$description is unreadable: $(sprint(showerror, error))")
    end
end

function model_gaps(scope, cell_ids)
    gaps = filter(get(scope, "eligibility_gaps", Any[])) do gap
        get(gap, "model", nothing) == MODEL
    end
    seen = Set{Int}()
    for gap in gaps
        cell_id = get(gap, "cell_id", nothing)
        cell_id in cell_ids ||
            fail("MIMICS-CN Eligibility Gap is outside scope")
        get(gap, "reviewed", false) === true &&
            !isempty(strip(String(get(gap, "reason", "")))) ||
            fail("MIMICS-CN Eligibility Gap is not reviewed")
        all(
            key -> haskey(gap, key),
            (
                "first_nonfinite_stage",
                "first_nonfinite_date",
                "first_nonfinite_variable",
            ),
        ) || fail("MIMICS-CN Eligibility Gap lacks first-failure evidence")
        cell_id in seen && fail("MIMICS-CN Eligibility Gap is duplicated")
        push!(seen, cell_id)
    end
    return gaps, seen
end

function verify_coverage(coverage, scope, scope_cell_ids)
    gaps, gap_ids = model_gaps(scope, scope_cell_ids)
    eligible_ids = filter(id -> id ∉ gap_ids, scope_cell_ids)
    get(coverage, "scope_cells", nothing) == 80 &&
        get(coverage, "compared_cells", nothing) == length(eligible_ids) &&
        get(coverage, "eligibility_gaps", nothing) == gaps ||
        fail("comparison coverage or Eligibility Gap evidence is inconsistent")
    haskey(coverage, "eligible_cells") &&
        get(coverage, "eligible_cells", nothing) != length(eligible_ids) &&
        fail("comparison eligible-cell coverage is inconsistent")
    haskey(coverage, "scope_cell_ids") &&
        Int.(coverage["scope_cell_ids"]) != scope_cell_ids &&
        fail("comparison scope cell IDs are inconsistent")
    haskey(coverage, "eligible_cell_ids") &&
        Int.(coverage["eligible_cell_ids"]) != eligible_ids &&
        fail("comparison eligible cell IDs are inconsistent")
    return gaps, eligible_ids
end

function verify_scientific_report(report, scope, scope_cell_ids)
    get(report, "schema_version", nothing) == 1 ||
        fail("scientific report schema is incompatible")
    coverage = get(report, "coverage", Dict{String, Any}())
    verify_coverage(coverage, scope, scope_cell_ids)

    boundaries = get(report, "boundary_comparison", Dict{String, Any}())
    Set(String.(keys(boundaries))) == Set(STAGES) && all(
        get(boundary, "all_match", false) for boundary in values(boundaries)
    ) || fail("comparison stage boundaries did not all pass")
    get(get(report, "historical_comparison", Dict()), "all_match", false) ||
        fail("historical comparison did not pass")
    get(get(report, "carbon_budget", Dict()), "all_close", false) ||
        fail("carbon budget comparison did not pass")
    get(get(report, "nitrogen_budget", Dict()), "all_close", false) ||
        fail("nitrogen budget comparison did not pass")
    return coverage
end

function verify_hashed_input(record, description)
    record isa AbstractDict || fail("$description record is missing")
    path = get(record, "path", get(record, "manifest", nothing))
    path isa AbstractString && isfile(path) || fail("$description is missing")
    expected = get(record, "sha256", get(record, "manifest_sha256", nothing))
    expected == sha256sum(path) || fail("$description SHA-256 is inconsistent")
    return abspath(path)
end

function write_toml_atomic(path, document)
    ispath(path) && fail("local candidate output already exists at $path")
    mkpath(dirname(path))
    temporary, io = mktemp(dirname(path))
    try
        TOML.print(io, document; sorted = true)
        close(io)
        mv(temporary, path)
    catch
        isopen(io) && close(io)
        ispath(temporary) && rm(temporary)
        rethrow()
    end
    return path
end

"""
    write_local_candidate(validation_root, oracle, output;
                          scope_manifest_path=DEFAULT_SCOPE)

Verify one successful public-runner MIMICS-CN proof and write a nonpublishable
local candidate audit. No canonical provenance or artifact binding is created.
"""
function write_local_candidate(
    validation_root,
    oracle,
    output = joinpath(validation_root, "mimics_cn_local_candidate.toml");
    scope_manifest_path = DEFAULT_SCOPE,
)
    validation_root = abspath(validation_root)
    oracle = abspath(oracle)
    output = abspath(output)
    scope_manifest_path = abspath(scope_manifest_path)
    validation_report_path = joinpath(validation_root, "validation_report.toml")
    validation = read_document(validation_report_path, "validation report")
    scope = read_document(scope_manifest_path, "Scope Manifest")

    get(validation, "schema_version", nothing) == 1 &&
        get(validation, "reference_mode", nothing) == "pinned" &&
        get(validation, "outcome", nothing) == "passed" ||
        fail("validation report is not a successful pinned run")
    scope_cell_ids = Int.(get(scope, "cell_ids", Int[]))
    get(scope, "schema_version", nothing) == 1 &&
        get(scope, "name", nothing) == "representative" &&
        length(scope_cell_ids) == 80 &&
        length(unique(scope_cell_ids)) == 80 ||
        fail("Scope Manifest is not the immutable 80-cell Representative scope")
    run_scope = get(validation, "scope", Dict{String, Any}())
    get(run_scope, "name", nothing) == "representative" &&
        get(run_scope, "cell_count", nothing) == 80 &&
        Int.(get(run_scope, "cell_ids", Int[])) == scope_cell_ids &&
        get(run_scope, "manifest", nothing) == scope_manifest_path &&
        get(run_scope, "manifest_sha256", nothing) ==
        sha256sum(scope_manifest_path) ||
        fail("validation report Scope Manifest identity is inconsistent")

    raw_models = get(validation, "model", Any[])
    raw_models isa AbstractVector && length(raw_models) == 1 ||
        fail("validation report must contain exactly one model")
    model = only(raw_models)
    get(model, "name", nothing) == MODEL &&
        get(model, "reference_mode", nothing) == "pinned" &&
        get(model, "outcome", nothing) == "passed" ||
        fail("MIMICS-CN model report did not pass")
    gaps, eligible_ids = verify_coverage(
        get(model, "coverage", Dict{String, Any}()),
        scope,
        scope_cell_ids,
    )
    checks = get(model, "comparison", Dict{String, Any}())
    Set(String.(keys(checks))) == Set(COMPARISON_CHECKS) &&
        all(get(checks, name, false) for name in COMPARISON_CHECKS) ||
        fail("MIMICS-CN aggregate comparison checks did not all pass")

    isfile(oracle) || fail("reduced oracle is missing at $oracle")
    oracle_sha256 = sha256sum(oracle)
    reference = get(model, "reference", Dict{String, Any}())
    get(reference, "path", nothing) == oracle &&
        get(reference, "sha256", nothing) == oracle_sha256 ||
        fail("validation report oracle SHA-256 or path is inconsistent")
    oracle_document = read_document(oracle, "reduced oracle")
    get(oracle_document, "schema_version", nothing) == 1 &&
        get(oracle_document, "model", nothing) == MODEL &&
        get(oracle_document, "scope", nothing) == "representative" &&
        Int.(get(oracle_document, "cell_ids", Int[])) == scope_cell_ids &&
        Set(String.(keys(get(oracle_document, "oracle", Dict())))) ==
        Set(("boundary", "annual", "daily", "budget")) ||
        fail("reduced oracle contract is incompatible")
    provenance = get(oracle_document, "provenance", Dict{String, Any}())
    get(provenance, "scope_manifest_sha256", nothing) ==
    sha256sum(scope_manifest_path) ||
        fail("reduced oracle Scope Manifest SHA-256 is inconsistent")
    revision = get(provenance, "fortran_source_revision", nothing)
    revision isa AbstractString && occursin(r"^[0-9a-f]{40}$", revision) ||
        fail("reduced oracle source revision is invalid")
    all(
        key -> valid_sha256(get(provenance, key, nothing)),
        ("generator_sha256", "fortran_build_sha256"),
    ) || fail("reduced oracle provenance contains an invalid SHA-256")

    scientific_path = get(model, "comparison_report", nothing)
    scientific_path isa AbstractString &&
        abspath(scientific_path) ==
        joinpath(validation_root, MODEL, "reconstruction_report.toml") ||
        fail("MIMICS-CN scientific report path is inconsistent")
    scientific = read_document(scientific_path, "MIMICS-CN scientific report")
    scientific_coverage =
        verify_scientific_report(scientific, scope, scope_cell_ids)
    scientific_coverage["eligibility_gaps"] == gaps &&
        Int.(scientific_coverage["eligible_cell_ids"]) == eligible_ids ||
        fail("aggregate and scientific coverage differ")

    policy = get(model, "comparison_policy", Dict{String, Any}())
    boundary_calibration = verify_hashed_input(
        Dict(
            "path" => get(policy, "boundary_calibration", nothing),
            "sha256" => get(policy, "boundary_calibration_sha256", nothing),
        ),
        "boundary calibration",
    )
    historical_calibration = verify_hashed_input(
        Dict(
            "path" => get(policy, "historical_calibration", nothing),
            "sha256" =>
                get(policy, "historical_calibration_sha256", nothing),
        ),
        "historical calibration",
    )
    forcing_manifest =
        verify_hashed_input(get(model, "forcing", nothing), "forcing manifest")

    paths = Dict(
        "oracle" => oracle,
        "validation_report" => validation_report_path,
        "scientific_report" => abspath(scientific_path),
        "scope_manifest" => scope_manifest_path,
        "boundary_calibration" => boundary_calibration,
        "historical_calibration" => historical_calibration,
        "forcing_manifest" => forcing_manifest,
    )
    hashes = Dict(name => sha256sum(path) for (name, path) in paths)
    document = Dict(
        "schema_version" => 1,
        "operation" => "local_reference_candidate_audit",
        "model" => MODEL,
        "scope" => "representative",
        "outcome" => "passed",
        "canonical" => false,
        "publishable" => false,
        "files" => hashes,
        "path" => paths,
        "coverage" => Dict(
            "scope_cells" => 80,
            "eligible_cells" => length(eligible_ids),
            "compared_cells" => length(eligible_ids),
            "eligibility_gaps" => gaps,
        ),
        "provenance" => provenance,
    )
    write_toml_atomic(output, document)
    return (; path = output, oracle, hashes, coverage = document["coverage"])
end

function main(args = ARGS)
    2 <= length(args) <= 4 || fail(
        "usage: mimics_cn_proof_run.jl VALIDATION_ROOT ORACLE [OUTPUT [SCOPE_MANIFEST]]",
    )
    validation_root, oracle = args[1:2]
    output =
        length(args) >= 3 ? args[3] :
        joinpath(validation_root, "mimics_cn_local_candidate.toml")
    scope = length(args) == 4 ? args[4] : DEFAULT_SCOPE
    write_local_candidate(
        validation_root,
        oracle,
        output;
        scope_manifest_path = scope,
    )
    return 0
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(TestbedMIMICSCNProofRun.main())
end
