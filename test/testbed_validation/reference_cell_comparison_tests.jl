using Test

const ReferenceCells = TestbedReferenceCellComparisons

@testset "reference-cell comparison contract" begin
    ordinary = ReferenceCells.ordinary_cell_collection()
    extended = ReferenceCells.extended_cell_collection()
    subset =
        ReferenceCells.subset(extended, getproperty.(ordinary.cells[1:2], :id))

    @test getproperty.(ordinary.cells, :id) ==
          Int.(ordinary.manifest["selection"]["core_cell_ids"])
    @test getproperty.(extended.cells, :id) ==
          Int.(extended.manifest["selection"]["extended_cell_ids"])
    @test getproperty.(subset.cells, :id) ==
          getproperty.(ordinary.cells[1:2], :id)

    active = cell -> cell.pft != 17
    compare = ReferenceCells.ReferenceComparison(
        "identity",
        (cell, _) ->
            ReferenceCells.CellComparison(cell.id == cell.id, cell.id);
        eligible = active,
    )
    for collection in (ordinary, subset)
        report = ReferenceCells.run_comparison(
            collection,
            compare,
            ReferenceCells.ConcurrencyBudget(1),
        )
        @test getproperty.(report.results, :cell) ==
              filter(active, collection.cells)
        @test getproperty.(report.skipped, :cell) ==
              filter(!active, collection.cells)
        @test report.failures == []
    end
end

@testset "reference-cell deterministic bounded scheduling" begin
    collection = ReferenceCells.subset(
        ReferenceCells.extended_cell_collection(),
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
    compare = ReferenceCells.ReferenceComparison(
        "out-of-order",
        function (cell, resource)
            current = Threads.atomic_add!(active, 1) + 1
            Threads.atomic_max!(maximum_active, current)
            sleep((700 - cell.id % 700) / 10_000)
            Threads.atomic_sub!(active, 1)
            ReferenceCells.CellComparison(true, (cell.id, objectid(resource)))
        end;
        with_resource,
    )
    report = ReferenceCells.run_comparison(
        collection,
        compare,
        ReferenceCells.ConcurrencyBudget(2),
    )

    @test getproperty.(getproperty.(report.results, :value), 1) ==
          getproperty.(collection.cells, :id)
    @test maximum_active[] <= 2
    @test length(resources) == length(collection.cells)
    @test length(unique(objectid.(resources))) == length(collection.cells)

    serial = ReferenceCells.run_comparison(
        collection,
        compare,
        ReferenceCells.ConcurrencyBudget(1),
    )
    @test getproperty.(getproperty.(serial.results, :value), 1) ==
          getproperty.(collection.cells, :id)
end

@testset "reference-cell failure aggregation" begin
    collection = ReferenceCells.subset(
        ReferenceCells.extended_cell_collection(),
        [532, 618, 626],
    )
    comparison = ReferenceCells.ReferenceComparison(
        "failure context",
        (cell, _) ->
            cell.id == 618 ? error("synthetic failure") :
            ReferenceCells.CellComparison(cell.id != 626, cell.id),
    )

    failure = try
        ReferenceCells.run_comparison(
            collection,
            comparison,
            ReferenceCells.ConcurrencyBudget(2),
        )
        nothing
    catch error
        error
    end
    @test failure isa ReferenceCells.ReferenceComparisonError
    @test getproperty.(failure.report.failures, :cell) == collection.cells[2:3]
    message = sprint(showerror, failure)
    for cell in collection.cells[2:3]
        @test occursin("cell $(cell.id)", message)
        @test occursin("PFT $(cell.pft)", message)
        @test all(reason -> occursin(reason, message), cell.reasons)
    end
end
