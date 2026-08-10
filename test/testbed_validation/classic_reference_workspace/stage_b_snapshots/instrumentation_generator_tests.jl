using Test
import TOML

include("generate_fortran_instrumentation.jl")
using .GenerateStageBFortranInstrumentation

const MINIMAL_DRIVER = """
module ctemDriver
  use classicParams, only: deltat, tolrance, convertg2kg
contains
  subroutine drive
    ! inputs
    if (PFTCompetition) then
      if (inibioclim) then
        call competition(args)
      end if
    end if
    if (lnduseon) then
      call luc(args)
    end if
    if (timberHarvest) then
      call harvestTile(args)
    end if
    call heterotrophicRespiration(args)
    call updatePoolsHetResp(args)
    call updatePoolsTurnover(args)
    call updatePoolsMortality(args)
    call disturbance(args)
    call turbation(args)
  end subroutine drive
end module ctemDriver
"""

@testset "compiled instrumentation generator is deterministic and immutable" begin
    mktempdir() do directory
        source = joinpath(directory, "ctemDriver.F90")
        write(source, MINIMAL_DRIVER)
        before = read(source)
        first = joinpath(directory, "first")
        second = joinpath(directory, "second")
        first_receipt = generate_fortran_instrumentation(
            source,
            first;
            source_commit = repeat("a", 40),
        )
        second_receipt = generate_fortran_instrumentation(
            source,
            second;
            source_commit = repeat("a", 40),
        )
        @test read(source) == before
        @test first_receipt["patch_sha256"] == second_receipt["patch_sha256"]
        patch = read(joinpath(first, "classic-stage-b-snapshots.patch"), String)
        pre_litter = findall("'pre.litrmass'", patch)
        pre_soil = findall("'pre.soilcmas'", patch)
        competition_calls = findall("+        call competition(args)", patch)
        @test length(pre_litter) == 1
        @test length(pre_soil) == 1
        @test length(competition_calls) == 1
        @test minimum(only(pre_litter)) < minimum(only(competition_calls))
        @test minimum(only(pre_soil)) < minimum(only(competition_calls))
        added = join(
            filter(
                line -> startswith(line, "+") && !startswith(line, "+++"),
                split(patch, '\n'),
            ),
            '\n',
        )
        @test occursin("static.delzw", patch)
        @test occursin("'static.zbot', zbot", patch)
        @test occursin("sb_competition_delta_litter = &", patch)
        @test occursin("sb_land_use_delta_litter = &", patch)
        @test occursin("sb_harvest_delta_litter = &", patch)
        @test findfirst("'pre.litrmass'", added) <
              findfirst("call competition(args)", added)
        @test findfirst("'pre.soilcmas'", added) <
              findfirst("call competition(args)", added)
        @test count("'pre.litrmass'", added) == 1
        @test count("'pre.soilcmas'", added) == 1
        @test !occursin(
            "'forcing.pre_resp_competition_delta_litter', 0.0*litrmass",
            patch,
        )
        @test first_receipt["pre_resp_transfer_capture"] ==
              "measured_at_process_calls"
        @test occursin("subroutine sb_write_r3", patch)
        @test occursin("CLASSIC_STAGE_B_CAPTURE_MODE", patch)
        @test occursin("CLASSIC_STAGE_B_CAPTURE_MAX_EVENTS", patch)
        @test occursin("capture max events must be a positive integer", patch)
        @test occursin("sb_event_index < sb_capture_max_events", patch)
        @test !occursin(
            "\n      capture_max_events = 0\n",
            GenerateStageBFortranInstrumentation.DECLARATIONS,
        )
        @test occursin("capture_complete events=", patch)
        @test occursin("event_' // event_name // '.raw", patch)
        @test occursin("daily Stage B event already exists", patch)
        @test occursin("event_ledger.raw", patch)
        @test occursin("CLASSIC_STAGE_B_SNAPSHOT_ROOT is required", patch)
        @test TOML.parsefile(
            joinpath(first, "instrumentation_receipt.toml"),
        )["status"] == "generated"
        @test_throws ErrorException generate_fortran_instrumentation(
            source,
            first;
            source_commit = repeat("a", 40),
        )
    end
end
