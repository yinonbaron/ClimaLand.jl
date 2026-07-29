using Test

const REFERENCE_CELLS = TestbedReferenceCellComparisons

@testset "reference-cell comparison contract" begin
    ordinary =
        @test_logs (:warn, r"ordinary_cell_collection\(\) is deprecated") REFERENCE_CELLS.ordinary_cell_collection()
    extended =
        @test_logs (:warn, r"extended_cell_collection\(\) is deprecated") REFERENCE_CELLS.extended_cell_collection()
    @test ordinary.name == "core"
    @test extended.name == "smoke"
    subset =
        REFERENCE_CELLS.subset(extended, getproperty.(ordinary.cells[1:2], :id))

    @test getproperty.(ordinary.cells, :id) ==
          Int.(ordinary.manifest["selection"]["core_cell_ids"])
    @test getproperty.(extended.cells, :id) ==
          Int.(extended.manifest["selection"]["extended_cell_ids"])
    @test getproperty.(subset.cells, :id) ==
          getproperty.(ordinary.cells[1:2], :id)

    active = cell -> cell.pft != 17
    compare = REFERENCE_CELLS.ReferenceComparison(
        "identity",
        (cell, _) ->
            REFERENCE_CELLS.CellComparison(cell.id == cell.id, cell.id);
        eligible = active,
    )
    for collection in (ordinary, subset)
        report = REFERENCE_CELLS.run_comparison(
            collection,
            compare,
            REFERENCE_CELLS.ConcurrencyBudget(1),
        )
        @test getproperty.(report.results, :cell) ==
              filter(active, collection.cells)
        @test getproperty.(report.skipped, :cell) ==
              filter(!active, collection.cells)
        @test report.failures == []
    end
end

@testset "reference-cell deterministic bounded scheduling" begin
    collection = REFERENCE_CELLS.subset(
        REFERENCE_CELLS.smoke_cell_collection(),
        [532, 618, 626, 1285],
    )
    active = Threads.Atomic{Int}(0)
    maximum_active = Threads.Atomic{Int}(0)
    resources = Any[]
    resource_lock = ReentrantLock()
    with_resource = function (callback, _)
        resource = Ref(nothing)
        lock(resource_lock) do
            push!(resources, resource)
        end
        callback(resource)
    end
    compare = REFERENCE_CELLS.ReferenceComparison(
        "out-of-order",
        function (cell, resource)
            current = Threads.atomic_add!(active, 1) + 1
            Threads.atomic_max!(maximum_active, current)
            sleep((700 - cell.id % 700) / 10_000)
            Threads.atomic_sub!(active, 1)
            REFERENCE_CELLS.CellComparison(true, (cell.id, objectid(resource)))
        end;
        with_resource,
    )
    report = REFERENCE_CELLS.run_comparison(
        collection,
        compare,
        REFERENCE_CELLS.ConcurrencyBudget(2),
    )

    @test getproperty.(getproperty.(report.results, :value), 1) ==
          getproperty.(collection.cells, :id)
    @test maximum_active[] <= 2
    @test length(resources) == length(collection.cells)
    @test length(unique(objectid.(resources))) == length(collection.cells)

    serial = REFERENCE_CELLS.run_comparison(
        collection,
        compare,
        REFERENCE_CELLS.ConcurrencyBudget(1),
    )
    @test getproperty.(getproperty.(serial.results, :value), 1) ==
          getproperty.(collection.cells, :id)
end

@testset "reference-cell failure aggregation" begin
    collection = REFERENCE_CELLS.subset(
        REFERENCE_CELLS.smoke_cell_collection(),
        [532, 618, 626],
    )
    comparison = REFERENCE_CELLS.ReferenceComparison(
        "failure context",
        (cell, _) ->
            cell.id == 618 ? error("synthetic failure") :
            REFERENCE_CELLS.CellComparison(cell.id != 626, cell.id),
    )

    failure = try
        REFERENCE_CELLS.run_comparison(
            collection,
            comparison,
            REFERENCE_CELLS.ConcurrencyBudget(2),
        )
        nothing
    catch error
        error
    end
    @test failure isa REFERENCE_CELLS.ReferenceComparisonError
    @test getproperty.(failure.report.failures, :cell) == collection.cells[2:3]
    message = sprint(showerror, failure)
    for cell in collection.cells[2:3]
        @test occursin("cell $(cell.id)", message)
        @test occursin("PFT $(cell.pft)", message)
        @test all(reason -> occursin(reason, message), cell.reasons)
    end
end

@testset "reference-cell eligibility failure context" begin
    collection = REFERENCE_CELLS.subset(
        REFERENCE_CELLS.smoke_cell_collection(),
        [532, 618],
    )
    comparison = REFERENCE_CELLS.ReferenceComparison(
        "eligibility context",
        (cell, _) -> cell.id;
        eligible = cell ->
            cell.id == first(collection.cells).id ?
            error("eligibility failure") : true,
    )

    failure = try
        REFERENCE_CELLS.run_comparison(
            collection,
            comparison,
            REFERENCE_CELLS.ConcurrencyBudget(1),
        )
        nothing
    catch error
        error
    end
    @test failure isa REFERENCE_CELLS.ReferenceComparisonError
    @test only(failure.report.failures).cell == first(collection.cells)
    @test occursin("eligibility failure", sprint(showerror, failure))
end
