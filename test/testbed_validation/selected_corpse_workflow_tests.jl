using Test

import NCDatasets

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

@testset "complete selected-cell CORPSE workflow reference" begin
    reference = TestbedSelectedCORPSEWorkflow.verified_workflow_reference()
    manifest = reference.manifest

    @test manifest["oracle"]["designation"] == "fresh_gswp3_fortran"
    @test manifest["oracle"]["legacy_2000_2010_mean"]["promoted"] == false
    @test manifest["source"]["commit"] ==
          "27ae1a0b673411642cd780ecad66d1c8f84e6a58"
    @test Set(keys(manifest["collection"])) == Set(("core", "extended"))
    @test all(
        collection["status"] == "complete" for
        collection in values(manifest["collection"])
    )

    stages = manifest["stage"]
    @test getindex.(stages, "name") ==
          ["prespin", "spin", "restart", "historical"]
    @test all(stage["status"] == "complete" for stage in stages)
    @test all(
        Set(keys(stage["hashes"])) ==
        Set(("control", "inputs", "outputs", "log")) for stage in stages
    )
    @test all(
        all(length(hash) == 64 for hash in values(stage["hashes"][kind])) for
        stage in stages for kind in ("inputs", "outputs")
    )
    @test all(length(stage["hashes"]["control"]) == 64 for stage in stages)
    @test all(length(stage["hashes"]["log"]) == 64 for stage in stages)

    NCDatasets.NCDataset(reference.path) do dataset
        @test Int.(dataset["cellid"][:]) ==
              manifest["collection"]["extended"]["cell_ids"]
        @test size(dataset["casa_state"], 2) == 4
        @test size(dataset["corpse_state"], 2) == 4
        @test dataset["casa_state"].attrib["units"] == "g C m-2"
        @test dataset["corpse_state"].attrib["units"] == "kg C m-2"
        @test "original_carbon" in dataset["corpse_state_field"][:]
        @test "cumulative_respiration" in dataset["corpse_state_field"][:]
    end

    diagnostics = manifest["diagnostics"]
    @test length(diagnostics["spin_convergence"]) ==
          length(manifest["collection"]["extended"]["cell_ids"])
    @test length(diagnostics["conservation"]) ==
          4 * length(manifest["collection"]["extended"]["cell_ids"])
    @test all(record["close"] for record in diagnostics["conservation"])
end
