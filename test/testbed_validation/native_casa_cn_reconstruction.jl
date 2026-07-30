if !isdefined(@__MODULE__, :TestbedNativeWorkflow)
    include(joinpath(@__DIR__, "native_workflow.jl"))
end

if !isdefined(@__MODULE__, :TestbedNativeCASACReconstruction)
    include(joinpath(@__DIR__, "native_casa_c_reconstruction.jl"))
end

if !isdefined(@__MODULE__, :TestbedSelectedCASAWorkflow)
    include(joinpath(@__DIR__, "selected_casa_workflow.jl"))
end

module TestbedNativeCASACNReconstruction

import NCDatasets
import TOML
import LinearAlgebra

native_workflow() = getfield(parentmodule(@__MODULE__), :TestbedNativeWorkflow)
native_casa() =
    getfield(parentmodule(@__MODULE__), :TestbedNativeCASACReconstruction)
selected_casa() =
    getfield(parentmodule(@__MODULE__), :TestbedSelectedCASAWorkflow)

# =============================================================================
# Scientific state and diagnostics
# =============================================================================

const COMPLETE_STAGES = selected_casa().COMPLETE_STAGES

const STOCK_VARIABLES = (
    "cleaf" => (:casa_plant, :c_leaf),
    "nleaf" => (:casa_plant, :n_leaf),
    "cwood" => (:casa_plant, :c_wood),
    "nwood" => (:casa_plant, :n_wood),
    "cfroot" => (:casa_plant, :c_fine_root),
    "nfroot" => (:casa_plant, :n_fine_root),
    "clitmetb" => (:casa_soil, :c_litter_metabolic),
    "nlitmetb" => (:casa_soil, :n_litter_metabolic),
    "clitstr" => (:casa_soil, :c_litter_structural),
    "nlitstr" => (:casa_soil, :n_litter_structural),
    "clitcwd" => (:casa_soil, :c_litter_cwd),
    "nlitcwd" => (:casa_soil, :n_litter_cwd),
    "csoilmic" => (:casa_soil, :c_soil_microbial),
    "nsoilmic" => (:casa_soil, :n_soil_microbial),
    "csoilslow" => (:casa_soil, :c_soil_slow),
    "nsoilslow" => (:casa_soil, :n_soil_slow),
    "csoilpass" => (:casa_soil, :c_soil_passive),
    "nsoilpass" => (:casa_soil, :n_soil_passive),
    "nMineral" => (:casa_soil, :n_mineral),
)

const FLUX_VARIABLES = (
    native_casa().FLUX_VARIABLES...,
    "nMinDep" => "diagnostic__n_deposition",
    "nMinFix" => "diagnostic__n_fixation",
    "nMinUptake" => "diagnostic__n_plant_uptake",
    "nMinLeach" => "diagnostic__n_leaching",
    "nMinLoss" => "diagnostic__n_gaseous_loss",
    "nLitMineralization" => "diagnostic__n_litter_mineralization",
    "nSoilMineralization" => "diagnostic__n_soil_mineralization",
    "nSoilImmob" => "diagnostic__n_soil_immobilization",
    "nNetMineralization" => "diagnostic__n_net_mineralization",
    "nLitInptMet" => "diagnostic__n_litter_metabolic_input",
    "nLitInptStruc" => "diagnostic__n_litter_structural_input",
)

function historical_variables()
    stocks = (
        reference_name => (
            native_name = native_workflow().output_name(component, variable),
            scale = 1000.0,
        ) for (reference_name, (component, variable)) in STOCK_VARIABLES
    )
    fluxes = (
        reference_name =>
            (native_name, scale = 1000.0 * native_casa().DAY_SECONDS) for
        (reference_name, native_name) in FLUX_VARIABLES
    )
    return (stocks..., fluxes...)
end

function casa_cn_diagnostics(soil_parameters)
    flux(name, long_name, compute) =
        (; name, long_name, units = "kg N m-2 s-1", compute)
    return (
        native_casa().casa_diagnostics(soil_parameters)...,
        flux(
            "diagnostic__n_deposition",
            "mineral nitrogen deposition",
            (_, p) -> p.casa_soil.nitrogen_deposition,
        ),
        flux(
            "diagnostic__n_fixation",
            "mineral nitrogen fixation",
            (_, p) -> p.casa_soil.nitrogen_fixation,
        ),
        flux(
            "diagnostic__n_plant_uptake",
            "plant mineral nitrogen uptake",
            (_, p) -> p.nitrogen_plant_uptake,
        ),
        flux(
            "diagnostic__n_leaching",
            "mineral nitrogen leaching",
            (_, p) -> getindex.(p.casa_soil.nitrogen_fluxes, 13),
        ),
        flux(
            "diagnostic__n_gaseous_loss",
            "gaseous mineral nitrogen loss",
            (_, p) -> getindex.(p.casa_soil.nitrogen_fluxes, 12),
        ),
        flux(
            "diagnostic__n_litter_mineralization",
            "litter nitrogen mineralization",
            (_, p) -> getindex.(p.casa_soil.nitrogen_fluxes, 8),
        ),
        flux(
            "diagnostic__n_soil_mineralization",
            "soil nitrogen mineralization",
            (_, p) -> getindex.(p.casa_soil.nitrogen_fluxes, 9),
        ),
        flux(
            "diagnostic__n_soil_immobilization",
            "soil nitrogen immobilization",
            (_, p) -> getindex.(p.casa_soil.nitrogen_fluxes, 10),
        ),
        flux(
            "diagnostic__n_net_mineralization",
            "net nitrogen mineralization",
            (_, p) -> getindex.(p.casa_soil.nitrogen_fluxes, 11),
        ),
        flux(
            "diagnostic__n_litter_metabolic_input",
            "metabolic litter nitrogen input",
            (_, p) -> p.nitrogen_litter_metabolic_input,
        ),
        flux(
            "diagnostic__n_litter_structural_input",
            "structural and CWD litter nitrogen input",
            (_, p) ->
                p.nitrogen_litter_structural_input .+
                p.nitrogen_litter_cwd_input,
        ),
    )
end

# =============================================================================
# Stage-boundary comparisons
# =============================================================================

const BOUNDARY_VARIABLES = (
    native_casa().BOUNDARY_VARIABLES...,
    "casapool%nplant(LEAF)" => (:casa_plant, :n_leaf),
    "casapool%nplant(WOOD)" => (:casa_plant, :n_wood),
    "casapool%nplant(FROOT)" => (:casa_plant, :n_fine_root),
    "casapool%nlitter(METB)" => (:casa_soil, :n_litter_metabolic),
    "casapool%nlitter(STR)" => (:casa_soil, :n_litter_structural),
    "casapool%nlitter(CWD)" => (:casa_soil, :n_litter_cwd),
    "casapool%nsoil(MIC)" => (:casa_soil, :n_soil_microbial),
    "casapool%nsoil(SLOW)" => (:casa_soil, :n_soil_slow),
    "casapool%nsoil(PASS)" => (:casa_soil, :n_soil_passive),
    "casapool%nsoilmin" => (:casa_soil, :n_mineral),
)

const BOOKKEEPING_VARIABLES = (
    "casabal%Fcnppyear",
    "casabal%FCrsyear",
    "casabal%FCneeyear",
    "casabal%FCrpyear",
    "casabal%FNdepyear",
    "casabal%FNfixyear",
    "casabal%FNsnetyear",
    "casabal%FNupyear",
    "casabal%FNleachyear",
    "casabal%FNlossyear",
)

struct BoundaryBookkeeping
    values::Dict{String, Vector{Float64}}
end

BoundaryBookkeeping(points) = BoundaryBookkeeping(
    Dict(name => zeros(points) for name in BOOKKEEPING_VARIABLES),
)

function reset_bookkeeping!(bookkeeping)
    foreach(values(bookkeeping.values)) do value
        fill!(value, 0)
    end
    return bookkeeping
end

function accumulate_bookkeeping!(bookkeeping, step, p)
    mod1(step, 365) == 1 && reset_bookkeeping!(bookkeeping)
    plant_carbon = parent(p.casa_plant.carbon_fluxes)
    soil_carbon = parent(p.casa_soil.carbon_fluxes)
    soil_nitrogen = parent(p.casa_soil.nitrogen_fluxes)
    deposition = parent(p.casa_soil.nitrogen_deposition)
    fixation = parent(p.casa_soil.nitrogen_fixation)
    uptake = parent(p.nitrogen_plant_uptake)
    scale = 1000 * native_casa().DAY_SECONDS
    values = bookkeeping.values
    for point in eachindex(values["casabal%Fcnppyear"])
        npp = plant_carbon[1, 1, 15, point]
        soil_respiration = soil_carbon[1, 1, 7, point]
        values["casabal%Fcnppyear"][point] += scale * npp
        values["casabal%FCrsyear"][point] += scale * soil_respiration
        values["casabal%FCneeyear"][point] += scale * (npp - soil_respiration)
        values["casabal%FCrpyear"][point] +=
            scale * plant_carbon[1, 1, 16, point]
        values["casabal%FNdepyear"][point] += scale * deposition[1, 1, 1, point]
        values["casabal%FNfixyear"][point] += scale * fixation[1, 1, 1, point]
        values["casabal%FNsnetyear"][point] +=
            scale * soil_nitrogen[1, 1, 11, point]
        values["casabal%FNupyear"][point] += scale * uptake[1, 1, 1, point]
        values["casabal%FNleachyear"][point] +=
            scale * soil_nitrogen[1, 1, 13, point]
        values["casabal%FNlossyear"][point] +=
            scale * soil_nitrogen[1, 1, 12, point]
    end
    return bookkeeping
end

function compare_boundary_csv(Y, path; atol = 0.0, rtol = 0.0)
    columns, data = native_casa().read_boundary_csv(path)
    metrics = Dict{String, Any}()
    for (reference_name, (component, variable)) in BOUNDARY_VARIABLES
        haskey(columns, reference_name) ||
            error("CASA-CN boundary is missing $reference_name: $path")
        actual =
            1000 .*
            vec(Array(parent(getproperty(getproperty(Y, component), variable))))
        expected =
            [parse(Float64, row[columns[reference_name]]) for row in data]
        metrics[reference_name] =
            native_casa().error_metrics(actual, expected; atol, rtol)
    end
    return Dict(
        "reference" => abspath(path),
        "points" => length(data),
        "variable" => metrics,
        "all_match" => all(metric["all_match"] for metric in values(metrics)),
    )
end

function compare_bookkeeping_csv(bookkeeping, path; atol = 0.0, rtol = 0.0)
    columns, data = native_casa().read_boundary_csv(path)
    metrics = Dict{String, Any}()
    for reference_name in BOOKKEEPING_VARIABLES
        haskey(columns, reference_name) ||
            error("CASA-CN bookkeeping is missing $reference_name: $path")
        expected =
            [parse(Float64, row[columns[reference_name]]) for row in data]
        metrics[reference_name] = native_casa().error_metrics(
            bookkeeping.values[reference_name],
            expected;
            atol,
            rtol,
        )
    end
    return Dict(
        "reference" => abspath(path),
        "points" => length(data),
        "variable" => metrics,
        "all_match" => all(metric["all_match"] for metric in values(metrics)),
    )
end

# =============================================================================
# Historical-output comparisons
# =============================================================================

function require_variables(dataset, path)
    missing =
        [name for (name, _) in historical_variables() if !haskey(dataset, name)]
    isempty(missing) ||
        error("CASA-CN reference is missing $(join(missing, ", ")): $path")
    return dataset
end

function compare_annual(native_output, reference_path, grid; atol, rtol)
    return NCDatasets.NCDataset(native_output) do native
        NCDatasets.NCDataset(reference_path) do reference
            require_variables(reference, reference_path)
            report = Dict{String, Any}()
            for (reference_name, variable) in historical_variables()
                aggregate = native_casa().empty_aggregate(atol, rtol)
                reference_values = native_casa().reference_points(
                    reference[reference_name],
                    grid,
                    Colon(),
                )
                for year_index in axes(reference_values, 2)
                    days = ((year_index - 1) * 365 + 1):(year_index * 365)
                    native_mean = vec(
                        sum(native[variable.native_name][:, days]; dims = 2) ./ 365,
                    )
                    metric = native_casa().error_metrics(
                        variable.scale .* native_mean,
                        view(reference_values, :, year_index);
                        atol,
                        rtol,
                    )
                    native_casa().merge_metrics!(aggregate, metric)
                end
                report[reference_name] = aggregate
            end
            return Dict(
                "reference" => abspath(reference_path),
                "variable" => report,
                "all_match" =>
                    all(metric["all_match"] for metric in values(report)),
            )
        end
    end
end

function compare_daily(
    native_output,
    reference_path,
    grid,
    native_days;
    atol,
    rtol,
)
    return NCDatasets.NCDataset(native_output) do native
        NCDatasets.NCDataset(reference_path) do reference
            require_variables(reference, reference_path)
            report = Dict{String, Any}()
            for (reference_name, variable) in historical_variables()
                actual =
                    variable.scale .*
                    native[variable.native_name][:, native_days]
                expected = native_casa().reference_points(
                    reference[reference_name],
                    grid,
                    Colon(),
                )
                report[reference_name] =
                    native_casa().error_metrics(actual, expected; atol, rtol)
            end
            return Dict(
                "reference" => abspath(reference_path),
                "variable" => report,
                "all_match" =>
                    all(metric["all_match"] for metric in values(report)),
            )
        end
    end
end

function find_reference(root, filenames)
    for filename in filenames
        path = joinpath(root, filename)
        isfile(path) && return path
    end
    error(
        "CASA-CN reference is missing; checked $(join(filenames, ", ")) under $root",
    )
end

function compare_yearly_daily(native_output, grid, root, years; atol, rtol)
    report = Dict(
        name => native_casa().empty_aggregate(atol, rtol) for
        (name, _) in historical_variables()
    )
    references = String[]
    for year in years
        filename = "casaclm_pool_flux_$(year)_daily.nc"
        path = find_reference(root, (filename, joinpath("HIST", filename)))
        push!(references, abspath(path))
        native_days = ((year - 1901) * 365 + 1):((year - 1900) * 365)
        comparison =
            compare_daily(native_output, path, grid, native_days; atol, rtol)
        for (name, metric) in comparison["variable"]
            native_casa().merge_metrics!(report[name], metric)
        end
    end
    return Dict(
        "reference" => references,
        "years" => collect(years),
        "variable" => report,
        "all_match" => all(metric["all_match"] for metric in values(report)),
    )
end

function compare_source(native_output, grid, root, source; atol, rtol)
    annual_name = "ann_casaclm_pool_flux_1901_2014.nc"
    annual = compare_annual(
        native_output,
        find_reference(root, (annual_name, joinpath("HIST", annual_name))),
        grid;
        atol,
        rtol,
    )
    daily = Dict{String, Any}()
    for (label, years) in (("1901_1905", 1901:1905), ("2010_2014", 2010:2014))
        combined = "casaclm_pool_flux_$(first(years))_$(last(years))_daily.nc"
        paths = (joinpath(root, combined), joinpath(root, "HIST", combined))
        path = findfirst(isfile, paths)
        if isnothing(path)
            daily[label] = compare_yearly_daily(
                native_output,
                grid,
                root,
                years;
                atol,
                rtol,
            )
        else
            native_days =
                ((first(years) - 1901) * 365 + 1):((last(years) - 1900) * 365)
            daily[label] = compare_daily(
                native_output,
                paths[path],
                grid,
                native_days;
                atol,
                rtol,
            )
        end
    end
    return Dict(
        "source" => source,
        "tolerance" => Dict("atol" => atol, "rtol" => rtol),
        "annual" => annual,
        "daily" => daily,
        "all_match" =>
            annual["all_match"] && all(x["all_match"] for x in values(daily)),
    )
end

function compare_historical_outputs(
    native_output,
    grid,
    fresh_fortran_root,
    archive_root;
    fresh_atol,
    fresh_rtol,
    archive_atol,
    archive_rtol,
)
    return Dict(
        "output" => Dict("records" => 114 * 365),
        "fresh_fortran" => compare_source(
            native_output,
            grid,
            fresh_fortran_root,
            "fresh_fortran";
            atol = fresh_atol,
            rtol = fresh_rtol,
        ),
        "published_archive" => compare_source(
            native_output,
            grid,
            archive_root,
            "published_archive";
            atol = archive_atol,
            rtol = archive_rtol,
        ),
    )
end

# =============================================================================
# Full gridded workflow
# =============================================================================

function gridded_provenance(stage, parameter_path, reference_root)
    stage_directory = Dict(
        :prespin => "01-prespin",
        :accelerated_spin => "02-accelerated_spin",
        :normal_spin => "03-normal_spin",
        :historical => "04-historical",
    )[stage.name]
    metadata = joinpath(
        reference_root,
        "stages",
        stage_directory,
        "stage_metadata.toml",
    )
    return Dict(
        "model" => "ClimaLand integrated CASA carbon-nitrogen",
        "configuration" => "issue-30 4,263-point gridded reconstruction",
        "pft" => "IGBP 1:18 in pinned grid order",
        "execution" => Dict(
            "julia_threads" => Threads.nthreads(),
            "blas_threads" => LinearAlgebra.BLAS.get_num_threads(),
        ),
        "parameter_file" => Dict(
            "source" => abspath(parameter_path),
            "sha256" => native_workflow().sha256sum(parameter_path),
        ),
        "forcing" => [
            Dict(
                "stage" => String(stage.name),
                "source" => "pinned GSWP3/CLM5 yearly files; manifest $(abspath(metadata))",
                "sha256" => native_workflow().sha256sum(metadata),
            ),
        ],
    )
end

function exudation_report(normal, accelerated)
    fractions(model) = vec(
        Array(
            parent(
                selected_casa().PlantCASA.root_exudate_fraction.(
                    model.casa_plant.parameters,
                ),
            ),
        ),
    )
    return Dict(
        "normal_all_zero" => all(iszero, fractions(normal.model)),
        "accelerated_all_zero" => all(iszero, fractions(accelerated.model)),
    )
end

function augment_report!(path, normal, accelerated, tolerances)
    report = TOML.parsefile(path)
    report["scientific_configuration"] = Dict(
        "mineral_nitrogen_owner" => "casa_soil.n_mineral",
        "native_checkpoint_handoff" => true,
        "cwd_nitrogen" => "casa_soil.n_litter_cwd with structural-input bookkeeping",
        "passive_pool_transformation" => "casa_soil.c_soil_passive and casa_soil.n_soil_passive multiplied by 10",
        "root_exudation" => exudation_report(normal, accelerated),
    )
    report["comparison_tolerance"] = tolerances
    open(path, "w") do io
        TOML.print(io, report; sorted = true)
    end
    return path
end

function require_acceptance!(path)
    report = TOML.parsefile(path)
    exudation = report["scientific_configuration"]["root_exudation"]
    checks = Dict(
        "normal root exudation" => exudation["normal_all_zero"],
        "accelerated root exudation" => exudation["accelerated_all_zero"],
        "boundary comparisons" => all(
            comparison["all_match"] for
            comparison in values(report["boundary_comparison"])
        ),
        "fresh Fortran comparison" =>
            report["historical_comparison"]["fresh_fortran"]["all_match"],
        "published archive comparison" =>
            report["historical_comparison"]["published_archive"]["all_match"],
        "carbon budget" => report["carbon_budget"]["all_close"],
        "nitrogen budget" => report["nitrogen_budget"]["all_close"],
    )
    failures = sort!([name for (name, passed) in checks if !passed])
    isempty(failures) || error(
        "CASA-CN reconstruction failed acceptance: $(join(failures, ", "))",
    )
    return path
end

struct GriddedCNForcingUpdate{F}
    forcing::F
end

function (callback::GriddedCNForcingUpdate)(stage, index, time)
    return native_casa().update_forcing!(callback.forcing, stage, index, time)
end

struct GriddedCNAfterStep{B, K}
    budget::B
    bookkeeping::K
end

function (callback::GriddedCNAfterStep)(stage, step, _, p, _)
    selected_casa().accumulate_budget!(
        callback.budget,
        :carbon_nitrogen,
        stage,
        p,
    )
    accumulate_bookkeeping!(callback.bookkeeping, step, p)
    return nothing
end

const REDUCED_SAMPLE_DAYS = sort!([
    (year - 1901) * 365 + start + offset for year in (1901, 1957, 2014) for
    start in (1, 91, 182, 274) for offset in 0:6
],)

mutable struct ReducedCNHistorical{D}
    diagnostics::D
    reference_name_by_diagnostic::Dict{String, String}
    annual_mean::Dict{String, Matrix{Float64}}
    end_of_year::Dict{String, Matrix{Float64}}
    annual_total::Dict{String, Matrix{Float64}}
    samples::Dict{String, Matrix{Float64}}
    sample_position::Dict{Int, Int}
end

function ReducedCNHistorical(point_count, soil_parameters)
    stocks = Dict(
        reference_name => zeros(point_count, 114) for
        (reference_name, _) in STOCK_VARIABLES
    )
    diagnostics = casa_cn_diagnostics(soil_parameters)
    reference_name_by_diagnostic =
        Dict(native_name => name for (name, native_name) in FLUX_VARIABLES)
    totals = Dict(
        reference_name_by_diagnostic[diagnostic.name] =>
            zeros(point_count, 114) for diagnostic in diagnostics
    )
    sample_names = (keys(stocks)..., keys(totals)...)
    return ReducedCNHistorical(
        diagnostics,
        reference_name_by_diagnostic,
        stocks,
        Dict(name => zeros(point_count, 114) for name in keys(stocks)),
        totals,
        Dict(
            name => zeros(point_count, length(REDUCED_SAMPLE_DAYS)) for
            name in sample_names
        ),
        Dict(day => index for (index, day) in enumerate(REDUCED_SAMPLE_DAYS)),
    )
end

field_values(field) = vec(parent(parent(field)))

function (tracker::ReducedCNHistorical)(stage, step, Y, p, _)
    stage.name == :historical || return nothing
    year = cld(step, 365)
    day = mod1(step, 365)
    sample = get(tracker.sample_position, step, 0)
    for (name, (component, variable)) in STOCK_VARIABLES
        values = field_values(getproperty(getproperty(Y, component), variable))
        view(tracker.annual_mean[name], :, year) .+= values
        day == 365 && (view(tracker.end_of_year[name], :, year) .= values)
        sample == 0 || (view(tracker.samples[name], :, sample) .= values)
    end
    for diagnostic in tracker.diagnostics
        name = tracker.reference_name_by_diagnostic[diagnostic.name]
        values = field_values(diagnostic.compute(Y, p))
        view(tracker.annual_total[name], :, year) .+=
            native_casa().DAY_SECONDS .* values
        sample == 0 || (view(tracker.samples[name], :, sample) .= values)
    end
    return nothing
end

function write_reduced_historical(path, tracker)
    mkpath(dirname(path))
    NCDatasets.NCDataset(path, "c") do output
        NCDatasets.defDim(
            output,
            "point",
            size(first(values(tracker.annual_mean)), 1),
        )
        NCDatasets.defDim(output, "year", 114)
        NCDatasets.defDim(output, "sample", length(REDUCED_SAMPLE_DAYS))
        NCDatasets.defVar(output, "year", Int, ("year",))[:] = 1901:2014
        NCDatasets.defVar(output, "sample_day", Int, ("sample",))[:] =
            REDUCED_SAMPLE_DAYS
        for (reducer, values) in (
            "annual_mean" => tracker.annual_mean,
            "end_of_year" => tracker.end_of_year,
            "annual_total" => tracker.annual_total,
            "fixed_daily_sample" => tracker.samples,
        )
            for (name, data) in values
                reducer == "annual_mean" && (data ./= 365)
                dimension = reducer == "fixed_daily_sample" ? "sample" : "year"
                variable = NCDatasets.defVar(
                    output,
                    "$(reducer)__$(name)",
                    Float64,
                    ("point", dimension);
                    deflatelevel = 1,
                )
                variable[:, :] = data
            end
        end
    end
    return path
end

"""
    run_gridded_case(source_root, forcing_root, reference_root, output_root; ...)

Run the pinned CASA-CN prespin, accelerated spin, normal spin, and historical
workflow on all 4,263 cells. `reference_root` is the completed issue-24 case
root. In addition to its `stages`, `candidates`, and `reference` directories,
it must contain `fresh_reference` with separately reduced annual and retained
daily fresh-Fortran products.
"""
function run_gridded_case(
    source_root,
    forcing_root,
    reference_root,
    output_root;
    boundary_atol = 5e-3,
    boundary_rtol = 1e-3,
    fresh_atol = 5e-3,
    fresh_rtol = 1e-3,
    archive_atol = 5e-3,
    archive_rtol = 1e-3,
    budget_rtol = 5e-12,
    boundary_only = false,
    resume_historical_checkpoint = nothing,
)
    isnothing(resume_historical_checkpoint) ||
        boundary_only ||
        error("CASA-CN historical recovery is calibration-only")
    isnothing(resume_historical_checkpoint) ||
        isfile(resume_historical_checkpoint) ||
        error("CASA-CN historical recovery checkpoint is missing")
    if boundary_only
        Threads.nthreads() == 1 ||
            error("CASA-CN calibration requires exactly one Julia thread")
        LinearAlgebra.BLAS.get_num_threads() == 1 ||
            error("CASA-CN calibration requires exactly one BLAS thread")
    end
    grid_path =
        joinpath(source_root, "GRID_CN", "gridinfo_igbpz_CLM5_GSWP3.csv")
    soil_path = joinpath(source_root, "GRID_CN", "gridinfo_soil_CLM5_GSWP3.csv")
    phenology_path =
        joinpath(source_root, "GRID_CN", "modis_phenology_wtundra.txt")
    prespin_path = joinpath(
        reference_root,
        "candidates",
        "parameters",
        "pftlookup_igbp_updated4_borealNfix.candidate.csv",
    )
    normal_path =
        joinpath(source_root, "GRID_CN", "pftlookup_igbp_updated4_exud0.csv")
    accelerated_path =
        joinpath(source_root, "GRID_CN", "pftlookup_igbp_updated4_exud0AD.csv")
    grid = native_casa().read_grid(grid_path)
    length(grid) == 4263 || error("Pinned CASA-CN grid must have 4,263 rows")
    soils = native_casa().read_soils(soil_path)
    domain = native_casa().gridded_domain(length(grid))
    buffers = native_casa().GriddedBuffers(domain)
    nitrogen_deposition =
        native_casa().scalar_field(domain, zeros(length(grid)))
    prespin = selected_casa().build_cn_model(
        grid,
        soils,
        prespin_path,
        buffers,
        nitrogen_deposition;
        domain,
        boreal_fixation = true,
    )
    normal = selected_casa().build_cn_model(
        grid,
        soils,
        normal_path,
        buffers,
        nitrogen_deposition;
        domain,
    )
    accelerated = selected_casa().build_cn_model(
        grid,
        soils,
        accelerated_path,
        buffers,
        nitrogen_deposition;
        domain,
    )
    all(values(exudation_report(normal, accelerated))) ||
        error("CASA-CN normal and accelerated root exudation must be zero")
    forcing = native_casa().GriddedForcing(
        grid,
        soils,
        normal.parameters,
        phenology_path,
        forcing_root,
        buffers;
        nitrogen_deposition,
    )
    model_for_stage(stage) =
        stage.name == :prespin ? prespin.model :
        stage.name == :accelerated_spin ? accelerated.model : normal.model
    parameter_for_stage(stage) =
        stage.name == :prespin ? prespin_path :
        stage.name == :accelerated_spin ? accelerated_path : normal_path
    boundary_directories = Dict(
        :prespin => "01-prespin",
        :accelerated_spin => "02-accelerated_spin",
        :normal_spin => "03-normal_spin",
        :historical => "04-historical",
    )
    budget = selected_casa().BudgetAccumulator(grid)
    bookkeeping = BoundaryBookkeeping(length(grid))
    reduced =
        boundary_only ?
        ReducedCNHistorical(length(grid), normal.model.casa_soil.parameters) :
        nothing
    function carbon_budget(stage, result, _, _, initial_state, model)
        boundary_only && return Dict("skipped" => "boundary calibration only")
        name = stage.name
        final_state = native_casa().state_as_initial_state(result.state, model)
        return selected_casa().budget_report(
            selected_casa().area_weighted_stock(
                initial_state,
                budget.area_m2,
                "c_",
            ),
            selected_casa().area_weighted_stock(
                final_state,
                budget.area_m2,
                "c_",
            ),
            budget.carbon_input[name],
            budget.carbon_output[name],
            "kg_c";
            adjustment = budget.carbon_bounded_adjustment[name],
            rtol = budget_rtol,
        )
    end
    function nitrogen_budget(stage, result, initial_state, model)
        boundary_only && return Dict("skipped" => "boundary calibration only")
        name = stage.name
        final_state = native_casa().state_as_initial_state(result.state, model)
        return selected_casa().budget_report(
            selected_casa().area_weighted_stock(
                initial_state,
                budget.area_m2,
                "n_",
            ),
            selected_casa().area_weighted_stock(
                final_state,
                budget.area_m2,
                "n_",
            ),
            budget.nitrogen_input[name],
            budget.nitrogen_output[name],
            "kg_n";
            adjustment = budget.nitrogen_bounded_adjustment[name],
            rtol = budget_rtol,
        )
    end
    function workflow_budget(
        carbon_stage_budgets,
        nitrogen_stage_budgets,
        passive_restoration,
    )
        boundary_only && return nothing
        return Dict(
            "carbon" => selected_casa().workflow_budget_report(
                carbon_stage_budgets,
                passive_restoration,
                budget.area_m2,
                "carbon";
                rtol = budget_rtol,
            ),
            "nitrogen" => selected_casa().workflow_budget_report(
                nitrogen_stage_budgets,
                passive_restoration,
                budget.area_m2,
                "nitrogen";
                rtol = budget_rtol,
            ),
        )
    end
    function compare_boundary(stage, result, _)
        directory =
            joinpath(reference_root, "stages", boundary_directories[stage.name])
        state = compare_boundary_csv(
            result.state,
            joinpath(directory, "casa_final.csv");
            atol = boundary_atol,
            rtol = boundary_rtol,
        )
        balance =
            boundary_only ? Dict("skipped" => "boundary calibration only") :
            compare_bookkeeping_csv(
                bookkeeping,
                joinpath(directory, "casa_flux_final.csv");
                atol = boundary_atol,
                rtol = boundary_rtol,
            )
        return Dict(
            "state" => state,
            "bookkeeping" => balance,
            "all_match" =>
                state["all_match"] && (boundary_only || balance["all_match"]),
        )
    end
    tolerances = Dict(
        "boundary" =>
            Dict("atol" => boundary_atol, "rtol" => boundary_rtol),
        "fresh_fortran" => Dict("atol" => fresh_atol, "rtol" => fresh_rtol),
        "published_archive" =>
            Dict("atol" => archive_atol, "rtol" => archive_rtol),
    )
    try
        active_stages =
            isnothing(resume_historical_checkpoint) ? COMPLETE_STAGES :
            (last(COMPLETE_STAGES),)
        initial_state = if isnothing(resume_historical_checkpoint)
            selected_casa().gridded_cn_initial_state(
                prespin.model,
                grid,
                prespin_path,
            )
        else
            checkpoint_state, _ = native_casa().ClimaLand.read_checkpoint(
                resume_historical_checkpoint;
                model = normal.model,
            )
            native_casa().state_as_initial_state(checkpoint_state, normal.model)
        end
        result = native_casa().run_case(
            initial_state,
            active_stages,
            output_root;
            model_for_stage,
            update_forcing! = GriddedCNForcingUpdate(forcing),
            after_step! = boundary_only ? reduced :
                          GriddedCNAfterStep(budget, bookkeeping),
            diagnostics = boundary_only ? () :
                          casa_cn_diagnostics(
                normal.model.casa_soil.parameters,
            ),
            provenance = stage -> gridded_provenance(
                stage,
                parameter_for_stage(stage),
                reference_root,
            ),
            compare_boundary,
            compare_historical = boundary_only ?
                                 (_, _) -> Dict(
                "output" => Dict("records" => 0),
                "skipped" => "boundary calibration only",
            ) :
                                 (path, _) -> compare_historical_outputs(
                path,
                grid,
                joinpath(reference_root, "fresh_reference"),
                joinpath(reference_root, "reference");
                fresh_atol,
                fresh_rtol,
                archive_atol,
                archive_rtol,
            ),
            carbon_budget,
            nitrogen_budget,
            workflow_budget,
            restore_passive! = selected_casa().restore_passive_carbon_nitrogen!,
            output_eltype = Float32,
            deflatelevel = 1,
        )
        if !boundary_only
            augment_report!(result.report, normal, accelerated, tolerances)
            require_acceptance!(result.report)
        else
            write_reduced_historical(
                joinpath(output_root, "reduced_historical.nc"),
                reduced,
            )
        end
        return result
    finally
        native_casa().close_forcing!(forcing)
    end
end

# =============================================================================
# Synthetic acceptance fixture and command-line entrypoint
# =============================================================================

function split_historical_comparison!(report_path)
    report = TOML.parsefile(report_path)
    comparison = get(report, "historical_comparison", Dict{String, Any}())
    skipped = get(comparison, "skipped", "synthetic reference comparison")
    report["historical_comparison"] = Dict(
        "fresh_fortran" =>
            Dict("source" => "fresh_fortran", "skipped" => skipped),
        "published_archive" =>
            Dict("source" => "published_archive", "skipped" => skipped),
    )
    open(report_path, "w") do io
        TOML.print(io, report; sorted = true)
    end
    return report_path
end

"""Exercise the full CASA-CN handoff contract on the pinned tiny fixture."""
function run_synthetic_case(output_root)
    stages = (
        native_workflow().NativeStage(:prespin, 2, 1; write_output = false),
        native_workflow().NativeStage(
            :accelerated_spin,
            2,
            1;
            write_output = false,
        ),
        native_workflow().NativeStage(:normal_spin, 2, 1; write_output = false),
        native_workflow().NativeStage(:historical, 2, 1),
    )
    result = selected_casa().run_selected_case(
        output_root;
        configuration = :carbon_nitrogen,
        stages,
        compare_references = false,
        diagnostics = setup ->
            casa_cn_diagnostics(setup.normal.model.casa_soil.parameters),
    )
    split_historical_comparison!(result.report)
    return result
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 4 || error(
        "usage: native_casa_cn_reconstruction.jl SOURCE_ROOT FORCING_ROOT REFERENCE_ROOT OUTPUT_ROOT",
    )
    TestbedNativeCASACNReconstruction.run_gridded_case(ARGS...)
end
