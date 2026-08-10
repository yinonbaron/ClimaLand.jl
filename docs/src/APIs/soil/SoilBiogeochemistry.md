# Soil Biogeochemistry

## This component model is available for use, but is still under development and is not yet fully debugged. Note that errors in this component do not propagate back to other component models.

```@meta
CurrentModule = ClimaLand.Soil.Biogeochemistry
```
## Model Structure

```@docs
ClimaLand.Soil.Biogeochemistry.SoilCO2Model
ClimaLand.Soil.Biogeochemistry.CASA.CASASoilModel
ClimaLand.Soil.Biogeochemistry.MIMICS.MIMICSSoilModel
ClimaLand.Soil.Biogeochemistry.CORPSE.CORPSESoilModel
ClimaLand.Soil.Biogeochemistry.CLASSIC.CLASSICSoilModel
```

## Parameter Structure

```@docs
ClimaLand.Soil.Biogeochemistry.SoilCO2ModelParameters
ClimaLand.Soil.SoilCO2ModelParameters(toml_dict::CP.ParamDict)
ClimaLand.Soil.Biogeochemistry.CASA.CASASoilModelParameters
ClimaLand.Soil.Biogeochemistry.CASA.CASANitrogenParameters
ClimaLand.Soil.Biogeochemistry.MIMICS.CarbonParameters
ClimaLand.Soil.Biogeochemistry.MIMICS.NitrogenParameters
ClimaLand.Soil.Biogeochemistry.MIMICS.MIMICSSoilModelParameters
ClimaLand.Soil.Biogeochemistry.CORPSE.CarbonParameters
ClimaLand.Soil.Biogeochemistry.CORPSE.CORPSESoilModelParameters
ClimaLand.Soil.Biogeochemistry.CLASSIC.CLASSICParameters
```

## Model-specific Types

```@docs
ClimaLand.Soil.Biogeochemistry.MicrobeProduction
ClimaLand.Soil.Biogeochemistry.SoilCO2FluxBC
ClimaLand.Soil.Biogeochemistry.SoilO2FluxBC
ClimaLand.Soil.Biogeochemistry.SoilCO2StateBC
ClimaLand.Soil.Biogeochemistry.AtmosCO2StateBC
ClimaLand.Soil.Biogeochemistry.AtmosO2StateBC
ClimaLand.Soil.Biogeochemistry.AbstractSoilDriver
ClimaLand.Soil.Biogeochemistry.SoilDrivers
ClimaLand.Soil.Biogeochemistry.PrescribedMet
ClimaLand.Soil.Biogeochemistry.CASA.CarbonTransferParameters
ClimaLand.Soil.Biogeochemistry.CASA.PrescribedDrivers
ClimaLand.Soil.Biogeochemistry.CASA.NitrogenPrescribedDrivers
ClimaLand.Soil.Biogeochemistry.MIMICS.PrescribedDrivers
ClimaLand.Soil.Biogeochemistry.MIMICS.NitrogenPrescribedDrivers
ClimaLand.Soil.Biogeochemistry.MIMICS.TemporalMode
ClimaLand.Soil.Biogeochemistry.MIMICS.LegacyDaily
ClimaLand.Soil.Biogeochemistry.MIMICS.ContinuousRate
ClimaLand.Soil.Biogeochemistry.CORPSE.PrescribedDrivers
ClimaLand.Soil.Biogeochemistry.CORPSE.AbstractTemporalMode
ClimaLand.Soil.Biogeochemistry.CORPSE.LegacyDaily
ClimaLand.Soil.Biogeochemistry.CORPSE.ContinuousRate
ClimaLand.Soil.Biogeochemistry.CLASSIC.CLASSICState
ClimaLand.Soil.Biogeochemistry.CLASSIC.StageBTransfer
ClimaLand.Soil.Biogeochemistry.CLASSIC.CLASSICForcing
ClimaLand.Soil.Biogeochemistry.CLASSIC.CLASSICAudit
ClimaLand.Soil.Biogeochemistry.CLASSIC.CLASSICPhases
ClimaLand.Soil.Biogeochemistry.CLASSIC.CLASSICTransition
ClimaLand.Soil.Biogeochemistry.CLASSIC.ConstantForcingProvider
ClimaLand.Soil.Biogeochemistry.CLASSIC.PrescribedDailyForcingProvider
```

## Functions of State

```@docs
ClimaLand.Soil.Biogeochemistry.volumetric_air_content
ClimaLand.Soil.Biogeochemistry.co2_diffusivity
ClimaLand.Soil.Biogeochemistry.o2_diffusivity
ClimaLand.Soil.Biogeochemistry.microbe_source
ClimaLand.Soil.Biogeochemistry.o2_availability
ClimaLand.Soil.Biogeochemistry.o2_concentration
ClimaLand.Soil.Biogeochemistry.o2_fraction_from_concentration
ClimaLand.Soil.Biogeochemistry.henry_constant
ClimaLand.Soil.Biogeochemistry.beta_gas
ClimaLand.Soil.Biogeochemistry.effective_porosity
```

## CASA Functions of State

```@docs
ClimaLand.Soil.Biogeochemistry.CASA.legacy_root_fractions
ClimaLand.Soil.Biogeochemistry.CASA.root_weighted_mean
ClimaLand.Soil.Biogeochemistry.CASA.temperature_factor
ClimaLand.Soil.Biogeochemistry.CASA.moisture_factor
ClimaLand.Soil.Biogeochemistry.CASA.environmental_factors
ClimaLand.Soil.Biogeochemistry.CASA.decomposition_rates
ClimaLand.Soil.Biogeochemistry.CASA.transfer_fractions
ClimaLand.Soil.Biogeochemistry.CASA.carbon_tendencies
ClimaLand.Soil.Biogeochemistry.CASA.nitrogen_limitation
ClimaLand.Soil.Biogeochemistry.CASA.new_soil_nitrogen_ratios
ClimaLand.Soil.Biogeochemistry.CASA.nitrogen_tendencies
```

## MIMICS Functions of State

```@docs
ClimaLand.Soil.Biogeochemistry.MIMICS.moisture_factor
ClimaLand.Soil.Biogeochemistry.MIMICS.environmental_parameters
ClimaLand.Soil.Biogeochemistry.MIMICS.hourly_carbon_map
ClimaLand.Soil.Biogeochemistry.MIMICS.daily_carbon_map
ClimaLand.Soil.Biogeochemistry.MIMICS.hourly_carbon_nitrogen_map
ClimaLand.Soil.Biogeochemistry.MIMICS.daily_carbon_nitrogen_map
ClimaLand.Soil.Biogeochemistry.MIMICS.continuous_carbon_fluxes
```

## CORPSE Functions of State

```@docs
ClimaLand.Soil.Biogeochemistry.CORPSE.cohort_carbon
ClimaLand.Soil.Biogeochemistry.CORPSE.add_litter
ClimaLand.Soil.Biogeochemistry.CORPSE.add_exudate
ClimaLand.Soil.Biogeochemistry.CORPSE.moisture_factor
ClimaLand.Soil.Biogeochemistry.CORPSE.mineral_protection_capacity
ClimaLand.Soil.Biogeochemistry.CORPSE.update_cohort
ClimaLand.Soil.Biogeochemistry.CORPSE.daily_carbon_map
ClimaLand.Soil.Biogeochemistry.CORPSE.continuous_cohort_tendencies
ClimaLand.Soil.Biogeochemistry.CORPSE.continuous_carbon_fluxes
```

## CLASSIC Constants

```@docs
ClimaLand.Soil.Biogeochemistry.CLASSIC.N_PFTS
ClimaLand.Soil.Biogeochemistry.CLASSIC.N_CATEGORIES
ClimaLand.Soil.Biogeochemistry.CLASSIC.N_SOIL_LAYERS
ClimaLand.Soil.Biogeochemistry.CLASSIC.N_PARAMETER_PFTS
```

## CLASSIC Functions

```@docs
ClimaLand.Soil.Biogeochemistry.CLASSIC.classic_domain
ClimaLand.Soil.Biogeochemistry.CLASSIC.forcing_at
ClimaLand.Soil.Biogeochemistry.CLASSIC.advance!
ClimaLand.Soil.Biogeochemistry.CLASSIC.advance_stage_b
ClimaLand.Soil.Biogeochemistry.CLASSIC.state_from_prognostic
ClimaLand.Soil.Biogeochemistry.CLASSIC.set_prognostic_state!
```

## CLASSIC Developer Interface

```@docs
ClimaLand.Soil.Biogeochemistry.CLASSIC.advance_stage_b!
ClimaLand.Soil.Biogeochemistry.CLASSIC._respiration!
ClimaLand.Soil.Biogeochemistry.CLASSIC._update_pools_cached!
ClimaLand.Soil.Biogeochemistry.CLASSIC._solve_mixing!
ClimaLand.Soil.Biogeochemistry.CLASSIC._mix_column_cached!
ClimaLand.Soil.Biogeochemistry.CLASSIC._turbate!
ClimaLand.Soil.Biogeochemistry.CLASSIC.DailyAdvance
```

## Extendible Functions

```@docs
ClimaLand.Soil.Biogeochemistry.soil_moisture
ClimaLand.Soil.Biogeochemistry.soil_temperature
ClimaLand.Soil.Biogeochemistry.soil_ice
```
