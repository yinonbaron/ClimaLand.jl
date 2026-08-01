using Test
import TOML

include(joinpath(@__DIR__, "corpse_fresh_worker.jl"))
using .TestbedCORPSEFreshWorker

function write_scope(path; cells = [51, 3442, collect(100:177)...])
    cells = copy(cells)
    entries = [
        Dict(
            "model" => "CORPSE",
            "cell_id" => 51,
            "pft" => 17,
            "reviewed" => true,
        ),
        Dict(
            "model" => "CORPSE",
            "cell_id" => 3442,
            "pft" => 11,
            "reviewed" => true,
        ),
    ]
    open(path, "w") do io
        TOML.print(
            io,
            Dict(
                "schema_version" => 1,
                "name" => "representative",
                "cell_ids" => cells,
                "eligibility_gaps" => entries,
            );
            sorted = true,
        )
    end
    return cells
end

function fixture(root)
    scope = joinpath(root, "representative.toml")
    cells = write_scope(scope)
    calibration = joinpath(root, "calibration.toml")
    fixture_manifest = joinpath(root, "fixture.toml")
    write(calibration, "calibration_id = \"frozen\"\n")
    write(fixture_manifest, "schema_version = 1\n")
    build = joinpath(root, "build")
    mkpath(build)
    executable = joinpath(build, "fcasacnp_clm")
    write(executable, "verified")
    return (; scope, cells, calibration, fixture_manifest, build, executable)
end

function successful_bridges(data, calls)
    executable_resolver = build -> begin
        push!(calls, (:resolve, build))
        data.executable
    end
    fortran_runner = function (;
        executable,
        source_root,
        fixture_manifest,
        scope_manifest,
        output_root,
        cell_ids,
        observer,
    )
        push!(calls, (:fortran, output_root, copy(cell_ids)))
        observer("prespin", 1, "1901-01-01", Dict("state.c" => zeros(80)))
        observer("spin", 1, "1901-01-01", Dict("state.c" => zeros(80)))
        observer(
            "spin_continuation",
            1,
            "1901-01-01",
            Dict("state.c" => zeros(80)),
        )
        observer("historical", 1, "1901-01-01", Dict("flux.r" => zeros(80)))
        boundary_root = joinpath(output_root, "boundaries")
        historical_root = joinpath(output_root, "historical")
        mkpath(boundary_root)
        mkpath(historical_root)
        (; cell_ids = copy(cell_ids), boundary_root, historical_root)
    end
    reference_reducer = (scope, historical, output) -> begin
        push!(calls, (:reduce, scope, historical, output))
        write(output, "fresh oracle")
        write(output * ".toml", "schema_version = 1\n")
        (; reference = output, manifest = output * ".toml")
    end
    payload_builder = (boundaries, oracle, destination) -> begin
        push!(calls, (:payload, boundaries, oracle, destination))
        write(joinpath(destination, "boundaries.tar"), "fresh boundaries")
        (; reduced_history = oracle, archive = joinpath(destination, "boundaries.tar"))
    end
    julia_runner = function (;
        output_root,
        bundle,
        boundary_root,
        fixture_manifest,
        scope_manifest,
        calibration_manifest,
        cell_ids,
        observer,
    )
        push!(calls, (:julia, output_root, copy(cell_ids)))
        observer("prespin", 1, "1901-01-01", Dict("state.c" => zeros(80)))
        observer("spin", 1, "1901-01-01", Dict("state.c" => zeros(80)))
        observer(
            "spin_continuation",
            1,
            "1901-01-01",
            Dict("state.c" => zeros(80)),
        )
        observer("historical", 1, "1901-01-01", Dict("flux.r" => zeros(80)))
        report = joinpath(output_root, "corpse_comparison_report.toml")
        open(report, "w") do io
            TOML.print(
                io,
                Dict(
                    "schema_version" => 1,
                    "outcome" => "passed",
                    "coverage" => Dict(
                        "scope_cells" => 80,
                        "eligible_cells" => 78,
                        "compared_cells" => 78,
                    ),
                );
                sorted = true,
            )
        end
        (; report)
    end
    return (;
        executable_resolver,
        fortran_runner,
        reference_reducer,
        payload_builder,
        julia_runner,
    )
end

function run_test_worker(data, run_root, bridges)
    return run_worker(
        dirname(data.fixture_manifest),
        data.fixture_manifest,
        run_root,
        data.build;
        scope_manifest = data.scope,
        calibration_manifest = data.calibration,
        bridges...,
    )
end

@testset "CORPSE fresh worker runs exact Representative scope in isolation" begin
    mktempdir() do root
        data = fixture(root)
        calls = Any[]
        result = run_test_worker(data, joinpath(root, "run"), successful_bridges(data, calls))
        @test result.status == :passed
        @test isfile(result.oracle)
        @test basename(result.comparison) == "comparison.toml"
        comparison = TOML.parsefile(result.comparison)
        @test comparison["model"] == "CORPSE"
        @test comparison["scope"] == "representative"
        @test comparison["reference"]["kind"] == "fresh_reduced_oracle"
        @test TOML.parsefile(joinpath(root, "run", "fortran_output.toml"))["scope_cells"] == 80
        @test isfile(joinpath(root, "run", "julia_output.toml"))
        @test [call[1] for call in calls] ==
              [:resolve, :fortran, :reduce, :payload, :julia]
        @test calls[2][3] == data.cells
        @test calls[5][3] == data.cells
        @test read(data.calibration, String) == "calibration_id = \"frozen\"\n"
        @test read(data.fixture_manifest, String) == "schema_version = 1\n"
    end
end

@testset "CORPSE exact Fortran nonfinite evidence stops before reduction" begin
    mktempdir() do root
        data = fixture(root)
        calls = Any[]
        bridges = successful_bridges(data, calls)
        fortran_runner = function (; output_root, cell_ids, observer, kwargs...)
            observer("prespin", 41, "1901-02-10", Dict("z" => zeros(80)))
            values = zeros(80)
            values[3] = Inf
            other = zeros(80)
            other[3] = NaN
            observer("prespin", 42, "1901-02-11", Dict("z" => values, "a" => other))
            error("unreachable")
        end
        result = run_test_worker(
            data,
            joinpath(root, "run"),
            merge(bridges, (; fortran_runner)),
        )
        @test result.status == :nonfinite
        @test result.side == :fortran
        document = TOML.parsefile(result.evidence)
        record = only(document["eligibility_gap_proposal"])
        @test record["cell_id"] == data.cells[3]
        @test record["first_nonfinite_stage"] == "prespin"
        @test record["first_nonfinite_step"] == 42
        @test record["first_nonfinite_date"] == "1901-02-11"
        @test record["first_nonfinite_variable"] == "a"
        @test record["reviewed"] == false
        @test !(:reduce in first.(calls))
    end
end

@testset "CORPSE Julia observer ignores reviewed gaps and reports eligible cells" begin
    mktempdir() do root
        data = fixture(root)
        calls = Any[]
        bridges = successful_bridges(data, calls)
        julia_runner = function (; cell_ids, observer, kwargs...)
            gap_values = zeros(80)
            gap_values[1] = Inf
            gap_values[2] = NaN
            observer("historical", 9, "1901-01-09", Dict("state.c" => gap_values))
            values = zeros(80)
            values[4] = Inf
            observer("historical", 10, "1901-01-10", Dict("diagnostic.r" => values))
            error("unreachable")
        end
        result = run_test_worker(
            data,
            joinpath(root, "run"),
            merge(bridges, (; julia_runner)),
        )
        @test result.status == :nonfinite
        @test result.side == :julia
        record = only(TOML.parsefile(result.evidence)["nonfinite"])
        @test record["cell_id"] == data.cells[4]
        @test record["first_nonfinite_step"] == 10
        @test record["first_nonfinite_variable"] == "diagnostic.r"
    end
end

@testset "CORPSE observer rejects incomplete and unordered evidence" begin
    cells = [51, 3442, collect(100:177)...]
    observer = TrajectoryObserver("julia", cells, cells[3:end])
    @test_throws WorkerError observer("spin", 1, "1901-01-01", Dict("x" => zeros(79)))
    observer = TrajectoryObserver("julia", cells, cells[3:end])
    observer("spin", 2, "1901-01-02", Dict("x" => zeros(80)))
    @test_throws WorkerError observer("spin", 2, "1901-01-02", Dict("x" => zeros(80)))
    @test_throws WorkerError observer("prespin", 3, "1901-01-03", Dict("x" => zeros(80)))
end

@testset "CORPSE fresh worker preserves immutable inputs and rethrows errors" begin
    mktempdir() do root
        data = fixture(root)
        bridges = successful_bridges(data, Any[])
        fortran_runner = function (; kwargs...)
            write(data.calibration, "changed = true\n")
            error("runner failed")
        end
        error = try
            run_test_worker(
                data,
                joinpath(root, "run"),
                merge(bridges, (; fortran_runner)),
            )
            nothing
        catch value
            value
        end
        @test error isa WorkerError
        @test occursin("mutated immutable input", sprint(showerror, error))
    end
    mktempdir() do root
        data = fixture(root)
        bridges = successful_bridges(data, Any[])
        fortran_runner = (; kwargs...) -> error("unrelated failure")
        @test_throws ErrorException run_test_worker(
            data,
            joinpath(root, "run"),
            merge(bridges, (; fortran_runner)),
        )
    end
end

@testset "CORPSE scope is fixed at 80 cells" begin
    mktempdir() do root
        path = joinpath(root, "bad.toml")
        write_scope(path; cells = [51, 3442, collect(100:176)...])
        @test_throws WorkerError representative_scope(path)
    end
end
