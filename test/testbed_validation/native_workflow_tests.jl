using Test

@testset "native repeated forcing schedule" begin
    stage = TestbedNativeWorkflow.NativeStage(:spin, 3, 2)
    @test TestbedNativeWorkflow.step_count(stage) == 6
    @test [TestbedNativeWorkflow.forcing_index(stage, step) for step in 1:6] == [1, 2, 3, 1, 2, 3]
    annual = TestbedNativeWorkflow.NativeStage(:prespin, 365, 2)
    @test TestbedNativeWorkflow.forcing_index.(
        Ref(annual),
        (1, 365, 366, 730),
    ) == (1, 365, 1, 365)
end

function write_initialization_table(path)
    carbon = [zeros(9) for _ in 1:18]
    nitrogen = [zeros(10) for _ in 1:18]
    carbon[7] .= (88, 372, 140, 3, 39, 112, 168, 4465, 1386)
    nitrogen[7] .= (2.9, 2.8, 3.4, 0.05, 0.26, 0.83, 16.8, 297.7, 92.4, 1000)
    carbon[16] .= (20, 17, 63, 1.5, 5, 28, 58, 1325, 517)
    nitrogen[16] .= (0.5, 0.13, 1.5, 0.02, 0.03, 0.21, 5.8, 88, 34, 1000)
    nitrogen[17][10] = 1000
    open(path, "w") do io
        println(io, "IGBP vegetation type")
        println(io, "IGBP,category")
        println(io, "vegtype,category")
        for pft in 1:18
            category = pft == 17 ? 0 : pft == 16 ? 1 : 3
            println(io, "$pft,$category")
        end
        for (header, rows) in ((",Leaf C", carbon), (",Nleaf", nitrogen))
            println(io, header)
            println(io, "units")
            for pft in 1:18
                println(io, join((pft, rows[pft]...), ','))
            end
        end
    end
end

@testset "Fortran parameter-based initial states" begin
    mktempdir() do directory
        path = joinpath(directory, "parameters.csv")
        write_initialization_table(path)

        casa = TestbedNativeWorkflow.fortran_initial_state(
            path,
            7;
            soil_model = :casa,
            nutrients = :carbon_nitrogen,
        )
        @test casa.casa_plant.c_leaf == 0.088
        @test casa.casa_plant.n_fine_root == 0.0034
        @test casa.casa_soil.c_soil_slow == 4.465
        @test casa.casa_soil.n_mineral == 1.0

        mimics = TestbedNativeWorkflow.fortran_initial_state(
            path,
            7;
            soil_model = :mimics,
            nutrients = :carbon_nitrogen,
            microbial_carbon_nitrogen = (6.0, 10.0),
        )
        @test mimics.mimics_soil.c_litter_metabolic == 1.0
        @test mimics.mimics_soil.c_litter_cwd == 0.112
        @test mimics.mimics_soil.n_litter_metabolic == 0.1
        @test mimics.mimics_soil.n_microbe_r == 0.0025
        @test mimics.mimics_soil.n_mineral == 1.0

        inactive = TestbedNativeWorkflow.fortran_initial_state(
            path,
            17;
            soil_model = :mimics,
            nutrients = :carbon_nitrogen,
        )
        @test all(iszero, values(inactive.casa_plant))
        @test all(
            iszero,
            values(Base.structdiff(inactive.mimics_soil, (; n_mineral = 0.0))),
        )
        @test inactive.mimics_soil.n_mineral == 0.0

        casa_c = TestbedNativeWorkflow.fortran_initial_state(
            path,
            7;
            soil_model = :casa,
            nutrients = :carbon_only,
        )
        @test propertynames(casa_c.casa_plant) ==
              (:c_leaf, :c_wood, :c_fine_root, :c_labile)
        @test casa_c.casa_soil.c_litter_cwd == 0.112

        mimics_c = TestbedNativeWorkflow.fortran_initial_state(
            path,
            7;
            soil_model = :mimics,
            nutrients = :carbon_only,
        )
        @test mimics_c.mimics_soil.c_microbe_k == 0.025

        inactive_casa = TestbedNativeWorkflow.fortran_initial_state(
            path,
            17;
            soil_model = :casa,
            nutrients = :carbon_nitrogen,
        )
        @test all(iszero, values(inactive_casa.casa_plant))
        @test all(iszero, values(inactive_casa.casa_soil))

        for soil_model in (:casa, :mimics)
            inactive_carbon = TestbedNativeWorkflow.fortran_initial_state(
                path,
                17;
                soil_model,
                nutrients = :carbon_only,
            )
            @test all(iszero, values(inactive_carbon.casa_plant))
            soil_component = soil_model == :casa ? :casa_soil : :mimics_soil
            @test all(
                iszero,
                values(getproperty(inactive_carbon, soil_component)),
            )
        end

        grass_casa = TestbedNativeWorkflow.fortran_initial_state(
            path,
            16;
            soil_model = :casa,
            nutrients = :carbon_nitrogen,
        )
        @test grass_casa.casa_plant.c_leaf == 0.02
        @test grass_casa.casa_plant.c_wood == 0.0
        @test all(
            value >= 1e-9 for value in (
                grass_casa.casa_plant.n_leaf,
                grass_casa.casa_plant.n_wood,
                grass_casa.casa_plant.n_fine_root,
            )
        )
        @test grass_casa.casa_plant.n_wood == 1e-9
        @test grass_casa.casa_soil.c_litter_cwd == 0.0
        @test grass_casa.casa_soil.n_litter_cwd == 1e-9

        grass_mimics = TestbedNativeWorkflow.fortran_initial_state(
            path,
            16;
            soil_model = :mimics,
            nutrients = :carbon_nitrogen,
        )
        @test grass_mimics.mimics_soil.c_litter_cwd == 0.0
        @test grass_mimics.mimics_soil.n_litter_cwd == 1e-9
    end
end
