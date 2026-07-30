import SHA
import TOML

import NCDatasets

if !isdefined(@__MODULE__, :TestbedSelectedMIMICSCWorkflow)
    include(joinpath(@__DIR__, "selected_mimics_c_workflow.jl"))
end

module GenerateMIMICSCHistoricalCalibration

import SHA
import TOML

import NCDatasets

const Workflow =
    getfield(parentmodule(@__MODULE__), :TestbedSelectedMIMICSCWorkflow)
const Calibration =
    getfield(parentmodule(@__MODULE__), :TestbedMIMICSCCalibration)

sha256sum(path) =
    open(path) do io
        bytes2hex(SHA.sha256(io))
    end

function units(reducer, name)
    state = name in Workflow.ANNUAL_STATE_NAMES
    reducer == "annual_total" && return "kg C m^-2 year^-1"
    reducer == "daily" && !state && return "kg C m^-2 s^-1"
    return "kg C m^-2"
end

function eligible_values(values, cell_ids, eligible_ids)
    length(values) % length(cell_ids) == 0 ||
        error("MIMICS-C historical oracle values are not cell-aligned")
    positions = indexin(eligible_ids, cell_ids)
    any(isnothing, positions) &&
        error("MIMICS-C eligible cells are outside the oracle")
    count = length(values) ÷ length(cell_ids)
    return vec(reshape(values, length(cell_ids), count)[Int.(positions), :])
end

function scope_contract(reference, scope_manifest_path)
    scope = TOML.parsefile(scope_manifest_path)
    Int.(get(scope, "cell_ids", Int[])) == Int.(reference["cell_ids"]) ||
        error("MIMICS-C historical population differs from its Scope Manifest")
    sha256sum(scope_manifest_path) ==
        reference["provenance"]["scope_manifest_sha256"] ||
        error("MIMICS-C historical Scope Manifest hash differs from the oracle")
    gaps = [
        gap for
        gap in get(scope, "eligibility_gaps", Dict{String, Any}[]) if
        get(gap, "model", nothing) == "MIMICS-C"
    ]
    excluded = Workflow.validate_gaps(gaps, Int.(reference["cell_ids"]))
    eligible_ids =
        filter(id -> id ∉ excluded, Int.(reference["cell_ids"]))
    return (; gaps, eligible_ids)
end

function historical_values(
    output_path,
    oracle,
    cell_ids,
    eligible_ids;
    coordinates = Dict(),
)
    annual_observations = [
        merge((; cell_id, year), get(coordinates, cell_id, (;))) for
        year in Workflow.HISTORICAL_YEARS for cell_id in eligible_ids
    ]
    annual_actual = NCDatasets.NCDataset(output_path) do output
        Workflow.selected_casa.reduced_annual_values(
            output,
            oracle["annual"],
        )
    end
    annual = Dict(
        reducer => Dict(
            name => Calibration.calibration_record(
                annual_actual[reducer][name],
                eligible_values(expected, cell_ids, eligible_ids);
                units = units(reducer, name),
                observations = annual_observations,
            ) for (name, expected) in variables
        ) for (reducer, variables) in
        (
            reducer => oracle["annual"][reducer] for
            reducer in ("annual_mean", "end_of_year", "annual_total")
        )
    )
    sample_days = Int.(oracle["daily"]["sample_days"])
    daily_observations = [
        (;
            cell_id,
            sample_day,
            year = first(Workflow.HISTORICAL_YEARS) +
                   (sample_day - 1) ÷ 365,
            day_of_year = mod1(sample_day, 365),
            get(coordinates, cell_id, (;))...,
        ) for sample_day in sample_days for cell_id in eligible_ids
    ]
    daily_actual = NCDatasets.NCDataset(output_path) do output
        Dict(
            name => vec(
                Array(
                    output[replace(name, "." => "__")][:, sample_days],
                ),
            ) for name in Workflow.DAILY_NAMES
        )
    end
    daily = Dict(
        name => Calibration.calibration_record(
            daily_actual[name],
            eligible_values(expected, cell_ids, eligible_ids);
            units = units("daily", name),
            observations = daily_observations,
        ) for (name, expected) in oracle["daily"]["variable"]
    )
    return annual, daily
end

function write_calibration(
    output_path,
    report_path,
    oracle_path,
    path;
    scope_manifest_path = joinpath(
        @__DIR__,
        "validation",
        "scopes",
        "representative.toml",
    ),
)
    reference = TOML.parsefile(oracle_path)
    get(reference, "model", nothing) == "MIMICS-C" ||
        error("historical calibration oracle is not for MIMICS-C")
    cell_ids = Int.(get(reference, "cell_ids", Int[]))
    length(cell_ids) == 80 ||
        error("historical calibration requires the exact 80-cell oracle")
    oracle = reference["oracle"]
    contract = scope_contract(reference, scope_manifest_path)
    coordinates = Dict(
        Int(cell["cell_id"]) => (;
            latitude = cell["latitude"],
            longitude = cell["longitude"],
        ) for cell in get(reference, "cell", Dict{String, Any}[])
    )
    length(coordinates) == length(cell_ids) ||
        error("MIMICS-C historical oracle lacks cell coordinates")
    annual, daily = historical_values(
        output_path,
        oracle,
        cell_ids,
        contract.eligible_ids;
        coordinates,
    )
    report = TOML.parsefile(report_path)
    get(report["coverage"], "scope_cell_ids", Int[]) == cell_ids &&
        get(report["coverage"], "eligible_cell_ids", Int[]) ==
        contract.eligible_ids &&
        get(report["coverage"], "eligibility_gaps", Any[]) ==
        contract.gaps ||
        error("MIMICS-C Julia report differs from the immutable Scope Manifest")
    julia_budget =
        report["historical_comparison"]["budget"]["historical_residual_kg_c"]
    fortran_budget = eligible_values(
        oracle["budget"]["historical_residual_kg_c"],
        cell_ids,
        contract.eligible_ids,
    )
    budget = Calibration.calibration_record(
        julia_budget,
        fortran_budget;
        units = "kg C",
        observations = [
            merge((; cell_id), coordinates[cell_id]) for
            cell_id in contract.eligible_ids
        ],
        relative = false,
    )
    eligible_count = length(contract.eligible_ids)
    all(
        record["finite_pair_count"] == eligible_count * 114 for
        reducer in values(annual) for record in values(reducer)
    ) || error("historical annual calibration population is incomplete")
    all(
        record["finite_pair_count"] == eligible_count * 84 for
        record in values(daily)
    ) || error("historical daily calibration population is incomplete")
    budget["finite_pair_count"] == eligible_count ||
        error("historical budget calibration population is incomplete")
    repo_root = normpath(joinpath(@__DIR__, "..", ".."))
    document = Dict(
        "schema_version" => 1,
        "calibration_id" =>
            "mimics-c-current-julia-fresh-fortran-representative-history-v1",
        "model" => "MIMICS-C",
        "scope" => reference["scope"],
        "cell_ids" => cell_ids,
        "cell_count" => length(cell_ids),
        "eligible_cell_ids" => contract.eligible_ids,
        "eligible_cell_count" => eligible_count,
        "reviewed_exclusion" => contract.gaps,
        "method" => Dict(
            "error" => "e_i = abs(Julia_i - Fortran_i)",
            "reference_magnitude" => "x_i = abs(Fortran_i)",
            "raw_absolute" => "a(r) = max(0, max_i(e_i - r*x_i))",
            "selection" =>
                "choose the smallest r >= 0 minimizing a(r) + r*mean(x); use r = 0 for the zero-centered budget residual",
            "safety_margin" =>
                "multiply raw atol and rtol by 1.05, then add 64eps(Float64) times the maximum observed Julia/Fortran magnitude to atol",
            "nonfinite" =>
                "fail calibration; exclusions require a reviewed Scope Manifest Eligibility Gap",
        ),
        "source_provenance" => Dict(
            "git_revision_basis" =>
                readchomp(`git -C $repo_root rev-parse HEAD`),
            "julia_version" => string(VERSION),
            "generator" => Dict(
                "id" => relpath(@__FILE__, repo_root),
                "sha256" => sha256sum(@__FILE__),
            ),
            "calibration" => Dict(
                "id" => relpath(
                    joinpath(@__DIR__, "mimics_c_calibration.jl"),
                    repo_root,
                ),
                "sha256" => sha256sum(
                    joinpath(@__DIR__, "mimics_c_calibration.jl"),
                ),
            ),
            "scope_manifest" => Dict(
                "id" => relpath(scope_manifest_path, repo_root),
                "sha256" => sha256sum(scope_manifest_path),
            ),
            "current_julia_output" => Dict(
                "id" => "current_julia_representative_historical_output",
                "sha256" => sha256sum(output_path),
            ),
            "current_julia_report" => Dict(
                "id" => "current_julia_representative_report",
                "sha256" => sha256sum(report_path),
            ),
            "fresh_fortran_oracle" => Dict(
                "id" => "pinned_mimics_c_representative_oracle",
                "sha256" => sha256sum(oracle_path),
                "fortran_source_revision" =>
                    reference["provenance"]["fortran_source_revision"],
                "scope_manifest_sha256" =>
                    reference["provenance"]["scope_manifest_sha256"],
                "fresh_historical_source_sha256" => reference["provenance"][
                    "fresh_historical_source_sha256"
                ],
            ),
        ),
        "annual" => annual,
        "daily" => daily,
        "budget" => budget,
    )
    mkpath(dirname(abspath(path)))
    temporary = "$(abspath(path)).tmp"
    open(temporary, "w") do io
        TOML.print(io, document; sorted = true)
    end
    mv(temporary, abspath(path); force = true)
    return abspath(path)
end

function main(args = ARGS)
    length(args) == 4 || error(
        "usage: generate_mimics_c_historical_calibration.jl JULIA_OUTPUT_NC JULIA_REPORT_TOML FORTRAN_ORACLE_TOML OUTPUT_PATH",
    )
    return write_calibration(args...)
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    GenerateMIMICSCHistoricalCalibration.main()
end
