import Pkg
import Serialization
import TOML

using ClimaLand

include(joinpath(@__DIR__, "selected_cell_fixtures.jl"))
include(joinpath(@__DIR__, "representative_cell_selection.jl"))
include(joinpath(@__DIR__, "reference_cell_comparisons.jl"))
include(joinpath(@__DIR__, "native_workflow.jl"))
include(joinpath(@__DIR__, "native_casa_c_reconstruction.jl"))
include(joinpath(@__DIR__, "selected_casa_workflow.jl"))
include(joinpath(@__DIR__, "generate_selected_casa_workflow_reference.jl"))

const Selection = TestbedRepresentativeCellSelection
const ReferenceCells = TestbedReferenceCellComparisons
const Workflow = TestbedSelectedCASAWorkflow
const CORPSE_REPRESENTATIVE_GAPS = [
    Dict(
        "model" => "CORPSE",
        "cell_id" => 51,
        "pft" => 17,
        "reason" => "PFT 17 (water) maps to Fortran vegetation category 0; corpse_cycle is outside its model applicability and is not executed.",
        "reviewed" => true,
        "evidence_kind" => "inactive_model_mask",
        "first_ineligible_stage" => "prespin",
        "evidence_variable" => "veg%iveg2",
        "fortran_vegetation_category" => 0,
    ),
    Dict(
        "model" => "CORPSE",
        "cell_id" => 3442,
        "pft" => 11,
        "reason" => "PFT 11 (permanent wetland) maps to Fortran vegetation category 0 in the pinned parameter table; corpse_cycle is outside its model applicability and is not executed.",
        "reviewed" => true,
        "evidence_kind" => "inactive_model_mask",
        "first_ineligible_stage" => "prespin",
        "evidence_variable" => "veg%iveg2",
        "fortran_vegetation_category" => 0,
    ),
]

function copy_payload(source, destination)
    for name in readdir(source)
        cp(joinpath(source, name), joinpath(destination, name); force = true)
    end
    return nothing
end

function bind_local_artifact!(artifacts_toml, name, payload)
    hash = Pkg.Artifacts.create_artifact() do artifact_directory
        copy_payload(payload, artifact_directory)
    end
    Pkg.Artifacts.bind_artifact!(artifacts_toml, name, hash; force = true)
    return hash
end

function build(args)
    length(args) == 6 || error(
        "usage: generate_representative_validation.jl build FORCING_ROOT SOURCE_ROOT FORTRAN_ROOT WORK_ROOT ARTIFACTS_TOML SCOPE_MANIFEST",
    )
    forcing_root,
    source_root,
    fortran_root,
    work_root,
    artifacts_toml,
    scope_manifest = args
    source_paths =
        [joinpath(forcing_root, "met_$(year)_$(year).nc") for year in 1901:2014]
    all(isfile, source_paths) || error("The 1901-2014 forcing is incomplete")
    grid_path =
        joinpath(source_root, "GRID_CN", "gridinfo_igbpz_CLM5_GSWP3.csv")
    soil_path = joinpath(source_root, "GRID_CN", "gridinfo_soil_CLM5_GSWP3.csv")
    smoke_manifest = joinpath(@__DIR__, "validation", "scopes", "smoke.toml")
    smoke_ids = Int.(TOML.parsefile(smoke_manifest)["cell_ids"])
    mkpath(work_root)
    candidate_cache = joinpath(work_root, "representative_candidates.bin")
    candidates = if isfile(candidate_cache)
        open(Serialization.deserialize, candidate_cache)
    else
        generated = Selection.representative_candidates(
            source_paths,
            grid_path,
            soil_path,
        )
        open(candidate_cache, "w") do io
            Serialization.serialize(io, generated)
        end
        generated
    end
    selection = Selection.select_representative_cells(
        candidates,
        smoke_ids;
        total_cells = 80,
        seed = 31432026,
    )
    Selection.write_scope_manifest(
        scope_manifest,
        selection,
        smoke_ids,
        source_paths,
        grid_path,
        soil_path,
        smoke_manifest;
        seed = 31432026,
        eligibility_gaps = CORPSE_REPRESENTATIVE_GAPS,
    )

    forcing_payload = joinpath(work_root, "representative_forcing")
    fixture_manifest = joinpath(forcing_payload, "fixture.toml")
    if isfile(fixture_manifest)
        manifest = TOML.parsefile(fixture_manifest)
        Int.(manifest["selection"]["representative_cell_ids"]) ==
        selection.cell_ids || error("Existing Representative forcing differs")
        get(manifest["selection"], "scope_manifest_sha256", nothing) ==
        Selection.sha256sum(scope_manifest) ||
            error("Existing Representative forcing has stale scope provenance")
        TestbedSelectedCellFixtures.verified_fixture_paths(
            fixture_manifest,
            manifest,
        )
        all(values(manifest["audit"])) ||
            error("Existing Representative forcing failed its audit")
    else
        Selection.build_representative_fixture(
            source_paths,
            source_root,
            forcing_payload,
            candidates,
            selection,
            scope_manifest,
        )
    end
    forcing_hash = bind_local_artifact!(
        artifacts_toml,
        "representative_forcing",
        forcing_payload,
    )
    forcing_artifact = Pkg.Artifacts.artifact_path(forcing_hash)
    collection = ReferenceCells.selected_cell_collection(
        "representative",
        selection.cell_ids;
        manifest_path = joinpath(forcing_artifact, basename(fixture_manifest)),
    )

    native_output = joinpath(work_root, "representative_casa_c_native")
    result = Workflow.run_selected_case(
        native_output;
        configuration = :carbon_only,
        collection,
        concurrency_budget = ReferenceCells.ConcurrencyBudget(1),
        compare_references = false,
    )
    reference_payload = joinpath(work_root, "representative_casa_c_reference")
    mkpath(reference_payload)
    reference_path = joinpath(reference_payload, "complete_casa_workflow.toml")
    generate_reference(
        :carbon_only,
        collection,
        native_output,
        fortran_root,
        reference_path,
    )
    reference_hash = bind_local_artifact!(
        artifacts_toml,
        "representative_casa_c_reference",
        reference_payload,
    )
    TOML.print(
        stdout,
        Dict(
            "scope_manifest" => abspath(scope_manifest),
            "forcing_artifact" => string(forcing_hash),
            "forcing_path" => Pkg.Artifacts.artifact_path(forcing_hash),
            "reference_artifact" => string(reference_hash),
            "reference_path" => Pkg.Artifacts.artifact_path(reference_hash),
            "native_report" => result.report,
        );
        sorted = true,
    )
    println()
    return 0
end

function build_casa_cn(args)
    length(args) == 4 || error(
        "usage: generate_representative_validation.jl build-casa-cn FORTRAN_ROOT WORK_ROOT ARTIFACTS_TOML SCOPE_MANIFEST",
    )
    fortran_root, work_root, artifacts_toml, scope_manifest = args
    scope = TOML.parsefile(scope_manifest)
    cell_ids = Int.(scope["cell_ids"])
    get(scope, "name", nothing) == "representative" &&
        get(scope, "schema_version", nothing) == 1 &&
        length(cell_ids) == 80 &&
        cell_ids == sort(unique(cell_ids)) || error(
        "CASA-CN artifact requires the immutable 80-cell Representative scope",
    )
    forcing_hash =
        Pkg.Artifacts.artifact_hash("representative_forcing", artifacts_toml)
    isnothing(forcing_hash) &&
        error("Representative forcing artifact binding is missing")
    Pkg.Artifacts.artifact_exists(forcing_hash) ||
        error("Representative forcing artifact is unavailable locally")
    fixture_manifest =
        joinpath(Pkg.Artifacts.artifact_path(forcing_hash), "fixture.toml")
    fixture = TOML.parsefile(fixture_manifest)
    get(
        get(fixture, "selection", Dict{String, Any}()),
        "scope_manifest_sha256",
        nothing,
    ) == Selection.sha256sum(scope_manifest) ||
        error("Representative forcing has stale scope provenance")
    collection = ReferenceCells.selected_cell_collection(
        "representative",
        cell_ids;
        manifest_path = fixture_manifest,
    )
    native_output = joinpath(work_root, "representative_casa_cn_native")
    result = Workflow.run_selected_case(
        native_output;
        configuration = :carbon_nitrogen,
        collection,
        concurrency_budget = ReferenceCells.ConcurrencyBudget(1),
        compare_references = false,
        diagnostics = setup -> NativeCASACN.casa_cn_diagnostics(
            setup.normal.model.casa_soil.parameters,
        ),
    )
    reference_payload = joinpath(work_root, "representative_casa_cn_reference")
    mkpath(reference_payload)
    reference_path = joinpath(reference_payload, "complete_casa_workflow.toml")
    generate_reference(
        :carbon_nitrogen,
        collection,
        native_output,
        fortran_root,
        reference_path,
    )
    reference_hash = bind_local_artifact!(
        artifacts_toml,
        "representative_casa_cn_reference",
        reference_payload,
    )
    TOML.print(
        stdout,
        Dict(
            "scope_manifest" => abspath(scope_manifest),
            "forcing_artifact" => string(forcing_hash),
            "reference_artifact" => string(reference_hash),
            "reference_path" => Pkg.Artifacts.artifact_path(reference_hash),
            "native_report" => result.report,
        );
        sorted = true,
    )
    println()
    return 0
end

function main(args = ARGS)
    isempty(args) && error(
        "usage: generate_representative_validation.jl build|build-casa-cn ...",
    )
    first(args) == "build" && return build(args[2:end])
    first(args) == "build-casa-cn" && return build_casa_cn(args[2:end])
    error("Only build and build-casa-cn are supported")
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
