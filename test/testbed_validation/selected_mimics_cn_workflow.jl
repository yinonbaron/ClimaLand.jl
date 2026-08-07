if !isdefined(@__MODULE__, :TestbedSelectedCASAWorkflow)
    include(joinpath(@__DIR__, "selected_casa_workflow.jl"))
end
if !isdefined(@__MODULE__, :TestbedNativeMIMICSCNReconstruction)
    include(joinpath(@__DIR__, "native_mimics_cn_reconstruction.jl"))
end
if !isdefined(@__MODULE__, :TestbedMIMICSCNCalibration)
    include(joinpath(@__DIR__, "mimics_cn_calibration.jl"))
end

module TestbedSelectedMIMICSCNWorkflow

import ClimaLand
import NCDatasets
import TOML

const selected_casa =
    getfield(parentmodule(@__MODULE__), :TestbedSelectedCASAWorkflow)
const native_mimics =
    getfield(parentmodule(@__MODULE__), :TestbedNativeMIMICSCNReconstruction)
const calibration =
    getfield(parentmodule(@__MODULE__), :TestbedMIMICSCNCalibration)
const MIMICS_PARAMETERS =
    joinpath(@__DIR__, "fixtures", "selected_cells", "mimics_cn_parameters.csv")
const PRESPIN_PARAMETERS = joinpath(
    @__DIR__,
    "fixtures",
    "selected_cells",
    "mimics_cn_prespin_parameters.csv",
)

const STAGE_NAMES = ("prespin", "spin", "spin_continuation", "historical")
const HISTORICAL_YEARS = 1901:2014
const BOUNDARY_NAMES = Tuple(
    "$(component).$(variable)" for
    (_, _, component, variable) in native_mimics.BOUNDARY_VARIABLES
)
const ANNUAL_STATE_NAMES = Tuple(
    replace(native_name, "__" => ".") for
    (_, _, native_name, scale) in native_mimics.HISTORICAL_VARIABLES if
    scale == 1000.0
)
const ANNUAL_FLUX_NAMES = Tuple(
    replace(native_name, "__" => ".") for
    (_, _, native_name, scale) in native_mimics.HISTORICAL_VARIABLES if
    scale != 1000.0
)
const DAILY_NAMES = Tuple(
    replace(native_name, "__" => ".") for
    (_, _, native_name, _) in native_mimics.HISTORICAL_VARIABLES
)
const NITROGEN_NAMES = Tuple(
    replace(native_name, "__" => ".") for
    (fortran_name, _, native_name, _) in native_mimics.HISTORICAL_VARIABLES if
    startswith(fortran_name, "n") || fortran_name == "DIN"
)

function fixed_daily_sample_days()
    starts = (1, 91, 182, 274)
    return sort!([
        (year - first(HISTORICAL_YEARS)) * 365 + start + offset for
        year in (1901, 1957, 2014) for start in starts for offset in 0:6
    ],)
end

function validate_names(values, required, location)
    Set(String.(keys(values))) == Set(required) ||
        error("$location has incompatible variables")
    return nothing
end

function validate_values(
    values,
    required,
    value_count,
    cell_ids,
    eligible_positions,
    location,
)
    validate_names(values, required, location)
    expected_length = length(cell_ids) * value_count
    for name in required
        data = values[name]
        data isa AbstractVector && length(data) == expected_length ||
            error("$location.$name has incompatible dimensions")
        for position in eligible_positions
            for index in position:length(cell_ids):length(data)
                value = data[index]
                value isa Real && isfinite(value) || error(
                    "MIMICS-CN oracle has an eligible nonfinite value for cell $(cell_ids[position]) at $location.$name",
                )
            end
        end
    end
    return nothing
end

function validate_tolerance(values, required, location)
    validate_names(values, required, location)
    for name in required
        tolerance = values[name]
        Set(String.(keys(tolerance))) == Set(("atol", "rtol")) ||
            error("$location.$name has an incompatible tolerance")
        all(
            value -> value isa Real && isfinite(value) && value >= 0,
            Base.values(tolerance),
        ) || error("$location.$name has an invalid tolerance")
    end
    return nothing
end

function validate_policy(policy)
    Set(String.(keys(policy))) == Set((
        "fresh_fortran_boundary",
        "fresh_fortran_annual",
        "fresh_fortran_daily",
        "fresh_fortran_budget",
    )) || error("MIMICS-CN Comparison Policy has incompatible rules")
    boundaries = policy["fresh_fortran_boundary"]
    Set(String.(keys(boundaries))) == Set(STAGE_NAMES) ||
        error("MIMICS-CN boundary policy has incompatible stages")
    for stage in STAGE_NAMES
        validate_tolerance(
            boundaries[stage],
            BOUNDARY_NAMES,
            "fresh_fortran_boundary.$stage",
        )
    end
    annual = policy["fresh_fortran_annual"]
    Set(String.(keys(annual))) ==
    Set(("annual_mean", "end_of_year", "annual_total")) ||
        error("MIMICS-CN annual policy has incompatible reducers")
    validate_tolerance(
        annual["annual_mean"],
        ANNUAL_STATE_NAMES,
        "fresh_fortran_annual.annual_mean",
    )
    validate_tolerance(
        annual["end_of_year"],
        ANNUAL_STATE_NAMES,
        "fresh_fortran_annual.end_of_year",
    )
    validate_tolerance(
        annual["annual_total"],
        ANNUAL_FLUX_NAMES,
        "fresh_fortran_annual.annual_total",
    )
    validate_tolerance(
        policy["fresh_fortran_daily"],
        DAILY_NAMES,
        "fresh_fortran_daily",
    )
    validate_tolerance(
        policy["fresh_fortran_budget"],
        ("historical_residual_kg_c", "historical_residual_kg_n"),
        "fresh_fortran_budget",
    )
    return nothing
end

function validate_gaps(gaps, cell_ids)
    seen = Set{Int}()
    for gap in gaps
        get(gap, "model", nothing) == "MIMICS-CN" ||
            error("MIMICS-CN Eligibility Gap has the wrong model")
        cell_id = get(gap, "cell_id", nothing)
        cell_id in cell_ids ||
            error("MIMICS-CN Eligibility Gap is outside the supplied collection")
        get(gap, "reviewed", false) === true &&
            !isempty(strip(String(get(gap, "reason", "")))) ||
            error("MIMICS-CN Eligibility Gap is not reviewed")
        haskey(gap, "first_nonfinite_stage") &&
            haskey(gap, "first_nonfinite_date") &&
            haskey(gap, "first_nonfinite_variable") ||
            error("MIMICS-CN Eligibility Gap lacks nonfinite evidence")
        cell_id in seen && error("MIMICS-CN Eligibility Gap is duplicated")
        push!(seen, cell_id)
    end
    return seen
end

function validate_provenance(provenance)
    revision = get(provenance, "fortran_source_revision", "")
    length(revision) == 40 && all(isxdigit, revision) ||
        error("MIMICS-CN oracle Fortran source revision is invalid")
    for name in ("generator_sha256", "scope_manifest_sha256")
        digest = get(provenance, name, "")
        length(digest) == 64 && all(isxdigit, digest) ||
            error("MIMICS-CN oracle $name is invalid")
    end
    return nothing
end

"""
    workflow_reference(collection; path, comparison_policy, eligibility_gaps)

Load and validate one reduced MIMICS-CN Comparison Oracle against the exact
supplied cell collection. Reviewed gaps remove a cell atomically; all values
for every other cell must be finite.
"""
function workflow_reference(
    collection;
    path,
    comparison_policy,
    eligibility_gaps = Dict{String, Any}[],
)
    isfile(path) || error("Pinned MIMICS-CN oracle is missing: $path")
    reference = TOML.parsefile(path)
    get(reference, "schema_version", nothing) == 1 ||
        error("Unsupported MIMICS-CN oracle schema")
    get(reference, "model", nothing) == "MIMICS-CN" ||
        error("Pinned oracle is not for MIMICS-CN")
    get(reference, "scope", nothing) == collection.name ||
        error("Pinned MIMICS-CN oracle scope does not match the collection")
    cell_ids = Int.(get(reference, "cell_ids", Int[]))
    supplied_ids = Int.(getproperty.(collection.cells, :id))
    cell_ids == supplied_ids ||
        error("Pinned MIMICS-CN oracle cell IDs do not exactly match the supplied collection")
    gap_ids = validate_gaps(eligibility_gaps, cell_ids)
    eligible_ids = filter(id -> id ∉ gap_ids, cell_ids)
    positions = findall(id -> id ∉ gap_ids, cell_ids)
    validate_provenance(get(reference, "provenance", Dict{String, Any}()))
    validate_policy(comparison_policy)

    oracle = get(reference, "oracle", Dict{String, Any}())
    Set(String.(keys(oracle))) ==
    Set(("boundary", "annual", "daily", "budget")) ||
        error("Pinned MIMICS-CN oracle has incompatible sections")
    boundaries = oracle["boundary"]
    Set(String.(keys(boundaries))) == Set(STAGE_NAMES) ||
        error("Pinned MIMICS-CN oracle has incompatible boundary stages")
    for stage in STAGE_NAMES
        validate_values(
            boundaries[stage],
            BOUNDARY_NAMES,
            1,
            cell_ids,
            positions,
            "boundary.$stage",
        )
    end
    annual = oracle["annual"]
    Int.(get(annual, "years", Int[])) == collect(HISTORICAL_YEARS) ||
        error("Pinned MIMICS-CN oracle has incompatible annual years")
    year_count = length(HISTORICAL_YEARS)
    validate_values(
        annual["annual_mean"],
        ANNUAL_STATE_NAMES,
        year_count,
        cell_ids,
        positions,
        "annual.annual_mean",
    )
    validate_values(
        annual["end_of_year"],
        ANNUAL_STATE_NAMES,
        year_count,
        cell_ids,
        positions,
        "annual.end_of_year",
    )
    validate_values(
        annual["annual_total"],
        ANNUAL_FLUX_NAMES,
        year_count,
        cell_ids,
        positions,
        "annual.annual_total",
    )
    daily = oracle["daily"]
    Int.(get(daily, "sample_days", Int[])) == fixed_daily_sample_days() ||
        error("Pinned MIMICS-CN oracle must retain the fixed 84 daily samples")
    validate_values(
        daily["variable"],
        DAILY_NAMES,
        length(fixed_daily_sample_days()),
        cell_ids,
        positions,
        "daily.variable",
    )
    budget = oracle["budget"]
    get(budget, "units", nothing) ==
    Dict("carbon" => "kg C", "nitrogen" => "kg N") &&
        get(budget, "reducer", nothing) ==
        "maximum_absolute_residual" || error(
        "Pinned MIMICS-CN oracle has an incompatible budget reducer",
    )
    carbon_residual =
        get(budget, "maximum_absolute_residual_kg_c", nothing)
    nitrogen_residual =
        get(budget, "maximum_absolute_residual_kg_n", nothing)
    all(
        value -> value isa Real && isfinite(value) && value >= 0,
        (carbon_residual, nitrogen_residual),
    ) || error("Pinned MIMICS-CN oracle has an invalid budget residual")
    validate_values(
        Dict(
            "historical_residual_kg_c" =>
                budget["historical_residual_kg_c"],
            "historical_residual_kg_n" =>
                budget["historical_residual_kg_n"],
        ),
        ("historical_residual_kg_c", "historical_residual_kg_n"),
        1,
        cell_ids,
        positions,
        "budget",
    )
    carbon_residual ==
    maximum(abs, budget["historical_residual_kg_c"][positions]) &&
        nitrogen_residual ==
        maximum(abs, budget["historical_residual_kg_n"][positions]) ||
        error("Pinned MIMICS-CN oracle budget reducers are inconsistent")
    by_id = Dict(id => index for (index, id) in enumerate(cell_ids))
    return (;
        reference,
        oracle,
        cell_ids,
        eligible_ids,
        eligibility_gaps,
        indices = (; by_id),
        comparison_policy,
        provenance = reference["provenance"],
        path = abspath(path),
    )
end

function compare_payload(
    actual,
    expected,
    tolerance,
    collection,
    reference_indices,
    concurrency_budget = getfield(
        parentmodule(@__MODULE__),
        :TestbedReferenceCellComparisons,
    ).ConcurrencyBudget(1),
)
    indices =
        reference_indices isa AbstractDict ? (; by_id = reference_indices) :
        reference_indices
    return selected_casa.compare_snapshot(
        actual,
        expected,
        tolerance,
        collection,
        indices,
        concurrency_budget,
    )
end

mutable struct PackedMIMICSForcing{B, F, T}
    base::B
    buffers::F
    porosity::Vector{Float64}
    frozen_saturation::Matrix{Float64}
    forced_annual_npp::Matrix{Float64}
    annual_npp_tracker::T
end

function PackedMIMICSForcing(
    dataset,
    cell_indices,
    grid,
    soils,
    parameters,
    phenology_path,
    buffers,
    domain,
    nitrogen_deposition,
)
    base = selected_casa.PackedForcing(
        dataset,
        cell_indices,
        grid,
        soils,
        parameters,
        phenology_path,
        buffers,
        nitrogen_deposition,
    )
    points = length(grid)
    days = length(HISTORICAL_YEARS) * 365
    roots = reduce(
        vcat,
        permutedims(
            collect(
                native_mimics.native_casa().root_fractions(
                    parameters[point.pft],
                ),
            ),
        ) for point in grid
    )
    frozen_raw = Float64.(dataset["xfrznmoist"][:, :, cell_indices])
    frozen = zeros(points, days)
    porosity = [soils[point.cell_id].porosity for point in grid]
    for point in eachindex(grid)
        base.active[point] || continue
        for day in 1:days
            frozen[point, day] = min(
                1.0,
                sum(
                    roots[point, layer] * frozen_raw[layer, day, point] for
                    layer in axes(roots, 2)
                ) / porosity[point],
            )
        end
    end
    raw_gpp = permutedims(Float64.(dataset["xcgpp"][:, cell_indices]))
    annual_npp = zeros(points, length(HISTORICAL_YEARS))
    for (year_index, _) in enumerate(HISTORICAL_YEARS)
        year_days = ((year_index - 1) * 365 + 1):(year_index * 365)
        for point in eachindex(grid)
            base.active[point] || continue
            annual_npp[point, year_index] =
                sum(view(raw_gpp, point, year_days)) / 2 / 1000
        end
    end
    tracker = native_mimics.native_mimics().AnnualNPPTracker(domain)
    return PackedMIMICSForcing(
        base,
        buffers,
        porosity,
        frozen,
        annual_npp,
        tracker,
    )
end

function update_forcing!(forcing::PackedMIMICSForcing, stage, index, time)
    selected_casa.update_forcing!(forcing.base, stage, index, time)
    year, day = native_mimics.native_casa().forcing_year_day(stage, index)
    source_index = (year - first(HISTORICAL_YEARS)) * 365 + day
    liquid = vec(parent(forcing.buffers.liquid_water))
    liquid_saturation = vec(parent(forcing.buffers.liquid_saturation))
    frozen_saturation = vec(parent(forcing.buffers.frozen_saturation))
    for point in eachindex(liquid)
        if forcing.base.active[point]
            liquid_saturation[point] =
                min(1.0, liquid[point] / forcing.porosity[point])
            frozen_saturation[point] =
                forcing.frozen_saturation[point, source_index]
        else
            liquid_saturation[point] = 0.0
            frozen_saturation[point] = 0.0
        end
    end
    day == 1 || return nothing
    tracker = forcing.annual_npp_tracker
    annual_npp = vec(parent(forcing.buffers.annual_npp))
    forced = view(
        forcing.forced_annual_npp,
        :,
        year - first(HISTORICAL_YEARS) + 1,
    )
    if tracker.active_stage != stage.name
        tracker.active_stage = stage.name
        annual_npp .= forced
    else
        annual_npp .= vec(parent(tracker.accumulated))
        native_mimics.native_mimics().apply_annual_npp_sentinel!(
            annual_npp,
            forced,
        )
    end
    tracker.accumulated .= 0.0
    return nothing
end

function load_setup(; collection)
    cells = getfield(
        parentmodule(@__MODULE__),
        :TestbedReferenceCellComparisons,
    )
    return cells.with_fixture(collection) do fixture
        grid = selected_casa.selected_grid(
            fixture.files["grid"],
            fixture.cell_ids,
        )
        soils = native_mimics.native_casa().read_soils(fixture.files["soil"])
        domain = native_mimics.native_casa().gridded_domain(length(grid))
        buffers = native_mimics.native_mimics().MIMICSBuffers(domain)
        nitrogen_deposition =
            native_mimics.native_casa().scalar_field(
                domain,
                zeros(length(grid)),
            )
        prespin = native_mimics.build_gridded_model(
            grid,
            soils,
            PRESPIN_PARAMETERS,
            MIMICS_PARAMETERS,
            buffers,
            nitrogen_deposition,
            ;
            domain,
            boreal_fixation = true,
        )
        normal = native_mimics.build_gridded_model(
            grid,
            soils,
            fixture.files["casa_c_parameters"],
            MIMICS_PARAMETERS,
            buffers,
            nitrogen_deposition;
            domain,
        )
        forcing = PackedMIMICSForcing(
            fixture.forcing,
            fixture.cell_indices,
            grid,
            soils,
            normal.parameters,
            fixture.files["phenology"],
            buffers,
            domain,
            nitrogen_deposition,
        )
        return (;
            collection,
            cell_ids = fixture.cell_ids,
            grid,
            soils,
            domain,
            buffers,
            prespin,
            normal,
            forcing,
            initial_state = native_mimics.gridded_initial_state(
                prespin.model,
                grid,
                PRESPIN_PARAMETERS,
                prespin.nitrogen,
            ),
            files = merge(
                fixture.files,
                Dict(
                    "mimics_cn_parameters" => MIMICS_PARAMETERS,
                    "mimics_cn_prespin_parameters" => PRESPIN_PARAMETERS,
                ),
            ),
        )
    end
end

state_snapshot(Y) = native_mimics.native_casa().state_snapshot(Y)

function compare_boundary_reference(
    reference,
    stage,
    Y,
    collection,
    concurrency_budget,
)
    return compare_payload(
        state_snapshot(Y),
        reference.oracle["boundary"][String(stage.name)],
        reference.comparison_policy["fresh_fortran_boundary"][String(
            stage.name,
        )],
        collection,
        reference.indices,
        concurrency_budget,
    )
end

function compare_historical_reference(
    reference,
    path,
    actual_budget,
    collection,
    concurrency_budget,
)
    daily = reference.oracle["daily"]
    daily_actual = NCDatasets.NCDataset(path) do output
        Dict(
            name => vec(
                Array(
                    output[replace(name, "." => "__")][
                        :,
                        daily["sample_days"],
                    ],
                ),
            ) for name in DAILY_NAMES
        )
    end
    daily_report = compare_payload(
        daily_actual,
        daily["variable"],
        reference.comparison_policy["fresh_fortran_daily"],
        collection,
        reference.indices,
        concurrency_budget,
    )
    annual_reports = Dict{String, Any}()
    NCDatasets.NCDataset(path) do output
        actual = selected_casa.reduced_annual_values(
            output,
            reference.oracle["annual"],
        )
        for reducer in ("annual_mean", "end_of_year", "annual_total")
            annual_reports[reducer] = compare_payload(
                actual[reducer],
                reference.oracle["annual"][reducer],
                reference.comparison_policy["fresh_fortran_annual"][reducer],
                collection,
                reference.indices,
                concurrency_budget,
            )
        end
    end
    annual = Dict(
        "reducer" => annual_reports,
        "all_match" =>
            all(report["all_match"] for report in values(annual_reports)),
    )
    budget = compare_budget_reference(
        reference,
        actual_budget,
        collection,
        concurrency_budget,
    )
    return Dict(
        "output" => Dict(
            "records" => NCDatasets.NCDataset(path) do output
                size(output["time"], 1)
            end,
        ),
        "reference" => reference.path,
        "provenance" => reference.provenance,
        "fixed_daily_samples" => daily_report,
        "annual" => annual,
        "budget" => budget,
        "all_match" =>
            daily_report["all_match"] &&
            annual["all_match"] &&
            budget["all_match"],
    )
end

function historical_budget_values(boundaries, path, grid)
    cell_count = length(grid)
    carbon_start = zeros(cell_count)
    carbon_stop = zeros(cell_count)
    nitrogen_start = zeros(cell_count)
    nitrogen_stop = zeros(cell_count)
    for name in BOUNDARY_NAMES
        destination_start, destination_stop =
            occursin(".n_", name) ?
            (nitrogen_start, nitrogen_stop) :
            (carbon_start, carbon_stop)
        destination_start .+= boundaries["spin_continuation"][name]
        destination_stop .+= boundaries["historical"][name]
    end
    npp, respiration, n_input, n_output = NCDatasets.NCDataset(path) do output
        (
            vec(
                sum(output["diagnostic__cnpp"][:, :]; dims = 2),
            ) .* native_mimics.DAY_SECONDS,
            vec(
                sum(
                    output["diagnostic__mimics_respiration"][:, :];
                    dims = 2,
                ),
            ) .* native_mimics.DAY_SECONDS,
            vec(
                sum(
                    output["diagnostic__n_deposition"][:, :] .+
                    output["diagnostic__n_fixation"][:, :];
                    dims = 2,
                ),
            ) .* native_mimics.DAY_SECONDS,
            vec(
                sum(
                    output["diagnostic__n_leaching"][:, :] .+
                    output["diagnostic__n_gaseous_loss"][:, :];
                    dims = 2,
                ),
            ) .* native_mimics.DAY_SECONDS,
        )
    end
    carbon_residual =
        getproperty.(grid, :area_m2) .*
        (carbon_stop .- carbon_start .- (npp .- respiration))
    nitrogen_residual =
        getproperty.(grid, :area_m2) .*
        (nitrogen_stop .- nitrogen_start .- (n_input .- n_output))
    all(isfinite, carbon_residual) && all(isfinite, nitrogen_residual) ||
        error("eligible Julia MIMICS-CN budget contains a nonfinite value")
    return Dict(
        "units" => Dict("carbon" => "kg C", "nitrogen" => "kg N"),
        "reducer" => "maximum_absolute_residual",
        "maximum_absolute_residual_kg_c" => maximum(abs, carbon_residual),
        "historical_residual_kg_c" => carbon_residual,
        "maximum_absolute_residual_kg_n" => maximum(abs, nitrogen_residual),
        "historical_residual_kg_n" => nitrogen_residual,
    )
end

function compare_budget_reference(
    reference,
    actual,
    collection,
    concurrency_budget,
)
    expected = reference.oracle["budget"]
    comparison = compare_payload(
        Dict(
            "historical_residual_kg_c" =>
                actual["historical_residual_kg_c"],
            "historical_residual_kg_n" =>
                actual["historical_residual_kg_n"],
        ),
        Dict(
            "historical_residual_kg_c" =>
                expected["historical_residual_kg_c"],
            "historical_residual_kg_n" =>
                expected["historical_residual_kg_n"],
        ),
        reference.comparison_policy["fresh_fortran_budget"],
        collection,
        reference.indices,
        concurrency_budget,
    )
    comparison["units"] = Dict("carbon" => "kg C", "nitrogen" => "kg N")
    comparison["reducer"] = "maximum_absolute_residual"
    comparison["julia_maximum_absolute_residual_kg_c"] =
        actual["maximum_absolute_residual_kg_c"]
    comparison["fortran_maximum_absolute_residual_kg_c"] =
        expected["maximum_absolute_residual_kg_c"]
    comparison["julia_maximum_absolute_residual_kg_n"] =
        actual["maximum_absolute_residual_kg_n"]
    comparison["fortran_maximum_absolute_residual_kg_n"] =
        expected["maximum_absolute_residual_kg_n"]
    return comparison
end

function stage_provenance(setup, stage)
    casa_path =
        stage.name == :prespin ? PRESPIN_PARAMETERS :
        setup.files["casa_c_parameters"]
    return Dict(
        "model" => "ClimaLand integrated CASA plant and MIMICS carbon-nitrogen soil",
        "configuration" => "selected-cell $(setup.collection.name) collection",
        "pft" => "exact supplied Scope Manifest cell IDs",
        "parameter_file" => Dict(
            "source" => abspath(MIMICS_PARAMETERS),
            "sha256" => native_mimics.native_workflow().sha256sum(
                MIMICS_PARAMETERS,
            ),
            "mimics_source" => abspath(MIMICS_PARAMETERS),
            "mimics_sha256" => native_mimics.native_workflow().sha256sum(
                MIMICS_PARAMETERS,
            ),
            "casa_source" => abspath(casa_path),
            "casa_sha256" => native_mimics.native_workflow().sha256sum(
                casa_path,
            ),
        ),
        "forcing" => [
            Dict(
                "stage" => String(stage.name),
                "source" => abspath(setup.files["forcing"]),
                "sha256" => native_mimics.native_workflow().sha256sum(
                    setup.files["forcing"],
                ),
            ),
        ],
    )
end

function annotate_report!(
    path,
    scope_collection,
    active_collection,
    eligibility_gaps,
)
    report = TOML.parsefile(path)
    for (name, units, suffix) in (
        ("carbon_budget", "kg C", "kg_c"),
        ("nitrogen_budget", "kg N", "kg_n"),
    )
        budget = report[name]
        stage_budgets = collect(values(budget["stage"]))
        budget["units"] = units
        budget["reducer"] = "maximum_absolute_residual"
        budget["maximum_absolute_residual_$suffix"] = maximum(
            abs(values["residual_$suffix"]) for values in stage_budgets
        )
    end
    report["coverage"] = Dict(
        "scope_cell_ids" => getproperty.(scope_collection.cells, :id),
        "eligible_cell_ids" => getproperty.(active_collection.cells, :id),
        "scope_cells" => length(scope_collection.cells),
        "compared_cells" => length(active_collection.cells),
        "eligibility_gaps" => eligibility_gaps,
    )
    temporary = "$path.tmp"
    open(temporary, "w") do io
        TOML.print(io, report; sorted = true)
    end
    mv(temporary, path; force = true)
    return path
end

function run_selected_case(
    output_root;
    collection,
    concurrency_budget = getfield(
        parentmodule(@__MODULE__),
        :TestbedReferenceCellComparisons,
    ).ConcurrencyBudget(1),
    stages = (
        native_mimics.native_workflow().NativeStage(
            :prespin,
            365,
            100;
            write_output = false,
        ),
        native_mimics.native_workflow().NativeStage(
            :spin,
            20 * 365,
            499;
            write_output = false,
        ),
        native_mimics.native_workflow().NativeStage(
            :spin_continuation,
            20 * 365,
            499;
            write_output = false,
        ),
        native_mimics.native_workflow().NativeStage(
            :historical,
            114 * 365,
            1,
        ),
    ),
    budget_rtol = 5e-12,
    compare_references = true,
    reference_path = nothing,
    comparison_policy = nothing,
    eligibility_gaps = Dict{String, Any}[],
    execution_cell_ids = nothing,
    nonfinite_observer = nothing,
)
    reference = if compare_references
        isnothing(reference_path) &&
            error("Pinned MIMICS-CN oracle path is required")
        isnothing(comparison_policy) &&
            error("MIMICS-CN Comparison Policy is required")
        workflow_reference(
            collection;
            path = reference_path,
            comparison_policy,
            eligibility_gaps,
        )
    else
        nothing
    end
    cells = getfield(
        parentmodule(@__MODULE__),
        :TestbedReferenceCellComparisons,
    )
    scope_collection =
        isnothing(execution_cell_ids) ? collection :
        cells.subset(collection, execution_cell_ids)
    requested_ids = getproperty.(scope_collection.cells, :id)
    requested = Set(requested_ids)
    eligible_ids =
        isnothing(reference) ? requested_ids :
        filter(id -> id in requested, reference.eligible_ids)
    active_collection = cells.subset(scope_collection, eligible_ids)
    reported_gaps =
        filter(gap -> Int(gap["cell_id"]) in requested, eligibility_gaps)
    setup = load_setup(; collection = active_collection)
    boundary_snapshots = Dict{String, Any}()
    budget = native_mimics.BudgetAccumulator(setup.grid)
    annual_npp = setup.forcing.annual_npp_tracker
    diagnostics = native_mimics.mimics_cn_diagnostics(
        setup.normal.model.mimics_soil.parameters,
    )
    model_for_stage(stage) =
        stage.name == :prespin ? setup.prespin.model : setup.normal.model
    fixed_plant_stoichiometry = Dict{Symbol, Vector{Float64}}()
    function prepare_stage!(stage, current_state, model)
        stage.name == :prespin ||
            native_mimics.quantize_fortran_restart!(current_state)
        parameters =
            stage.name == :prespin ? setup.prespin.parameters :
            setup.normal.parameters
        fixed_plant_stoichiometry[stage.name] =
            native_mimics.use_initial_plant_stoichiometry!(
                model,
                setup.grid,
                parameters,
                current_state,
            )
    end
    function update_drivers!(stage, index, time)
        update_forcing!(setup.forcing, stage, index, time)
    end
    function after_step!(stage, step, Y, p, _)
        native_mimics.native_mimics().accumulate_annual_npp!(
            annual_npp,
            p,
        )
        native_mimics.accumulate_budget!(budget, stage, p)
        step == 1 && native_mimics.restore_plant_stoichiometry!(
            model_for_stage(stage),
            fixed_plant_stoichiometry[stage.name],
        )
        if !isnothing(nonfinite_observer)
            nonfinite_observer(stage, step, Y, p, diagnostics)
        end
    end
    carbon_budget(stage, initial_state, final_state) =
        native_mimics.budget_report(
            budget,
            stage,
            initial_state,
            final_state,
            :carbon;
            rtol = budget_rtol,
        )
    nitrogen_budget(stage, initial_state, final_state) =
        native_mimics.budget_report(
            budget,
            stage,
            initial_state,
            final_state,
            :nitrogen;
            rtol = budget_rtol,
        )
    function compare_boundary(stage, result, _)
        boundary_snapshots[String(stage.name)] = state_snapshot(result.state)
        return isnothing(reference) ?
               Dict("skipped" => "reference comparison disabled") :
               compare_boundary_reference(
            reference,
            stage,
            result.state,
            active_collection,
            concurrency_budget,
        )
    end
    function compare_historical(path)
        model_budget =
            historical_budget_values(boundary_snapshots, path, setup.grid)
        return isnothing(reference) ?
               Dict(
            "output" => Dict(
                "records" => NCDatasets.NCDataset(path) do output
                    size(output["time"], 1)
                end,
            ),
            "budget" => model_budget,
            "skipped" => "reference comparison disabled",
        ) : compare_historical_reference(
            reference,
            path,
            model_budget,
            active_collection,
            concurrency_budget,
        )
    end
    try
        result = native_mimics.run_case(
            setup.initial_state,
            stages,
            output_root;
            model_for_stage,
            prepare_stage!,
            update_forcing! = update_drivers!,
            after_step!,
            diagnostics,
            output_eltype = Float32,
            deflatelevel = 1,
            provenance = stage -> stage_provenance(setup, stage),
            compare_boundary,
            compare_historical,
            carbon_budget,
            nitrogen_budget,
        )
        annotate_report!(
            result.report,
            scope_collection,
            active_collection,
            reported_gaps,
        )
        return result
    finally
        for stage in stages
            haskey(fixed_plant_stoichiometry, stage.name) || continue
            native_mimics.restore_plant_stoichiometry!(
                model_for_stage(stage),
                fixed_plant_stoichiometry[stage.name],
            )
        end
    end
end

end
