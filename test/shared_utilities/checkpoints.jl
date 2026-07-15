using Test

import ClimaComms
ClimaComms.@import_required_backends

using ClimaLand

struct CheckpointTestModel{FT, D} <: ClimaLand.AbstractModel{FT}
    domain::D
end

ClimaLand.name(::CheckpointTestModel) = :checkpoint
ClimaLand.prognostic_vars(::CheckpointTestModel) = (:carbon, :bookkeeping)
ClimaLand.prognostic_types(::CheckpointTestModel{FT}) where {FT} = (FT, FT)
ClimaLand.prognostic_domain_names(::CheckpointTestModel) =
    (:subsurface, :surface)

function checkpoint_test_domain(::Type{FT}, domain_kind) where {FT}
    if domain_kind == :column
        return ClimaLand.Domains.Column(; zlim = FT.((-1, 0)), nelements = 4)
    elseif domain_kind == :column_latlong
        return ClimaLand.Domains.Column(;
            zlim = FT.((-1, 0)),
            nelements = 4,
            longlat = FT.((-118, 45)),
        )
    end
    return ClimaLand.Domains.HybridBox(;
        xlim = FT.((-1000, 1000)),
        ylim = FT.((-1000, 1000)),
        zlim = FT.((-1, 0)),
        nelements = (1, 1, 4),
        npolynomial = 1,
        longlat = FT.((-118, 45)),
    )
end

function checkpoint_file(output_dir)
    return only(
        filter(
            path -> endswith(path, ".hdf5"),
            readdir(output_dir; join = true),
        ),
    )
end

@testset "Checkpoint grid compatibility" begin
    FT = Float32
    time = FT(12345.5)
    for domain_kind in (:column, :column_latlong, :hybrid_box_latlong)
        @testset "$domain_kind" begin
            domain = checkpoint_test_domain(FT, domain_kind)
            model = CheckpointTestModel{FT, typeof(domain)}(domain)
            Y, _, _ = ClimaLand.initialize(model)
            Y.checkpoint.carbon .= FT(1.25)
            Y.checkpoint.bookkeeping .= FT(2.5)

            restored_domain = checkpoint_test_domain(FT, domain_kind)
            restored_model = CheckpointTestModel{FT, typeof(restored_domain)}(
                restored_domain,
            )
            Y_restored, _, _ = ClimaLand.initialize(restored_model)

            mktempdir() do output_dir
                ClimaLand.save_checkpoint(Y, time, output_dir; model)
                restart_file = checkpoint_file(output_dir)
                ClimaLand.set_initial_conditions_from_checkpoint!(
                    Y_restored,
                    restart_file;
                    model,
                )
                @test ClimaLand.initial_time_from_checkpoint(
                    restart_file;
                    model,
                ) == time

                Y_loaded, loaded_time =
                    ClimaLand.read_checkpoint(restart_file; model)
                @test loaded_time == time
                @test Y_loaded == Y
            end

            @test Array(parent(Y_restored.checkpoint.carbon)) ==
                  Array(parent(Y.checkpoint.carbon))
            @test Array(parent(Y_restored.checkpoint.bookkeeping)) ==
                  Array(parent(Y.checkpoint.bookkeeping))
        end
    end
end
