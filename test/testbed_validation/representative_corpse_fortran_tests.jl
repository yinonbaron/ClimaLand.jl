using Test
import SHA
import TOML

include(joinpath(@__DIR__, "representative_corpse_fortran.jl"))
const RepresentativeCORPSEFortran = TestbedRepresentativeCORPSEFortran

record(path) = Dict(
    "filename" => basename(path),
    "bytes" => filesize(path),
    "sha256" => bytes2hex(SHA.sha256(read(path))),
)

function synthetic_fixture(root)
    cells = collect(1001:1080)
    scope = joinpath(root, "representative.toml")
    open(scope, "w") do io
        TOML.print(
            io,
            Dict(
                "schema_version" => 1,
                "name" => "representative",
                "cell_ids" => cells,
            );
            sorted = true,
        )
    end
    paths = Dict{String, String}()
    for name in (
        "forcing",
        "grid",
        "soil",
        "casa_c_parameters",
        "corpse_parameters",
        "phenology",
        "perturbation",
    )
        path = joinpath(root, "$name.input")
        write(path, "$name immutable\n")
        paths[name] = path
    end
    fixture = joinpath(root, "fixture.toml")
    open(fixture, "w") do io
        TOML.print(
            io,
            Dict(
                "schema_version" => 1,
                "selection" => Dict(
                    "representative_cell_ids" => cells,
                    "scope_manifest_sha256" =>
                        bytes2hex(SHA.sha256(read(scope))),
                ),
                "source" => Dict(
                    "repository_commit" =>
                        RepresentativeCORPSEFortran.SOURCE_COMMIT,
                ),
                "fixture" => Dict(name => record(path) for (name, path) in paths),
            );
            sorted = true,
        )
    end
    return (; fixture, scope, cells, paths)
end

@testset "Representative CORPSE workflow uses exact compact four stages" begin
    mktempdir() do root
        data = synthetic_fixture(root)
        before = Dict(name => read(path) for (name, path) in data.paths)
        years = Int[]
        result = RepresentativeCORPSEFortran.write_workflow(
            data.fixture,
            data.scope,
            joinpath(root, "run");
            meteorology_writer = (source, destination; selected_year) -> begin
                push!(years, selected_year)
                write(destination, "$selected_year\n")
            end,
            grid_writer = (source, destination) -> write(destination, "grid\n"),
        )
        workflow = TOML.parsefile(result.workflow_path)
        @test getindex.(workflow["stage"], "name") == [
            "prespin",
            "spin",
            "spin_continuation",
            "historical",
        ]
        @test getindex.(workflow["stage"], "outputs") .|> length ==
              [11, 9, 9, 231]
        @test years == collect(1901:2014)
        @test result.inputs.cell_ids == data.cells
        @test Dict(name => read(path) for (name, path) in data.paths) == before
    end
end

@testset "Representative CORPSE runner uses shared executable and return contract" begin
    mktempdir() do root
        data = synthetic_fixture(root)
        executable = joinpath(root, "fcasacnp")
        write(executable, "fake shared executable")
        calls = Any[]
        workflow_writer = (fixture, scope, output) -> begin
            path = joinpath(output, "workflow.toml")
            write(path, "schema_version = 1\n")
            (; workflow_path = path, inputs = (; cell_ids = data.cells))
        end
        workflow_runner = (exe, workflow, output) -> begin
            push!(calls, (:run, exe, workflow, output))
            historical = joinpath(output, "stages", "04-historical")
            mkpath(historical)
            [(; status = :ran) for _ in 1:4]
        end
        boundary_scanner = (output, cells, observer) -> begin
            push!(calls, (:boundaries, copy(cells)))
            observer("prespin", 36500, "1901-12-31", Dict("state" => zeros(80)))
        end
        historical_scanner = (output, cells, observer) -> begin
            push!(calls, (:historical, output, copy(cells)))
            observer("historical", 1, "1901-01-01", Dict("state" => zeros(80)))
        end
        observed = Any[]
        result = RepresentativeCORPSEFortran.run(;
            executable,
            source_root = root,
            fixture_manifest = data.fixture,
            scope_manifest = data.scope,
            output_root = joinpath(root, "run"),
            cell_ids = data.cells,
            observer = (args...) -> push!(observed, args),
            workflow_writer,
            workflow_runner,
            boundary_scanner,
            historical_scanner,
        )
        @test result.cell_ids == data.cells
        @test result.boundary_root == joinpath(root, "run")
        @test result.historical_root ==
              joinpath(root, "run", "stages", "04-historical")
        @test first(calls)[2] == executable
        @test length(observed) == 2
        reconstruction = TOML.parsefile(
            joinpath(result.boundary_root, "reconstruction_report.toml"),
        )
        @test reconstruction["points"] == 80
    end
end

@testset "CORPSE boundary scanner preserves one-cell source identity" begin
    mktempdir() do root
        write(
            joinpath(root, "casa_final.csv"),
            "npt,veg,casapool%cleaf\n1,7,1.25,\n",
        )
        write(
            joinpath(root, "corpse_final.csv"),
            "ijgcm,veg,soil_1_unprotect_rhiz(LABILE)\n11060,7,2.5,\n",
        )
        values = RepresentativeCORPSEFortran.boundary_values(root, [11060])
        @test values["casa.casapool%cleaf"] == [1.25]
        @test values["corpse.soil_1_unprotect_rhiz(LABILE)"] == [2.5]
        @test values["corpse.veg"] == [7.0]
    end
end

@testset "Representative CORPSE fixture fails closed" begin
    mktempdir() do root
        data = synthetic_fixture(root)
        scope = TOML.parsefile(data.scope)
        pop!(scope["cell_ids"])
        open(data.scope, "w") do io
            TOML.print(io, scope; sorted = true)
        end
        @test_throws ErrorException RepresentativeCORPSEFortran.fixture_inputs(
            data.fixture,
            data.scope,
        )
    end
end
