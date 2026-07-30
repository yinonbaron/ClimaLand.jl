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

function right_derivative(r, errors, references, absolute_floor, mean_reference)
    maximum_value = absolute_floor
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

function calibrated_envelope(errors, references)
    absolute_floor = 5.0e-10 + 64eps(Float64)
    mean_reference = Statistics.mean(references)
    relative = 0.0
    if right_derivative(
        relative,
        errors,
        references,
        absolute_floor,
        mean_reference,
    ) < 0
        upper = eps(Float64)
        while right_derivative(
            upper,
            errors,
            references,
            absolute_floor,
            mean_reference,
        ) < 0
            upper *= 2
            isfinite(upper) ||
                error("unable to bracket calibrated relative tolerance")
        end
        lower = 0.0
        for _ in 1:80
            middle = (lower + upper) / 2
            if right_derivative(
                middle,
                errors,
                references,
                absolute_floor,
                mean_reference,
            ) < 0
                lower = middle
            else
                upper = middle
            end
        end
        relative = upper
    end
    absolute = max(absolute_floor, maximum(errors .- relative .* references))
    atol = 1.05absolute + 64eps(Float64)
    rtol = 1.05relative
    all(errors .<= atol .+ rtol .* references) ||
        error("calibrated tolerance does not enclose every full-grid pair")
    return (;
        atol,
        rtol,
        raw_atol = absolute,
        raw_rtol = relative,
        absolute_floor,
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

function calibration_record(actual, expected, grid; quantity = "c")
    length(actual) == length(expected) == length(grid) ||
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
    envelope = calibrated_envelope(errors, references)
    residuals = errors .- envelope.raw_rtol .* references
    maximum_residual = maximum(residuals)
    active_tolerance = 256eps(Float64) * max(1.0, abs(maximum_residual))
    active =
        maximum_residual + active_tolerance >= envelope.absolute_floor ?
        findall(
            residual -> isapprox(
                residual,
                maximum_residual;
                atol = active_tolerance,
                rtol = 0,
            ),
            residuals,
        ) : Int[]
    order = sortperm(errors; rev = true)
    outliers = [
        Dict(
            "rank" => rank,
            "cell_id" => grid[index].cell_id,
            "pft" => grid[index].pft,
            "julia_kg_$(quantity)_m2" => actual[index],
            "fortran_kg_$(quantity)_m2" => expected[index],
            "absolute_error_kg_$(quantity)_m2" => errors[index],
            "relative_error" =>
                iszero(references[index]) ? "undefined_zero_reference" :
                errors[index] / references[index],
        ) for (rank, index) in enumerate(order[1:6])
    ]
    return Dict(
        "finite_pair_count" => length(errors),
        "absolute_error_kg_$(quantity)_m2" => distribution(errors),
        "relative_error" => relative_distribution,
        "absolute_reference_kg_$(quantity)_m2" => distribution(references),
        "active_constraint_cell_ids" =>
            [grid[index].cell_id for index in active],
        "active_constraint_objective_slopes" => [
            Statistics.mean(references) - references[index] for index in active
        ],
        "floor_constraint_active" => isapprox(
            envelope.absolute_floor,
            max(envelope.absolute_floor, maximum_residual);
            atol = active_tolerance,
            rtol = 0,
        ),
        "active_constraint" => isempty(active) ? "absolute_floor" : "cell_pair",
        "top_outlier" => outliers,
        "derived_policy" => Dict(
            "atol" => envelope.atol,
            "rtol" => envelope.rtol,
            "raw_atol" => envelope.raw_atol,
            "raw_rtol" => envelope.raw_rtol,
            "absolute_floor" => envelope.absolute_floor,
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
            stage_records["$component.$variable"] =
                calibration_record(actual, expected, grid; quantity)
        end
        variables[stage] = stage_records
    end
    annual = Dict{String, Any}()
    annual_sources = Dict{String, Any}()
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
                repeated_grid = repeat(grid, 114)
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
                        repeated_grid;
                        quantity,
                    )
                end
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
    document = Dict(
        "schema_version" => 1,
        "calibration_id" => calibration_id,
        "source" => "fresh_fortran_full_grid",
        "cell_count" => 4263,
        "units" => units,
        "method" => Dict(
            "error" => "e_i = abs(Julia_i - Fortran_i)",
            "reference_magnitude" => "x_i = abs(Fortran_i)",
            "raw_absolute" => "a(r) = max(5e-10 in the declared variable units + 64eps(Float64), max_i(e_i - r*x_i))",
            "selection" => "choose the smallest r >= 0 minimizing a(r) + r*mean(x)",
            "safety_margin" => "multiply both raw envelope coefficients by 1.05, then add 64eps(Float64) to atol",
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
            "model_source" => model_sources,
        ),
        "variable" => variables,
        "annual_variable" => annual,
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
