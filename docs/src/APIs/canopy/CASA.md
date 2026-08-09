# CASA plant carbon and nitrogen

```@meta
CurrentModule = ClimaLand.Vegetation.CASA
```

## Model and drivers

```@docs
CASAPlantModel
CASAPlantModelParameters
CASAPlantNitrogenParameters
PrescribedDrivers
NitrogenPrescribedDrivers
CarbonOnly
CarbonNitrogen
AbstractTemporalMode
LegacyDaily
ContinuousRate
```

## Carbon kernels

```@docs
temperature_response
respiration_fluxes
leaf_area_index
allocation_fractions
senescence_rates
carbon_fluxes
```

## Nitrogen and litter-quality kernels

```@docs
nitrogen_supply
nitrogen_uptake
nitrogen_fluxes
plant_litter_fractions
mimics_plant_litter_fractions
mimics_litter_quality
```
