program corpse_one_day
    use corpse_soil_carbon
    implicit none

    type(soil_carbon_pool) :: pool
    real :: fast_loss, slow_loss, dead_loss, carbon_dioxide
    real :: dead_produced
    real :: protected_produced(3), protected_turnover(3)
    real :: dissolved(3), deposited(3)
    character(len = 1024) :: parameter_file
    integer :: index

    call get_command_argument(1, parameter_file)
    if (len_trim(parameter_file) == 0) stop "missing CORPSE namelist"
    call read_soil_carbon_namelist(trim(parameter_file))
    call init_soil_carbon(pool, Qmax = 0.05, max_cohorts = 2)

    pool%litterCohorts(1)%litterC = (/0.2, 1.3, 0.05/)
    pool%litterCohorts(1)%protectedC = (/0.01, 0.2, 0.03/)
    pool%litterCohorts(1)%livingMicrobeC = 0.02
    pool%litterCohorts(1)%CO2 = 0.4
    pool%litterCohorts(1)%originalLitterC = 2.21

    call update_pool(&
        pool = pool, &
        T = 283.15, &
        theta_liq = 0.3, &
        air_filled_porosity = 0.4, &
        liquid_water = 0.3, &
        frozen_water = 0.0, &
        dt = 1.0 / 365.0, &
        layerThickness = 0.15, &
        fast_C_loss_rate = fast_loss, &
        slow_C_loss_rate = slow_loss, &
        deadmic_C_loss_rate = dead_loss, &
        CO2prod = carbon_dioxide, &
        deadmic_produced = dead_produced, &
        protected_produced = protected_produced, &
        protected_turnover_rate = protected_turnover, &
        C_dissolved = dissolved, &
        deposited_C = deposited, &
        npt = 1, &
        doy = 1, &
        hr = 1 &
    )

    do index = 1, 3
        write(*, '(ES24.16)') pool%litterCohorts(1)%litterC(index)
    end do
    do index = 1, 3
        write(*, '(ES24.16)') pool%litterCohorts(1)%protectedC(index)
    end do
    write(*, '(ES24.16)') pool%litterCohorts(1)%livingMicrobeC
    write(*, '(ES24.16)') pool%litterCohorts(1)%CO2
    write(*, '(ES24.16)') pool%litterCohorts(1)%originalLitterC
    write(*, '(ES24.16)') carbon_dioxide
end program corpse_one_day
