module GenerateStageBFortranInstrumentation

import SHA
import TOML

export generate_fortran_instrumentation

sha256sum(path) = open(path) do io
    bytes2hex(SHA.sha256(io))
end

function statement_end(lines, start)
    index = start
    while index < length(lines)
        code = first(split(lines[index], '!'; limit = 2))
        endswith(strip(code), "&") || return index
        index += 1
    end
    return index
end

function insert_before_call!(lines, routine, block)
    matches = findall(
        line -> occursin(Regex("^\\s*call\\s+$routine\\s*\\("), line),
        lines,
    )
    length(matches) == 1 || error("expected one unconditional $routine call")
    index = only(matches)
    splice!(lines, index:(index - 1), split(block, '\n'))
end

function insert_after_call!(lines, routine, block)
    matches = findall(
        line -> occursin(Regex("^\\s*call\\s+$routine\\s*\\("), line),
        lines,
    )
    length(matches) == 1 || error("expected one unconditional $routine call")
    index = statement_end(lines, only(matches)) + 1
    splice!(lines, index:(index - 1), split(block, '\n'))
end

function insert_before_condition!(lines, variable, block)
    pattern = Regex("(?i)^\\s*if\\s*\\(\\s*$variable\\s*\\)\\s*then")
    matches = findall(line -> occursin(pattern, line), lines)
    length(matches) == 1 || error("expected one $variable conditional anchor")
    index = only(matches)
    splice!(lines, index:(index - 1), split(block, '\n'))
end

const DECLARATIONS = raw"""
    integer, save :: sb_active = 0
    integer, save :: sb_event_index = 0
    integer, save :: sb_capture_max_events = 0
    logical, save :: sb_capture_all_daily = .false.
    logical, save :: sb_mode_initialized = .false.
    logical, save :: sb_ordinary_done = .false.
    logical, save :: sb_frozen_done = .false.
    character(len=1024), save :: sb_directory = ''
    real, allocatable, save :: sb_litter_before(:,:,:)
    real, allocatable, save :: sb_soil_before(:,:,:)
    real, allocatable, save :: sb_competition_delta_litter(:,:,:)
    real, allocatable, save :: sb_competition_delta_soil(:,:,:)
    real, allocatable, save :: sb_land_use_delta_litter(:,:,:)
    real, allocatable, save :: sb_land_use_delta_soil(:,:,:)
    real, allocatable, save :: sb_harvest_delta_litter(:,:,:)
    real, allocatable, save :: sb_harvest_delta_soil(:,:,:)
"""

const BEGIN_PRE_TRANSFERS = raw"""
    sb_active = 0
    if (.not. sb_mode_initialized) call sb_initialize_capture_mode(sb_capture_all_daily, sb_mode_initialized, sb_capture_max_events)
    if (sb_capture_all_daily) then
      if (sb_event_index < sb_capture_max_events) then
        sb_event_index = sb_event_index + 1
        sb_active = 3
        call sb_begin_daily_snapshot(sb_event_index, sb_directory)
      end if
    else if (.not. sb_frozen_done .and. any(tbar(il1:il2,1) - tfrez <= tcrit) .and. &
        any(thice(il1:il2,1) > 0.0)) then
      sb_active = 2
      call sb_begin_snapshot('frozen_soil', sb_directory)
    else if (.not. sb_ordinary_done .and. all(tbar(il1:il2,1) - tfrez > tcrit)) then
      sb_active = 1
      call sb_begin_snapshot('ordinary', sb_directory)
    end if
    if (sb_active > 0) then
      call sb_write_r3(sb_directory, 'pre.litrmass', litrmass(il1:il2,1:iccp1,:))
      call sb_write_r3(sb_directory, 'pre.soilcmas', soilcmas(il1:il2,1:iccp1,:))
      if (.not. allocated(sb_litter_before)) then
        allocate(sb_litter_before(il2-il1+1,iccp1,ignd))
        allocate(sb_soil_before(il2-il1+1,iccp1,ignd))
        allocate(sb_competition_delta_litter(il2-il1+1,iccp1,ignd))
        allocate(sb_competition_delta_soil(il2-il1+1,iccp1,ignd))
        allocate(sb_land_use_delta_litter(il2-il1+1,iccp1,ignd))
        allocate(sb_land_use_delta_soil(il2-il1+1,iccp1,ignd))
        allocate(sb_harvest_delta_litter(il2-il1+1,iccp1,ignd))
        allocate(sb_harvest_delta_soil(il2-il1+1,iccp1,ignd))
      end if
      sb_competition_delta_litter = 0.0
      sb_competition_delta_soil = 0.0
      sb_land_use_delta_litter = 0.0
      sb_land_use_delta_soil = 0.0
      sb_harvest_delta_litter = 0.0
      sb_harvest_delta_soil = 0.0
    end if
"""

const BEFORE_HET = raw"""
    if (sb_active > 0) then
      if (.not. PFTCompetition) then
        sb_competition_delta_litter = 0.0
        sb_competition_delta_soil = 0.0
      end if
      if (.not. lnduseon) then
        sb_land_use_delta_litter = 0.0
        sb_land_use_delta_soil = 0.0
      end if
      if (.not. timberHarvest) then
        sb_harvest_delta_litter = 0.0
        sb_harvest_delta_soil = 0.0
      end if
      call sb_write_r2(sb_directory, 'forcing.tbar', tbar(il1:il2,:))
      call sb_write_r2(sb_directory, 'forcing.thliq', thliq(il1:il2,:))
      call sb_write_r2(sb_directory, 'forcing.thice', thice(il1:il2,:))
      call sb_write_r2(sb_directory, 'forcing.fcancmx', fcancmx(il1:il2,:))
      call sb_write_r1(sb_directory, 'forcing.fg', fg(il1:il2))
      call sb_write_r1(sb_directory, 'forcing.max_annual_active_layer', maxAnnualActLyr(il1:il2))
      call sb_write_r3(sb_directory, 'forcing.pre_resp_competition_delta_litter', sb_competition_delta_litter)
      call sb_write_r3(sb_directory, 'forcing.pre_resp_competition_delta_soil', sb_competition_delta_soil)
      call sb_write_r3(sb_directory, 'forcing.pre_resp_land_use_delta_litter', sb_land_use_delta_litter)
      call sb_write_r3(sb_directory, 'forcing.pre_resp_land_use_delta_soil', sb_land_use_delta_soil)
      call sb_write_r3(sb_directory, 'forcing.pre_resp_harvest_delta_litter', sb_harvest_delta_litter)
      call sb_write_r3(sb_directory, 'forcing.pre_resp_harvest_delta_soil', sb_harvest_delta_soil)
      call sb_write_r3(sb_directory, 'forcing.post_resp_turnover_delta_litter', 0.0*litrmass(il1:il2,1:iccp1,:))
      call sb_write_r3(sb_directory, 'forcing.post_resp_turnover_delta_soil', 0.0*soilcmas(il1:il2,1:iccp1,:))
      call sb_write_r3(sb_directory, 'forcing.post_resp_mortality_delta_litter', 0.0*litrmass(il1:il2,1:iccp1,:))
      call sb_write_r3(sb_directory, 'forcing.post_resp_mortality_delta_soil', 0.0*soilcmas(il1:il2,1:iccp1,:))
      call sb_write_r3(sb_directory, 'forcing.post_resp_disturbance_delta_litter', 0.0*litrmass(il1:il2,1:iccp1,:))
      call sb_write_r3(sb_directory, 'forcing.post_resp_disturbance_delta_soil', 0.0*soilcmas(il1:il2,1:iccp1,:))
      call sb_write_r2(sb_directory, 'static.thpor', thpor(il1:il2,:))
      call sb_write_r2(sb_directory, 'static.psisat', psisat(il1:il2,:))
      call sb_write_r2(sb_directory, 'static.bi', bi(il1:il2,:))
      call sb_write_i2(sb_directory, 'static.isand', isand(il1:il2,:))
      call sb_write_r1(sb_directory, 'static.zbot', zbot)
      call sb_write_r2(sb_directory, 'static.zbotw', zbotw(il1:il2,:))
      call sb_write_r2(sb_directory, 'static.delzw', delzw(il1:il2,:))
      call sb_write_i1(sb_directory, 'static.sort', sort)
      call sb_write_i1(sb_directory, 'static.spinfast', [spinfast])
      call sb_write_i1(sb_directory, 'static.mineral_mask', merge(1,0,peatlandType(il1:il2) == 'None'))
      call sb_write_i1(sb_directory, 'static.turbation_on', [merge(1,0,c_switch%turbationON)])
      call sb_write_r1(sb_directory, 'static.deltat', [deltat])
      call sb_write_r1(sb_directory, 'static.tfrez', [tfrez])
      call sb_write_r1(sb_directory, 'static.tcrit', [tcrit])
      call sb_write_r1(sb_directory, 'static.tanhq10', tanhq10)
      call sb_write_r1(sb_directory, 'static.bsratelt', bsratelt)
      call sb_write_r1(sb_directory, 'static.bsratesc', bsratesc)
      call sb_write_r1(sb_directory, 'static.bsratelt_g', [bsratelt_g])
      call sb_write_r1(sb_directory, 'static.bsratesc_g', [bsratesc_g])
      call sb_write_r1(sb_directory, 'static.r_depthredu', [r_depthredu])
      call sb_write_r1(sb_directory, 'static.frozered', [frozered])
      call sb_write_r1(sb_directory, 'static.humicfac', humicfac)
      call sb_write_r1(sb_directory, 'static.humicfac_bg', [humicfac_bg])
      call sb_write_r1(sb_directory, 'static.cryodiffus', [cryodiffus])
      call sb_write_r1(sb_directory, 'static.biodiffus', [biodiffus])
      call sb_write_r1(sb_directory, 'static.kterm', [kterm])
      call sb_write_r1(sb_directory, 'static.zero', [zero])
      call sb_write_r1(sb_directory, 'forcing.rmr', rmr(il1:il2))
      call sb_write_r2(sb_directory, 'forcing.rmrveg', rmrveg(il1:il2,:))
    end if
"""

const BEFORE_PRE_TRANSFER = raw"""
    if (sb_active > 0) then
      sb_litter_before = litrmass(il1:il2,1:iccp1,:)
      sb_soil_before = soilcmas(il1:il2,1:iccp1,:)
    end if
"""

function after_pre_transfer(prefix)
    return """
    if (sb_active > 0) then
      sb_$(prefix)_delta_litter = &
        litrmass(il1:il2,1:iccp1,:) - sb_litter_before
      sb_$(prefix)_delta_soil = &
        soilcmas(il1:il2,1:iccp1,:) - sb_soil_before
    end if
"""
end

const AFTER_HET = raw"""
    if (sb_active > 0) then
      call sb_write_r3(sb_directory, 'audit.ltresveg', ltresveg(il1:il2,1:iccp1,:))
      call sb_write_r3(sb_directory, 'audit.scresveg', scresveg(il1:il2,1:iccp1,:))
    end if
"""

const AFTER_UPDATE = raw"""
    if (sb_active > 0) then
      call sb_write_r3(sb_directory, 'audit.humtrsvg', humtrsvg(il1:il2,1:iccp1,:))
      call sb_write_r2(sb_directory, 'audit.hetrsveg', hetrsveg(il1:il2,:))
      call sb_write_r1(sb_directory, 'audit.litres', litres(il1:il2))
      call sb_write_r1(sb_directory, 'audit.socres', socres(il1:il2))
      call sb_write_r1(sb_directory, 'audit.hetrores', hetrores(il1:il2))
      call sb_write_r1(sb_directory, 'audit.soilresp', soilresp(il1:il2))
      call sb_write_r1(sb_directory, 'audit.humiftrs', humiftrs(il1:il2))
      call sb_write_r3(sb_directory, 'intermediate.after_pool_update_litrmass', litrmass(il1:il2,1:iccp1,:))
      call sb_write_r3(sb_directory, 'intermediate.after_pool_update_soilcmas', soilcmas(il1:il2,1:iccp1,:))
    end if
"""

const BEFORE_TRANSFER = raw"""
    if (sb_active > 0) then
      sb_litter_before = litrmass(il1:il2,1:iccp1,:)
      sb_soil_before = soilcmas(il1:il2,1:iccp1,:)
    end if
"""

function after_transfer(prefix)
    return """
    if (sb_active > 0) then
      call sb_write_r3(sb_directory, 'forcing.post_resp_$(prefix)_delta_litter', &
                       litrmass(il1:il2,1:iccp1,:) - sb_litter_before)
      call sb_write_r3(sb_directory, 'forcing.post_resp_$(prefix)_delta_soil', &
                       soilcmas(il1:il2,1:iccp1,:) - sb_soil_before)
    end if
"""
end

const BEFORE_TURBATION = raw"""
      if (sb_active > 0) then
        call sb_write_r3(sb_directory, 'intermediate.before_turbation_litrmass', litrmass(il1:il2,1:iccp1,:))
        call sb_write_r3(sb_directory, 'intermediate.before_turbation_soilcmas', soilcmas(il1:il2,1:iccp1,:))
        sb_litter_before = litrmass(il1:il2,1:iccp1,:)
        sb_soil_before = soilcmas(il1:il2,1:iccp1,:)
      end if
"""

const AFTER_TURBATION = raw"""
      if (sb_active > 0) then
        call sb_write_r3(sb_directory, 'audit.turbation_delta_litter', &
                         litrmass(il1:il2,1:iccp1,:) - sb_litter_before)
        call sb_write_r3(sb_directory, 'audit.turbation_delta_soil', &
                         soilcmas(il1:il2,1:iccp1,:) - sb_soil_before)
        call sb_write_r3(sb_directory, 'post.litrmass', litrmass(il1:il2,1:iccp1,:))
        call sb_write_r3(sb_directory, 'post.soilcmas', soilcmas(il1:il2,1:iccp1,:))
        if (sb_active == 3) call sb_commit_daily_snapshot(sb_event_index, iday, sb_capture_max_events)
        if (sb_active == 1) sb_ordinary_done = .true.
        if (sb_active == 2) sb_frozen_done = .true.
        sb_active = 0
      end if
"""

const HELPERS = raw"""

  subroutine sb_initialize_capture_mode(capture_all_daily, mode_initialized, capture_max_events)
    character(len=1024) :: root
    character(len=32) :: mode, max_events_text
    logical, intent(out) :: capture_all_daily, mode_initialized
    integer, intent(out) :: capture_max_events
    logical :: exists
    integer :: status, unit, parse_status
    capture_max_events = 0
    call get_environment_variable('CLASSIC_STAGE_B_CAPTURE_MODE', mode, status=status)
    if (status /= 0 .or. len_trim(mode) == 0 .or. trim(mode) == 'sparse') then
      capture_all_daily = .false.
    else if (trim(mode) == 'all_daily') then
      capture_all_daily = .true.
      call get_environment_variable('CLASSIC_STAGE_B_CAPTURE_MAX_EVENTS', max_events_text, status=status)
      if (status /= 0 .or. len_trim(max_events_text) == 0) &
        error stop 'capture max events must be a positive integer'
      read(max_events_text,*,iostat=parse_status) capture_max_events
      if (parse_status /= 0 .or. capture_max_events <= 0) &
        error stop 'capture max events must be a positive integer'
      call get_environment_variable('CLASSIC_STAGE_B_SNAPSHOT_ROOT', root, status=status)
      if (status /= 0 .or. len_trim(root) == 0) error stop 'CLASSIC_STAGE_B_SNAPSHOT_ROOT is required'
      inquire(file=trim(root)//'/daily', exist=exists)
      if (exists) error stop 'daily Stage B capture root already exists'
      call execute_command_line('mkdir -p ' // trim(root) // '/daily', exitstat=status)
      if (status /= 0) error stop 'cannot create daily Stage B capture root'
      open(newunit=unit,file=trim(root)//'/daily/event_ledger.raw',status='new',action='write')
      write(unit,'(A,I0)') 'schema_version=1 capture_mode=all_daily max_events=', capture_max_events
      flush(unit)
      close(unit)
    else
      error stop 'CLASSIC_STAGE_B_CAPTURE_MODE must be sparse or all_daily'
    end if
    mode_initialized = .true.
  end subroutine sb_initialize_capture_mode

  subroutine sb_begin_daily_snapshot(index, directory)
    integer, intent(in) :: index
    character(*), intent(out) :: directory
    character(len=1024) :: root
    character(len=8) :: event_name
    integer :: status
    call get_environment_variable('CLASSIC_STAGE_B_SNAPSHOT_ROOT', root, status=status)
    if (status /= 0 .or. len_trim(root) == 0) error stop 'CLASSIC_STAGE_B_SNAPSHOT_ROOT is required'
    write(event_name,'(I8.8)') index
    directory = trim(root) // '/daily/event_' // event_name // '.raw'
    call execute_command_line('mkdir ' // trim(directory), exitstat=status)
    if (status /= 0) error stop 'daily Stage B event already exists or cannot be created'
  end subroutine sb_begin_daily_snapshot

  subroutine sb_commit_daily_snapshot(index, iday, max_events)
    integer, intent(in) :: index, iday, max_events
    character(len=1024) :: root
    character(len=8) :: event_name
    integer :: status, unit
    call get_environment_variable('CLASSIC_STAGE_B_SNAPSHOT_ROOT', root, status=status)
    if (status /= 0 .or. len_trim(root) == 0) error stop 'CLASSIC_STAGE_B_SNAPSHOT_ROOT is required'
    write(event_name,'(I8.8)') index
    open(newunit=unit,file=trim(root)//'/daily/event_ledger.raw',status='old',position='append',action='write')
    write(unit,'(I0,1X,I0,1X,A)') index, iday, 'daily/event_' // event_name // '.raw'
    if (index == max_events) write(unit,'(A,I0,A,I0)') &
      'capture_complete events=', index, ' max_events=', max_events
    flush(unit)
    close(unit)
  end subroutine sb_commit_daily_snapshot

  subroutine sb_begin_snapshot(label, directory)
    character(*), intent(in) :: label
    character(*), intent(out) :: directory
    character(len=1024) :: root
    integer :: status
    call get_environment_variable('CLASSIC_STAGE_B_SNAPSHOT_ROOT', root, status=status)
    if (status /= 0 .or. len_trim(root) == 0) error stop 'CLASSIC_STAGE_B_SNAPSHOT_ROOT is required'
    directory = trim(root) // '/' // trim(label) // '.raw'
    call execute_command_line('mkdir -p ' // trim(directory), exitstat=status)
    if (status /= 0) error stop 'cannot create Stage B snapshot directory'
  end subroutine sb_begin_snapshot

  subroutine sb_write_r1(directory, name, value)
    character(*), intent(in) :: directory, name
    real, intent(in) :: value(:)
    integer :: unit
    if (storage_size(value) /= 64) error stop 'Stage B snapshots require Float64 CLASSIC build'
    open(newunit=unit,file=trim(directory)//'/'//trim(name)//'.bin',access='stream',form='unformatted',status='replace',convert='little_endian')
    write(unit) value
    close(unit)
    open(newunit=unit,file=trim(directory)//'/'//trim(name)//'.shape',status='replace')
    write(unit,'(I0)') size(value,1)
    close(unit)
  end subroutine sb_write_r1

  subroutine sb_write_r2(directory, name, value)
    character(*), intent(in) :: directory, name
    real, intent(in) :: value(:,:)
    integer :: unit
    if (storage_size(value) /= 64) error stop 'Stage B snapshots require Float64 CLASSIC build'
    open(newunit=unit,file=trim(directory)//'/'//trim(name)//'.bin',access='stream',form='unformatted',status='replace',convert='little_endian')
    write(unit) value
    close(unit)
    open(newunit=unit,file=trim(directory)//'/'//trim(name)//'.shape',status='replace')
    write(unit,'(I0,1X,I0)') size(value,1), size(value,2)
    close(unit)
  end subroutine sb_write_r2

  subroutine sb_write_r3(directory, name, value)
    character(*), intent(in) :: directory, name
    real, intent(in) :: value(:,:,:)
    integer :: unit
    if (storage_size(value) /= 64) error stop 'Stage B snapshots require Float64 CLASSIC build'
    open(newunit=unit,file=trim(directory)//'/'//trim(name)//'.bin',access='stream',form='unformatted',status='replace',convert='little_endian')
    write(unit) value
    close(unit)
    open(newunit=unit,file=trim(directory)//'/'//trim(name)//'.shape',status='replace')
    write(unit,'(I0,1X,I0,1X,I0)') size(value,1), size(value,2), size(value,3)
    close(unit)
  end subroutine sb_write_r3

  subroutine sb_write_i1(directory, name, value)
    character(*), intent(in) :: directory, name
    integer, intent(in) :: value(:)
    integer :: unit
    open(newunit=unit,file=trim(directory)//'/'//trim(name)//'.bin',access='stream',form='unformatted',status='replace',convert='little_endian')
    write(unit) value
    close(unit)
    open(newunit=unit,file=trim(directory)//'/'//trim(name)//'.shape',status='replace')
    write(unit,'(I0)') size(value,1)
    close(unit)
  end subroutine sb_write_i1

  subroutine sb_write_i2(directory, name, value)
    character(*), intent(in) :: directory, name
    integer, intent(in) :: value(:,:)
    integer :: unit
    open(newunit=unit,file=trim(directory)//'/'//trim(name)//'.bin',access='stream',form='unformatted',status='replace',convert='little_endian')
    write(unit) value
    close(unit)
    open(newunit=unit,file=trim(directory)//'/'//trim(name)//'.shape',status='replace')
    write(unit,'(I0,1X,I0)') size(value,1), size(value,2)
    close(unit)
  end subroutine sb_write_i2
"""

function replacement_patch(source, instrumented)
    old = split(chomp(source), '\n')
    new = split(chomp(instrumented), '\n')
    io = IOBuffer()
    println(io, "--- a/src/base/ctemDriver.F90")
    println(io, "+++ b/src/base/ctemDriver.F90")
    println(io, "@@ -1,$(length(old)) +1,$(length(new)) @@")
    foreach(line -> println(io, "-", line), old)
    foreach(line -> println(io, "+", line), new)
    return String(take!(io))
end

function generate_fortran_instrumentation(
    driver_path,
    output_directory;
    source_commit,
)
    ispath(output_directory) &&
        error("output already exists: $output_directory")
    source = read(driver_path, String)
    lines = split(chomp(source), '\n')
    use_index = findfirst(
        line -> occursin("deltat, tolrance, convertg2kg", line),
        lines,
    )
    isnothing(use_index) && error("classicParams use anchor not found")
    lines[use_index] = replace(
        lines[use_index],
        "deltat, tolrance," => "deltat, tolrance, tfrez, tcrit, tanhq10, bsratelt, bsratesc, bsratelt_g, bsratesc_g, r_depthredu, frozered, cryodiffus, biodiffus, kterm,",
    )
    declaration_anchor =
        findfirst(i -> lines[i] == "    ! inputs", eachindex(lines))
    isnothing(declaration_anchor) && error("declaration anchor not found")
    splice!(
        lines,
        declaration_anchor:(declaration_anchor - 1),
        split(DECLARATIONS, '\n'),
    )
    insert_before_condition!(lines, "PFTCompetition", BEGIN_PRE_TRANSFERS)
    for (routine, prefix) in (
        ("competition", "competition"),
        ("luc", "land_use"),
        ("harvestTile", "harvest"),
    )
        insert_before_call!(lines, routine, BEFORE_PRE_TRANSFER)
        insert_after_call!(lines, routine, after_pre_transfer(prefix))
    end
    insert_before_call!(lines, "heterotrophicRespiration", BEFORE_HET)
    insert_after_call!(lines, "heterotrophicRespiration", AFTER_HET)
    insert_after_call!(lines, "updatePoolsHetResp", AFTER_UPDATE)
    for (routine, prefix) in (
        ("updatePoolsTurnover", "turnover"),
        ("updatePoolsMortality", "mortality"),
        ("disturbance", "disturbance"),
    )
        insert_before_call!(lines, routine, BEFORE_TRANSFER)
        insert_after_call!(lines, routine, after_transfer(prefix))
    end
    insert_before_call!(lines, "turbation", BEFORE_TURBATION)
    insert_after_call!(lines, "turbation", AFTER_TURBATION)
    module_end = findlast(line -> strip(line) == "end module ctemDriver", lines)
    splice!(lines, module_end:(module_end - 1), split(HELPERS, '\n'))
    instrumented = join(lines, '\n')

    mkpath(output_directory)
    patch_path = joinpath(output_directory, "classic-stage-b-snapshots.patch")
    write(patch_path, replacement_patch(source, instrumented))
    receipt = Dict(
        "schema_version" => 1,
        "status" => "generated",
        "source_commit" => source_commit,
        "source_sha256" => bytes2hex(SHA.sha256(codeunits(source))),
        "pre_resp_transfer_capture" => "measured_at_process_calls",
        "patch_path" => basename(patch_path),
        "patch_sha256" => sha256sum(patch_path),
    )
    open(joinpath(output_directory, "instrumentation_receipt.toml"), "w") do io
        TOML.print(io, receipt; sorted = true)
    end
    return receipt
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 3 ||
        error("usage: generate_fortran_instrumentation.jl DRIVER OUTPUT COMMIT")
    generate_fortran_instrumentation(ARGS[1], ARGS[2]; source_commit = ARGS[3])
end

end
