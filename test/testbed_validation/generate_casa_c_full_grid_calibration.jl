import ClimaLand
import NCDatasets
import SHA
import Statistics
import TOML

const STAGES = (
    ("prespin", "01-prespin"),
    ("accelerated_spin", "02-accelerated_spin"),
    ("normal_spin", "03-normal_spin"),
    ("historical", "04-historical"),
)

const BOUNDARY_VARIABLES = (
    "casapool%clabile" => ("casa_plant", "c_labile"),
    "casapool%cplant(LEAF)" => ("casa_plant", "c_leaf"),
    "casapool%cplant(WOOD)" => ("casa_plant", "c_wood"),
    "casapool%cplant(FROOT)" => ("casa_plant", "c_fine_root"),
    "casapool%clitter(METB)" => ("casa_soil", "c_litter_metabolic"),
    "casapool%clitter(STR)" => ("casa_soil", "c_litter_structural"),
    "casapool%clitter(CWD)" => ("casa_soil", "c_litter_cwd"),
    "casapool%csoil(MIC)" => ("casa_soil", "c_soil_microbial"),
    "casapool%csoil(SLOW)" => ("casa_soil", "c_soil_slow"),
    "casapool%csoil(PASS)" => ("casa_soil", "c_soil_passive"),
)

sha256sum(path) = bytes2hex(SHA.sha256(read(path)))

function csv_table(path)
    lines = readlines(path)
    header = strip.(split(first(lines), ','))
    columns = Dict(name => index for (index, name) in enumerate(header))
    rows = [strip.(split(line, ',')) for line in lines[2:end]]
    return columns, rows
end

function grid_metadata(path)
    columns, rows = csv_table(path)
    return [
        (
            cell_id = parse(Int, row[columns["ijcam"]]),
            pft = parse(Int, row[columns["ivt_igbp"]]),
            latitude = parse(Float64, row[columns["lat"]]),
            longitude = parse(Float64, row[columns["lon"]]),
        ) for row in rows
    ]
end

function checkpoint_path(output_root, stage)
    stage_root = joinpath(output_root, "stages", stage)
    manifest_path = joinpath(stage_root, "workflow.toml")
    manifest = TOML.parsefile(manifest_path)
    entries = manifest["stage"]
    length(entries) == 1 || error("expected one stage in $manifest_path")
    return joinpath(stage_root, entries[1]["checkpoint"]), manifest_path
end

function checkpoint_values(path, component, variable)
    hdf5 = ClimaLand.InputOutput.HDF5
    return hdf5.h5open(path, "r") do file
        vec(hdf5.read(file["fields/Y/$component/$variable"]))
    end
end

function fortran_values(path, reference_name)
    columns, rows = csv_table(path)
    index = columns[reference_name]
    # The archived Fortran boundary CSVs use g C m^-2; ClimaLand uses kg C m^-2.
    return [parse(Float64, row[index]) / 1000 for row in rows]
end

function right_derivative(r, errors, references, mean_reference)
    maximum_value = 0.0
    maximum_slope = mean_reference
    for index in eachindex(errors, references)
        residual = errors[index] - r * references[index]
        if residual > maximum_value
            maximum_value = residual
            maximum_slope = mean_reference - references[index]
        elseif residual == maximum_value
            maximum_slope =
                max(maximum_slope, mean_reference - references[index])
        end
    end
    return maximum_slope
end

function calibrated_envelope(errors, references; numerical_scale)
    numerical_padding = 64eps(Float64) * max(numerical_scale, floatmin(Float64))
    mean_reference = Statistics.mean(references)
    relative = 0.0
    if right_derivative(relative, errors, references, mean_reference) < 0
        upper = eps(Float64)
        while right_derivative(upper, errors, references, mean_reference) < 0
            upper *= 2
            isfinite(upper) ||
                error("unable to bracket calibrated relative tolerance")
        end
        lower = 0.0
        for _ in 1:80
            middle = (lower + upper) / 2
            if right_derivative(middle, errors, references, mean_reference) < 0
                lower = middle
            else
                upper = middle
            end
        end
        relative = upper
    end
    absolute = max(0.0, maximum(errors .- relative .* references))
    atol = 1.05absolute + numerical_padding
    rtol = 1.05relative
    all(errors .<= atol .+ rtol .* references) ||
        error("calibrated tolerance does not enclose every full-grid pair")
    return (;
        atol,
        rtol,
        raw_atol = absolute,
        raw_rtol = relative,
        numerical_padding,
    )
end

function distribution(values)
    return Dict(
        "minimum" => minimum(values),
        "median" => Statistics.median(values),
        "p90" => Statistics.quantile(values, 0.90),
        "p95" => Statistics.quantile(values, 0.95),
        "p99" => Statistics.quantile(values, 0.99),
        "p999" => Statistics.quantile(values, 0.999),
        "maximum" => maximum(values),
        "mean" => Statistics.mean(values),
    )
end

function calibration_record(actual, expected, contexts; units)
    length(actual) == length(expected) == length(contexts) ||
        error("full-grid calibration requires aligned cell pairs")
    all(isfinite, actual) ||
        error("eligible Julia full-grid boundary contains a nonfinite value")
    all(isfinite, expected) ||
        error("eligible Fortran full-grid boundary contains a nonfinite value")

    references = abs.(expected)
    errors = abs.(actual .- expected)
    nonzero_reference = findall(!iszero, references)
    relative_errors = errors[nonzero_reference] ./ references[nonzero_reference]
    relative_distribution = Dict{String, Any}(
        "defined_pair_count" => length(relative_errors),
        "undefined_zero_reference_count" =>
            length(references) - length(relative_errors),
    )
    isempty(relative_errors) ||
        merge!(relative_distribution, distribution(relative_errors))
    envelope = calibrated_envelope(
        errors,
        references;
        numerical_scale = max(maximum(abs, actual), maximum(abs, expected)),
    )
    residuals = errors .- envelope.raw_rtol .* references
    maximum_residual = maximum(residuals)
    active_tolerance = 256eps(Float64) * max(1.0, abs(maximum_residual))
    active =
        maximum_residual + active_tolerance >= 0 ?
        findall(
            residual -> isapprox(
                residual,
                maximum_residual;
                atol = active_tolerance,
                rtol = 0,
            ),
            residuals,
        ) : Int[]
    active_sample = [
        Dict(
            "cell_id" => contexts[index].cell_id,
            "pft" => contexts[index].pft,
            "latitude" => contexts[index].latitude,
            "longitude" => contexts[index].longitude,
            (
                string(name) => value for
                (name, value) in pairs(contexts[index]) if
                name ∉ (:cell_id, :pft, :latitude, :longitude)
            )...,
            "objective_slope" =>
                Statistics.mean(references) - references[index],
        ) for index in Iterators.take(active, 6)
    ]
    order = sortperm(errors; rev = true)
    outliers = [
        Dict(
            "rank" => rank,
            "cell_id" => contexts[index].cell_id,
            "pft" => contexts[index].pft,
            "latitude" => contexts[index].latitude,
            "longitude" => contexts[index].longitude,
            (
                string(name) => value for
                (name, value) in pairs(contexts[index]) if
                name ∉ (:cell_id, :pft, :latitude, :longitude)
            )...,
            "julia_value" => actual[index],
            "fortran_value" => expected[index],
            "absolute_error" => errors[index],
            "relative_error" =>
                iszero(references[index]) ? "undefined_zero_reference" :
                errors[index] / references[index],
        ) for (rank, index) in enumerate(order[1:6])
    ]
    return Dict(
        "finite_pair_count" => length(errors),
        "units" => units,
        "absolute_error" => distribution(errors),
        "relative_error" => relative_distribution,
        "absolute_reference" => distribution(references),
        "active_constraint_count" => length(active),
        "active_constraint_sample" => active_sample,
        "nonnegative_absolute_constraint_active" => isapprox(
            0.0,
            max(0.0, maximum_residual);
            atol = active_tolerance,
            rtol = 0,
        ),
        "active_constraint" =>
            isempty(active) ? "nonnegative_absolute_bound" : "cell_pair",
        "top_outlier" => outliers,
        "derived_policy" => Dict(
            "atol" => envelope.atol,
            "rtol" => envelope.rtol,
            "raw_atol" => envelope.raw_atol,
            "raw_rtol" => envelope.raw_rtol,
            "numerical_padding" => envelope.numerical_padding,
            "raw_objective" =>
                envelope.raw_atol +
                envelope.raw_rtol * Statistics.mean(references),
            "validation_failed_pairs" => count(
                errors .> envelope.atol .+ envelope.rtol .* references,
            ),
        ),
    )
end

function source_file_record(path, id)
    return Dict("id" => id, "sha256" => sha256sum(path))
end

function generate(
    output_root,
    fortran_root,
    output_path;
    execution_revision = "HEAD",
    boundary_variables = BOUNDARY_VARIABLES,
    calibration_id = "casa-c-fresh-fortran-full-grid-v1",
    units = "kg C m^-2",
    model_source = "native_casa_c_reconstruction.jl",
    annual_variables = (),
    daily_variables = (),
    additional_sources = (),
)
    stage_root = joinpath(fortran_root, "stages")
    grid_path = joinpath(stage_root, "01-prespin", "grid.csv")
    grid = grid_metadata(grid_path)
    length(grid) == 4263 ||
        error("Fortran grid must contain exactly 4,263 cells")

    variables = Dict{String, Any}()
    julia_sources = Dict{String, Any}()
    fortran_sources = Dict{String, Any}()
    for (stage, fortran_stage) in STAGES
        checkpoint, workflow = checkpoint_path(output_root, stage)
        fortran_stage_root = joinpath(stage_root, fortran_stage)
        fortran_boundary = joinpath(fortran_stage_root, "casa_final.csv")
        julia_sources[stage] = Dict(
            "checkpoint" => source_file_record(
                checkpoint,
                "julia/$stage/final_checkpoint.hdf5",
            ),
            "workflow" =>
                source_file_record(workflow, "julia/$stage/workflow.toml"),
        )
        fortran_sources[stage] = Dict(
            name => source_file_record(
                joinpath(fortran_stage_root, filename),
                "fortran/stages/$fortran_stage/$filename",
            ) for (name, filename) in (
                "boundary" => "casa_final.csv",
                "metadata" => "stage_metadata.toml",
                "parameters" => "casa_parameters.csv",
                "grid" => "grid.csv",
                "soil" => "soil.csv",
                "phenology" => "phenology.txt",
            )
        )
        stage_records = Dict{String, Any}()
        for (reference_name, specification) in boundary_variables
            component, variable = specification[1:2]
            quantity = length(specification) == 3 ? specification[3] : "c"
            actual = checkpoint_values(checkpoint, component, variable)
            expected = fortran_values(fortran_boundary, reference_name)
            stage_records["$component.$variable"] = calibration_record(
                actual,
                expected,
                grid;
                units = "kg $(uppercase(quantity)) m^-2",
            )
        end
        variables[stage] = stage_records
    end
    annual = Dict{String, Any}()
    daily = Dict{String, Any}()
    annual_sources = Dict{String, Any}()
    daily_sources = Dict{String, Any}()
    if !isempty(annual_variables)
        reduced_path = joinpath(output_root, "reduced_historical.nc")
        fortran_path = joinpath(
            fortran_root,
            "fresh_reference",
            "ann_casaclm_pool_flux_1901_2014.nc",
        )
        annual_sources = Dict(
            "julia_reduced_historical" => source_file_record(
                reduced_path,
                "julia/reduced_historical.nc",
            ),
            "fresh_fortran_annual" => source_file_record(
                fortran_path,
                "fortran/fresh_reference/ann_casaclm_pool_flux_1901_2014.nc",
            ),
        )
        NCDatasets.NCDataset(reduced_path) do julia
            NCDatasets.NCDataset(fortran_path) do fortran
                cell_ids = vec(Int.(Array(fortran["cellid"])))
                positions =
                    Dict(id => index for (index, id) in enumerate(cell_ids))
                indices = [positions[cell.cell_id] for cell in grid]
                annual_contexts = [
                    merge(cell, (; year)) for year in 1901:2014 for cell in grid
                ]
                for (reference_name, native_name, reducer, quantity) in
                    annual_variables
                    actual = vec(Array(julia["$(reducer)__$(reference_name)"]))
                    raw = reshape(
                        Array(fortran[reference_name]),
                        length(cell_ids),
                        114,
                    )
                    expected = vec(raw[indices, :])
                    any(ismissing, expected) &&
                        error("eligible fresh-Fortran annual value is missing")
                    expected =
                        reducer == "annual_total" ?
                        Float64.(expected) .* 365 ./ 1000 :
                        Float64.(expected) ./ 1000
                    annual["$reducer.$native_name"] = calibration_record(
                        actual,
                        expected,
                        annual_contexts;
                        units = reducer == "annual_total" ?
                                "kg $(uppercase(quantity)) m^-2 year^-1" :
                                "kg $(uppercase(quantity)) m^-2",
                    )
                end
            end
        end
    end
    if !isempty(daily_variables)
        reduced_path = joinpath(output_root, "reduced_historical.nc")
        sample_columns = [collect(1:28); collect(57:84)]
        daily_samples = [
            (
                year = year,
                day_of_year = day,
                sample_day = (year - 1901) * 365 + day,
            ) for year in (1901, 2014) for day in [
                collect(1:7)
                collect(91:97)
                collect(182:188)
                collect(274:280)
            ]
        ]
        daily_contexts =
            [merge(cell, sample) for sample in daily_samples for cell in grid]
        daily_paths = Dict(
            year => joinpath(
                fortran_root,
                "stages",
                "04-historical",
                "casaclm_pool_flux_$(year)_daily.nc",
            ) for year in (1901, 2014)
        )
        daily_sources = Dict(
            "julia_reduced_historical" => source_file_record(
                reduced_path,
                "julia/reduced_historical.nc",
            ),
            "fresh_fortran_daily" => Dict(
                string(year) => source_file_record(
                    path,
                    "fortran/stages/04-historical/$(basename(path))",
                ) for (year, path) in daily_paths
            ),
        )
        NCDatasets.NCDataset(reduced_path) do julia
            for (reference_name, native_name, _, quantity) in daily_variables
                actual = vec(
                    Array(
                        julia["fixed_daily_sample__$(reference_name)"][
                            :,
                            sample_columns,
                        ],
                    ),
                )
                expected_years = Matrix{Float64}[]
                for year in (1901, 2014)
                    NCDatasets.NCDataset(daily_paths[year]) do fortran
                        ids = vec(Int.(Array(fortran["cellid"])))
                        positions =
                            Dict(id => index for (index, id) in enumerate(ids))
                        indices = [positions[cell.cell_id] for cell in grid]
                        raw = reshape(
                            Array(fortran[reference_name]),
                            length(ids),
                            365,
                        )
                        days = [
                            collect(1:7)
                            collect(91:97)
                            collect(182:188)
                            collect(274:280)
                        ]
                        values = Float64.(raw[indices, days])
                        startswith(native_name, "diagnostic.") &&
                            (values ./= 86400)
                        push!(expected_years, values ./ 1000)
                    end
                end
                expected = vec(hcat(expected_years...))
                daily[native_name] = calibration_record(
                    actual,
                    expected,
                    daily_contexts;
                    units = startswith(native_name, "diagnostic.") ?
                            "kg $(uppercase(quantity)) m^-2 s^-1" :
                            "kg $(uppercase(quantity)) m^-2",
                )
            end
        end
    end

    repo_root = normpath(joinpath(@__DIR__, "..", ".."))
    model_sources = Dict(
        relpath(path, repo_root) =>
            source_file_record(path, relpath(path, repo_root)) for path in (
            joinpath(@__DIR__, model_source),
            joinpath(@__DIR__, "native_workflow.jl"),
            joinpath(@__DIR__, "generate_casa_c_full_grid_calibration.jl"),
            (joinpath(@__DIR__, source) for source in additional_sources)...,
            joinpath(repo_root, "src", "integrated", "casa_biogeochemistry.jl"),
            joinpath(
                repo_root,
                "src",
                "standalone",
                "Soil",
                "Biogeochemistry",
                "casa.jl",
            ),
            joinpath(repo_root, "src", "standalone", "Vegetation", "casa.jl"),
        )
    )
    model_source_paths = sort!(collect(keys(model_sources)))
    model_diff = read(`git -C $repo_root diff -- $model_source_paths`, String)
    git_status = readchomp(`git -C $repo_root status --porcelain`)
    execution_revision =
        readchomp(`git -C $repo_root rev-parse $execution_revision`)
    manifest_revision = readchomp(`git -C $repo_root rev-parse HEAD`)
    recovery_path = joinpath(output_root, "historical_recovery.toml")
    historical_recovery = if isfile(recovery_path)
        detail = TOML.parsefile(recovery_path)
        get(detail, "schema_version", nothing) == 1 &&
            get(detail, "mode", nothing) == "historical_only" ||
            error("Historical recovery provenance is incompatible")
        Dict(
            "record" => source_file_record(
                recovery_path,
                "julia/historical_recovery.toml",
            ),
            "detail" => detail,
        )
    else
        Dict{String, Any}()
    end
    document = Dict(
        "schema_version" => 1,
        "calibration_id" => calibration_id,
        "source" => "fresh_fortran_full_grid",
        "cell_count" => 4263,
        "units" => units,
        "method" => Dict(
            "error" => "e_i = abs(Julia_i - Fortran_i)",
            "reference_magnitude" => "x_i = abs(Fortran_i)",
            "raw_absolute" => "a(r) = max(0, max_i(e_i - r*x_i))",
            "selection" => "choose the smallest r >= 0 minimizing a(r) + r*mean(x)",
            "safety_margin" => "multiply both observation-fitted raw coefficients by 1.05, then add 64*eps(Float64)*max(maximum(abs, Julia), maximum(abs, Fortran), floatmin(Float64)) to atol",
            "acceptance" => "e_i <= atol + rtol*x_i for every eligible pair",
            "nonfinite" => "fail calibration; exclusions require a reviewed scope-manifest gap",
        ),
        "source_provenance" => Dict(
            "git_revision_basis" => execution_revision,
            "git_head_at_manifest_generation" => manifest_revision,
            "git_head_advanced_during_run" =>
                execution_revision != manifest_revision,
            "git_dirty" => !isempty(git_status),
            "execution_source_dirty" => !isempty(model_diff),
            "execution_source_hashes_are_authoritative" => true,
            "revision_note" => "repository HEAD may advance concurrently; exact execution source is identified by the recorded source hashes and diff hash",
            "execution_source_diff_sha256" =>
                bytes2hex(SHA.sha256(model_diff)),
            "grid" => source_file_record(
                grid_path,
                "fortran/stages/01-prespin/grid.csv",
            ),
            "julia" => julia_sources,
            "fortran" => fortran_sources,
            "annual" => annual_sources,
            "daily" => daily_sources,
            "historical_recovery" => historical_recovery,
            "model_source" => model_sources,
        ),
        "variable" => variables,
        "annual_variable" => annual,
        "daily_variable" => daily,
    )
    mkpath(dirname(output_path))
    open(output_path, "w") do io
        TOML.print(io, document; sorted = true)
    end
    return output_path
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) in (3, 4) || error(
        "usage: generate_casa_c_full_grid_calibration.jl JULIA_OUTPUT FORTRAN_REFERENCE OUTPUT_TOML [EXECUTION_REVISION]",
    )
    println(
        generate(
            ARGS[1:3]...;
            execution_revision = length(ARGS) == 4 ? ARGS[4] : "HEAD",
        ),
    )
end
