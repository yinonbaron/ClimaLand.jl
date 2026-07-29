module TestbedReferenceCellComparisons

import TOML

import NCDatasets

selected_fixtures() =
    getfield(parentmodule(@__MODULE__), :TestbedSelectedCellFixtures)

const SELECTED_CELL_MANIFEST =
    joinpath(@__DIR__, "fixtures", "selected_cells", "fixture.toml")

struct ReferenceCell
    id::Int
    pft::Int
    reasons::Vector{String}
end

struct ReferenceCellCollection
    name::String
    cells::Vector{ReferenceCell}
    manifest::Dict{String, Any}
    files::Dict{String, String}
end

function selected_cell_collection(name, ids)
    manifest = TOML.parsefile(SELECTED_CELL_MANIFEST)
    manifest["schema_version"] == 1 ||
        error("Unsupported selected-cell fixture schema")
    files = selected_fixtures().verified_fixture_paths(
        SELECTED_CELL_MANIFEST,
        manifest,
    )
    metadata = Dict(Int(cell["id"]) => cell for cell in manifest["cell"])
    cells = map(sort!(unique!(Int.(collect(ids))))) do id
        haskey(metadata, id) || error("Selected fixture cell $id is unknown")
        cell = metadata[id]
        ReferenceCell(id, Int(cell["pft"]), sort!(String.(cell["reasons"])))
    end
    return ReferenceCellCollection(String(name), cells, manifest, files)
end

"Return the 11-cell Core Scope."
function core_cell_collection()
    manifest = TOML.parsefile(SELECTED_CELL_MANIFEST)
    return selected_cell_collection(
        "core",
        manifest["selection"]["core_cell_ids"],
    )
end

"Return the 37-cell Smoke Scope."
function smoke_cell_collection()
    manifest = TOML.parsefile(SELECTED_CELL_MANIFEST)
    return selected_cell_collection(
        "smoke",
        manifest["selection"]["extended_cell_ids"],
    )
end

"Deprecated alias for `core_cell_collection()`."
function ordinary_cell_collection()
    @warn "ordinary_cell_collection() is deprecated; use core_cell_collection()"
    return core_cell_collection()
end

"Deprecated alias for `smoke_cell_collection()`."
function extended_cell_collection()
    @warn "extended_cell_collection() is deprecated; use smoke_cell_collection()"
    return smoke_cell_collection()
end

"Return a deterministically ordered subset of `collection`."
function subset(collection::ReferenceCellCollection, ids)
    requested = Set(Int.(collect(ids)))
    cells = filter(cell -> cell.id in requested, collection.cells)
    found = Set(getproperty.(cells, :id))
    missing = sort!(collect(setdiff(requested, found)))
    isempty(missing) ||
        error("Cells are absent from $(collection.name): $missing")
    return ReferenceCellCollection(
        "$(collection.name) subset",
        cells,
        collection.manifest,
        collection.files,
    )
end

function with_fixture(callback, collection::ReferenceCellCollection)
    return NCDatasets.NCDataset(collection.files["forcing"]) do forcing
        fixture_ids = Int.(forcing["cellid"][:])
        cell_indices = map(collection.cells) do cell
            index = findfirst(==(cell.id), fixture_ids)
            isnothing(index) &&
                error("Cell $(cell.id) is missing from the forcing fixture")
            index
        end
        callback((;
            manifest = collection.manifest,
            files = collection.files,
            forcing,
            cells = collection.cells,
            cell_ids = getproperty.(collection.cells, :id),
            cell_indices,
        ))
    end
end

struct ConcurrencyBudget
    workers::Int
    function ConcurrencyBudget(workers)
        workers > 0 ||
            throw(ArgumentError("concurrency budget must be positive"))
        new(Int(workers))
    end
end

struct CellComparison{T}
    passed::Bool
    value::T
end

struct ReferenceComparison{Eligibility, Runner, ResourceScope}
    name::String
    eligible::Eligibility
    run::Runner
    with_resource::ResourceScope
end

function ReferenceComparison(
    name,
    run;
    eligible = _ -> true,
    with_resource = (callback, _) -> callback(nothing),
)
    return ReferenceComparison(String(name), eligible, run, with_resource)
end

struct CellResult{T}
    cell::ReferenceCell
    value::T
    seconds::Float64
end

struct SkippedCell
    cell::ReferenceCell
end

struct CellFailure{T, E}
    cell::ReferenceCell
    value::T
    error::E
    seconds::Float64
end

struct ComparisonReport{Results, Failures}
    name::String
    results::Results
    skipped::Vector{SkippedCell}
    failures::Failures
    seconds::Float64
    workers::Int
end

struct ReferenceComparisonError{Report} <: Exception
    report::Report
end

function Base.showerror(io::IO, error::ReferenceComparisonError)
    report = error.report
    print(
        io,
        "$(report.name) failed for $(length(report.failures)) reference cells",
    )
    for failure in report.failures
        cell = failure.cell
        print(
            io,
            "\n  cell $(cell.id), PFT $(cell.pft), reasons: ",
            join(cell.reasons, "; "),
            ": ",
        )
        showerror(io, failure.error)
    end
end

function run_cell(comparison, cell)
    started = time_ns()
    try
        outcome = comparison.with_resource(cell) do resource
            value = comparison.run(cell, resource)
            value isa CellComparison ? value : CellComparison(true, value)
        end
        seconds = (time_ns() - started) / 1e9
        return outcome.passed ? CellResult(cell, outcome.value, seconds) :
               CellFailure(
            cell,
            outcome.value,
            ErrorException("comparison returned a failing result"),
            seconds,
        )
    catch error
        return CellFailure(cell, nothing, error, (time_ns() - started) / 1e9)
    end
end

"Run one model comparison with bounded scheduling and deterministic reporting."
function run_comparison(
    collection::ReferenceCellCollection,
    comparison::ReferenceComparison,
    budget::ConcurrencyBudget;
    throw_on_failure = true,
)
    started = time_ns()
    eligible = ReferenceCell[]
    skipped = SkippedCell[]
    eligibility_failures = Any[]
    for cell in collection.cells
        cell_started = time_ns()
        try
            comparison.eligible(cell) ? push!(eligible, cell) :
            push!(skipped, SkippedCell(cell))
        catch error
            push!(
                eligibility_failures,
                CellFailure(
                    cell,
                    nothing,
                    error,
                    (time_ns() - cell_started) / 1e9,
                ),
            )
        end
    end
    worker_count = min(budget.workers, Threads.nthreads(), length(eligible))
    slots = Vector{Any}(undef, length(eligible))
    if worker_count == 1
        for index in eachindex(eligible)
            slots[index] = run_cell(comparison, eligible[index])
        end
    elseif worker_count > 1
        next_index = Threads.Atomic{Int}(1)
        tasks = map(1:worker_count) do _
            Threads.@spawn begin
                while true
                    index = Threads.atomic_add!(next_index, 1)
                    index > length(eligible) && break
                    slots[index] = run_cell(comparison, eligible[index])
                end
            end
        end
        foreach(fetch, tasks)
    end
    results = filter(result -> result isa CellResult, slots)
    failures = [
        eligibility_failures
        filter(result -> result isa CellFailure, slots)
    ]
    cell_order =
        Dict(cell.id => index for (index, cell) in enumerate(collection.cells))
    sort!(failures; by = failure -> cell_order[failure.cell.id])
    report = ComparisonReport(
        comparison.name,
        results,
        skipped,
        failures,
        (time_ns() - started) / 1e9,
        max(worker_count, 1),
    )
    throw_on_failure &&
        !isempty(failures) &&
        throw(ReferenceComparisonError(report))
    return report
end

end
