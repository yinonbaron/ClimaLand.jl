using Test

@testset "CORPSE comparison accepts replaceable cell collections" begin
    ordinary = TestbedReferenceCellComparisons.ordinary_cell_collection()
    extended = TestbedReferenceCellComparisons.extended_cell_collection()
    subset =
        TestbedReferenceCellComparisons.subset(extended, [51, 532, 618, 3442])

    for (collection, workers) in ((ordinary, 1), (extended, 2), (subset, 2))
        budget = TestbedReferenceCellComparisons.ConcurrencyBudget(workers)
        report = TestbedSelectedCORPSEWorkflow.run_corpse_comparison(
            collection,
            budget,
        )
        productive = filter(
            TestbedSelectedCORPSEWorkflow.corpse_active,
            collection.cells,
        )
        inactive = filter(
            cell -> !TestbedSelectedCORPSEWorkflow.corpse_active(cell),
            collection.cells,
        )

        @test getproperty.(report.results, :cell) == productive
        @test getproperty.(report.skipped, :cell) == inactive
        @test isempty(report.failures)
        @test report.workers ==
              min(workers, Threads.nthreads(), length(productive))
        @test all(
            result.value.legacy_daily.all_match for result in report.results
        )
        @test all(
            result.value.continuous_rate.all_match for result in report.results
        )
        @test all(
            result.value.continuous_rate.maximum_relative_pool_error < 1e-3 for
            result in report.results
        )
        @test all(
            result.value.continuous_rate.maximum_relative_respiration_error <
            1e-2 for result in report.results
        )
    end
end

@testset "CORPSE failures retain selected-cell context" begin
    reference_cells = TestbedReferenceCellComparisons
    collection = reference_cells.subset(
        reference_cells.extended_cell_collection(),
        [532],
    )
    original = only(collection.cells)
    bad_cell = reference_cells.ReferenceCell(
        original.id,
        original.pft + 1,
        ["intentional provenance mismatch"],
    )
    bad_collection = reference_cells.ReferenceCellCollection(
        "bad PFT",
        [bad_cell],
        collection.manifest,
        collection.files,
    )

    caught = try
        TestbedSelectedCORPSEWorkflow.run_corpse_comparison(
            bad_collection,
            reference_cells.ConcurrencyBudget(1),
        )
        nothing
    catch error
        error
    end
    @test caught isa reference_cells.ReferenceComparisonError
    message = sprint(showerror, caught)
    @test occursin("cell 532", message)
    @test occursin("PFT $(bad_cell.pft)", message)
    @test occursin("intentional provenance mismatch", message)
end

@testset "CORPSE reference provenance is pinned" begin
    provenance = TestbedSelectedCORPSEWorkflow.reference_provenance()

    @test provenance["source_commit"] ==
          "27ae1a0b673411642cd780ecad66d1c8f84e6a58"
    @test length(provenance["reference_sha256"]) == 64
    @test !isempty(provenance["configuration"])
    @test !isempty(provenance["transformations"])
    @test occursin("xcnpp = xcgpp / 2", join(provenance["transformations"]))
    @test Set(keys(provenance["input_sha256"]["staged_run"])) == Set((
        "meteorology",
        "grid",
        "soil",
        "casa_parameters",
        "corpse_parameters",
        "phenology",
        "perturbation",
        "control",
    ))
    @test all(
        length(hash) == 64 for
        hash in values(provenance["input_sha256"]["staged_run"])
    )
    @test length(provenance["build"]["executable_sha256"]) == 64
    @test occursin("not reproducible", provenance["historical_limitation"])
end
