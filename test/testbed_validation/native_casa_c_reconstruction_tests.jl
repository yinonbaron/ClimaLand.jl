using Test
import NCDatasets
import TOML

function write_gridded_parameter_fixture(path)
    open(path, "w") do io
        println(io, "IGBP vegetation type")
        println(io, "IGBP,category")
        println(io, "vegtype,category")
        for pft in 1:18
            println(io, "$pft,$(pft == 17 ? 0 : 3)")
        end
        sections = (
            (
                "nv1,Kroot",
                [
                    2,
                    1.5,
                    0,
                    0,
                    0,
                    0,
                    0,
                    1,
                    40,
                    3,
                    0.04,
                    0.23,
                    0.824,
                    0.137,
                    5,
                    222.22,
                    0.2,
                    0.02,
                ],
            ),
            ("NV2,Calloc_leaf", [0.4, 0.2, 0.4, 0.1, 1, 1, 0.5]),
            (
                "nv3,C:N leaf",
                [
                    50,
                    150,
                    40,
                    0.5,
                    0.95,
                    0.9,
                    0.2,
                    0.4,
                    0.2,
                    8,
                    20,
                    20,
                    6,
                    16,
                    16,
                    8,
                    30,
                    30,
                    3,
                    0.1,
                ],
            ),
            (",Leaf C", collect(1.0:9.0)),
            (",Nleaf", collect(1.0:10.0)),
            (",Pleaf", collect(1.0:12.0)),
            ("IGBP:,Tkshed", [273.15, 0.1, 3, 0.1, 3]),
            (",xnpmax,q01soil", [1, 1.72, 0.4, 0.4, 0, 0, 0, 0, 0, 0]),
            (",xkNlimit_min", [0, 0, 0, 0.45, 0.45, 0.7, 0.4, 0.7, 1, 1, 0.45]),
        )
        for (header, values) in sections
            println(io, header)
            println(io, "units")
            for pft in 1:18
                println(io, join((pft, values...), ','))
            end
        end
    end
end

function write_gridded_fixture(directory)
    grid = joinpath(directory, "grid.csv")
    write(
        grid,
        "ijcam,lat,lon,ivt_igbp,ist,iso,landarea,Ndep,Nfix,Pwea,Pdust,doyP1,doyP2,doyP3,doyP4,Phase(1),ivcasa,ilat,ilon\n" *
        "1,79.75,0,1,1,1,10,0,0,0,0,0,0,0,0,0,1,1,1\n" *
        "2,79.75,1,17,1,1,20,0,0,0,0,0,0,0,0,0,17,1,2\n",
    )
    soil = joinpath(directory, "soil.csv")
    write(
        soil,
        "ijcam,lat,lon,sand,clay,silt,wwilt,wfield,wsat\n" *
        "1,79.75,0,0.4,0.2,0.4,0.1,0.2,0.4\n" *
        "2,79.75,1,0.4,0.2,0.4,0.1,0.2,0.4\n",
    )
    phenology = joinpath(directory, "phenology.txt")
    pfts = "3 4 5 6 7 8 9 10 12 14 18"
    values = join(vcat(fill(100, 11), fill(200, 11), fill(2, 11)), ' ')
    write(phenology, "header\n$pfts $pfts $pfts\n79.75 $values\n")
    parameters = joinpath(directory, "parameters.csv")
    write_gridded_parameter_fixture(parameters)
    forcing = joinpath(directory, "forcing")
    mkpath(forcing)
    NCDatasets.NCDataset(joinpath(forcing, "met_1901_1901.nc"), "c") do output
        NCDatasets.defDim(output, "lon", 2)
        NCDatasets.defDim(output, "lat", 1)
        NCDatasets.defDim(output, "nsoilyrs", 6)
        NCDatasets.defDim(output, "time", 2)
        NCDatasets.defVar(output, "xcgpp", Float64, ("lon", "lat", "time"))[
            :,
            :,
            :,
        ] .= 1
        NCDatasets.defVar(output, "xtairk", Float64, ("lon", "lat", "time"))[
            :,
            :,
            :,
        ] .= 280
        NCDatasets.defVar(
            output,
            "xtsoil",
            Float64,
            ("lon", "lat", "nsoilyrs", "time"),
        )[
            :,
            :,
            :,
            :,
        ] .= 275
        NCDatasets.defVar(
            output,
            "xmoist",
            Float64,
            ("lon", "lat", "nsoilyrs", "time"),
        )[
            :,
            :,
            :,
            :,
        ] .= 0.3
    end
    return (; grid, soil, phenology, parameters, forcing)
end

@testset "native CASA-C reconstruction run-case seam" begin
    mktempdir() do output_root
        result =
            TestbedNativeCASACReconstruction.run_synthetic_case(output_root)
        report = TOML.parsefile(result.report)

        @test getproperty.(result.stages, :name) ==
              (:prespin, :accelerated_spin, :normal_spin, :historical)
        @test all(isfile, getproperty.(result.stages, :checkpoint))
        @test report["passive_restoration"]["verified"]
        @test report["passive_restoration"]["multiplier"] == 10
        @test report["historical_output"]["records"] == 2
        @test Set(keys(report["boundary_comparison"])) ==
              Set(("prespin", "accelerated_spin", "normal_spin", "historical"))
        @test Set(keys(report["historical_comparison"])) ==
              Set(("annual", "daily"))
        @test report["carbon_budget"]["all_close"]
        NCDatasets.NCDataset(result.output) do output
            @test all(
                haskey(output, native_name) for (_, native_name) in
                TestbedNativeCASACReconstruction.FLUX_VARIABLES
            )
            @test all(iszero, Array(output["diagnostic__cgpp"][:, :]))
        end
    end
end

@testset "native CASA-C reduced gridded fixture" begin
    mktempdir() do directory
        fixture = write_gridded_fixture(directory)
        grid = TestbedNativeCASACReconstruction.read_grid(fixture.grid)
        soils = TestbedNativeCASACReconstruction.read_soils(fixture.soil)
        domain = TestbedNativeCASACReconstruction.gridded_domain(2)
        buffers = TestbedNativeCASACReconstruction.GriddedBuffers(domain)
        built = TestbedNativeCASACReconstruction.build_gridded_model(
            grid,
            soils,
            fixture.parameters,
            buffers;
            domain,
        )
        initial = TestbedNativeCASACReconstruction.gridded_initial_state(
            built.model,
            grid,
            built.parameters,
        )
        forcing = TestbedNativeCASACReconstruction.GriddedForcing(
            grid,
            soils,
            built.parameters,
            fixture.phenology,
            fixture.forcing,
            buffers,
        )
        stage = TestbedNativeWorkflow.NativeStage(:prespin, 2, 1)
        TestbedNativeCASACReconstruction.update_forcing!(forcing, stage, 1, 0.0)

        @test length(grid) == 2
        @test sum(
            TestbedNativeCASACReconstruction.root_fractions(
                built.parameters[1],
            ),
        ) ≈ 1
        expected_roots =
            TestbedNativeCASACReconstruction.SoilCASA.legacy_root_fractions(
                built.parameters[1].root_coefficient,
                built.parameters[1].root_depth,
                (0.022, 0.058, 0.154, 0.409, 1.085, 2.872),
            )
        @test TestbedNativeCASACReconstruction.root_fractions(
            built.parameters[1],
        ) == expected_roots
        default_phenology = TestbedNativeCASACReconstruction.read_phenology(
            fixture.phenology,
            [(; latitude = 79.75, pft = 16)],
        )
        @test only(default_phenology).transition == (-50, -36, 367, 16)
        @test vec(parent(initial.casa_plant.c_leaf)) == [0.001, 0.0]
        @test vec(parent(buffers.gpp)) == [1 / 1000 / 86400, 0]
        @test vec(parent(buffers.soil_temperature)) == [275, 273.15]
        @test vec(parent(buffers.liquid_water)) ≈ [0.2, 0]
        @test vec(parent(buffers.water_stress)) == [1, 0]
        @test vec(parent(buffers.phase)) == [2, 2]
        @test forcing.spin_cache[1901].loaded[1]
        TestbedNativeCASACReconstruction.close_forcing!(forcing)
    end
end

@testset "native CASA-C comparison guards" begin
    @test_throws DimensionMismatch TestbedNativeCASACReconstruction.error_metrics(
        zeros(2),
        zeros(3),
    )
    invalid_native =
        TestbedNativeCASACReconstruction.error_metrics([NaN], [1.0])
    @test !invalid_native["all_match"]
    @test invalid_native["failed_values"] == 1
    invalid_reference =
        TestbedNativeCASACReconstruction.error_metrics([1.0], [NaN])
    @test !invalid_reference["all_match"]
    @test invalid_reference["failed_values"] == 1
    mixed_reference =
        TestbedNativeCASACReconstruction.error_metrics([1.0, 2.0], [1.0, NaN])
    @test !mixed_reference["all_match"]
    @test mixed_reference["failed_values"] == 1
end
