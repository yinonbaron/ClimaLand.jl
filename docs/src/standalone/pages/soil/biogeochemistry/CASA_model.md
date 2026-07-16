# CASA soil carbon and nitrogen model

`CASASoilModel` is the CASA soil component of the
[soil biogeochemical testbed](https://github.com/wwieder/biogeochem_testbed).
It is a standalone ClimaLand model with surface-integrated litter and soil
carbon pools. Its compile-time `CarbonOnly` configuration preserves the
six-field carbon layout; `CarbonNitrogen` adds organic and mineral nitrogen.
The standalone CASA plant CN component, plant-to-soil CN coupling, and native
root-weighted `EnergyHydrology` driver coupling are also implemented.

## State and units

All prognostic fields live on the surface domain and use kg C m⁻².

| Field | Pool |
|---|---|
| `c_litter_metabolic` | Metabolic litter |
| `c_litter_structural` | Structural litter |
| `c_litter_cwd` | Coarse woody debris |
| `c_soil_microbial` | Microbial or fast soil carbon |
| `c_soil_slow` | Slow soil carbon |
| `c_soil_passive` | Passive soil carbon |

With `configuration = CarbonNitrogen()`, the model additionally owns these
surface fields in kg N m⁻²:

| Field | Pool |
|---|---|
| `n_litter_metabolic` | Metabolic litter nitrogen |
| `n_litter_structural` | Structural litter nitrogen |
| `n_litter_cwd` | Coarse-woody-debris nitrogen |
| `n_soil_microbial` | Microbial soil organic nitrogen |
| `n_soil_slow` | Slow soil organic nitrogen |
| `n_soil_passive` | Passive soil organic nitrogen |
| `n_mineral` | Plant-available mineral nitrogen |

The prescribed drivers are root-zone soil temperature in K, root-zone liquid
water as a volumetric fraction, and metabolic, structural, and CWD inputs in
kg C m⁻² s⁻¹. Turnover parameters use s⁻¹.

Reference preprocessing uses `legacy_root_fractions` and
`root_weighted_mean`. For parity, `legacy_root_fractions` retains a testbed
indexing behavior in which each layer thickness is treated as a lower depth
and the preceding thickness as its upper depth, instead of first accumulating
the layer thicknesses. Liquid water is capped at field capacity separately in
each layer before root weighting. Native `EnergyHydrology` coupling instead
normalizes an exponential root-density profile over the represented ClimaLand
soil column. It does not reproduce the legacy six-layer preprocessing rule;
that distinction is explicit at the driver boundary.

## Environmental response

The relative saturation is

```math
\theta = \min\left(1, \frac{\theta_l}{\nu}\right),
```

where ``\theta_l`` is the prescribed root-zone liquid-water fraction and
``\nu`` is porosity. The temperature response is normalized at 35 °C:

```math
f_T = Q_{10}^{0.1(T - T_0 - 35)}.
```

For non-cropland points, the moisture response is

```math
f_W =
\left(\frac{\theta - 1.70}{0.55 - 1.70}\right)^{6.6481}
\left(\frac{\theta + 0.007}{0.55 + 0.007}\right)^{3.22}.
```

The testbed sets ``f_W=1`` for cropland and cropland-mosaic points. Litter and
soil rate multipliers are respectively
``k_{L,\mathrm{opt}} f_T f_W`` and
``k_{S,\mathrm{opt}} f_T f_W``. Structural-litter decomposition receives the
additional lignin factor ``\exp(-3 L_{leaf})``; microbial decomposition also
receives the texture factor ``1 - 0.75(f_{clay}+f_{silt})``.
Only cropland receives the legacy 1.25 microbial and 1.5 slow/passive turnover
multipliers; cropland mosaic receives constant moisture without those turnover
multipliers. `constant_moisture` and `is_cropland` represent these independent
rules.

## Carbon transfers

Every source-pool loss is divided among receiving pools and heterotrophic
respiration. The receiving-pool fractions reproduce the testbed equations:

- metabolic litter to microbial soil;
- structural litter to microbial and slow soil, partitioned by leaf lignin;
- CWD to microbial and slow soil, partitioned by wood lignin;
- microbial soil to slow and passive soil, modified by clay and silt;
- slow soil to passive soil.

The untransferred fraction is emitted as heterotrophic respiration. Therefore,
for litter input ``I_C`` and the combined litter and soil stock ``C``,

```math
\frac{dC}{dt} = I_C - R_h.
```

The implementation tests this identity independently for `Float32` and
`Float64`.

## Nitrogen processes

`CarbonNitrogen` applies the Fortran calculation order at every point. Mineral
N controls a linear litter-decomposition multiplier between configured lower
and upper thresholds; excess fine litter plus CWD removes that limitation.
New microbial, slow, and passive material receives an N:C ratio interpolated
between configured bounds using mineral N. Litter and soil N released by
decomposition is mineralized, while N required by receiving soil pools is
immobilized.

The mineral pool gains net mineralization, deposition, and fixation and loses
plant uptake, gaseous loss, and leaching. In native units,

```math
\frac{d}{dt}(N_L + N_S + N_{min}) =
I_{N,L} + D_N + F_N - U_N - L_{gas} - L_{leach}.
```

Plant uptake is prescribed for standalone runs and supplied by `CASAPlantModel`
in coupled CN runs. `CASANitrogenParameters` uses kg N m⁻² thresholds, kg C m⁻²
litter maxima, dimensionless N:C ratios and loss fraction, and s⁻¹ leaching.
`NitrogenPrescribedDrivers` supplies the three litter-N inputs, deposition,
fixation, and uptake in kg N m⁻² s⁻¹.

A CN model is constructed by adding the compile-time configuration and
nitrogen inputs:

```julia
nitrogen_parameters = CASANitrogenParameters{FT}(;
    limitation_minimum = 0.5e-3,
    limitation_maximum = 2e-3,
    maximum_fine_litter = 0.157,
    maximum_cwd = 0.107,
    soil_nitrogen_ratio_minimum = (1 / 8, 1 / 20, 1 / 20),
    soil_nitrogen_ratio_maximum = (1 / 6.17, 1 / 16.63, 1 / 16.63),
    loss_threshold = 2e-3,
    loss_fraction = 0.05,
    leach_rate = (10 * 0.05 / 365) / day,
)
nitrogen_drivers = NitrogenPrescribedDrivers(
    t -> 1e-9, t -> 2e-9, t -> 3e-9,
    t -> 4e-10, t -> 5e-10, t -> 6e-10,
)
model = CASASoilModel{FT}(;
    configuration = CarbonNitrogen(),
    parameters,
    nitrogen_parameters,
    drivers,
    nitrogen_drivers,
)
```

## Legacy daily stepping

The testbed applies one ordered update per day. `CASASoilModel` expresses that
map as an explicit tendency in SI units. With turnover fractions divided by
86,400 s, a native ClimaTimeSteppers forward-Euler step of 86,400 s applies
the same daily update.

```julia
using ClimaLand
using ClimaLand.Soil.Biogeochemistry.CASA
import ClimaTimeSteppers as CTS

FT = Float64
day = FT(86400)

transfers = CarbonTransferParameters{FT}(;
    lignin_leaf = 0.2,
    lignin_wood = 0.4,
    cue_metabolic_to_microbial = 0.45,
    cue_structural_to_microbial = 0.45,
    cue_structural_to_slow = 0.7,
    cue_cwd_to_microbial = 0.4,
    cue_cwd_to_slow = 0.7,
    cue_microbial_to_slow = 1.0,
    cue_microbial_to_passive = 1.0,
    cue_slow_to_passive = 0.45,
)

parameters = CASASoilModelParameters{FT, typeof(transfers)}(;
    q10 = 1.72,
    litter_optimum = 0.4,
    soil_optimum = 0.1034,
    porosity = 0.41312,
    clay = 0.21805,
    silt = 0.13224,
    freezing_temperature = 273.15,
    litter_base_rates = 1 ./ (day .* (365 .* (0.04, 0.23, 0.824))),
    soil_base_rates = 1 ./ (day .* (365 .* (0.137, 5.0, 222.22))),
    transfers,
)

drivers = PrescribedDrivers(
    t -> 280.0,  # soil temperature
    t -> 0.20,   # liquid-water fraction
    t -> 1e-7,   # metabolic litter input
    t -> 2e-7,   # structural litter input
    t -> 3e-7,   # CWD input
)

model = CASASoilModel{FT}(; parameters, drivers)
Y, p, _ = initialize(model)
Y.casa_soil.c_litter_metabolic .= 0.02
Y.casa_soil.c_litter_structural .= 0.03
Y.casa_soil.c_litter_cwd .= 0.04
Y.casa_soil.c_soil_microbial .= 0.5
Y.casa_soil.c_soil_slow .= 6.0
Y.casa_soil.c_soil_passive .= 7.0

tendency! = make_exp_tendency(model)
problem = CTS.ODEProblem(
    CTS.ClimaODEFunction((T_exp!) = tendency!),
    Y,
    (0.0, day),
    p,
)
forward_euler = CTS.ExplicitAlgorithm(
    CTS.ExplicitTableau(;
        a = zeros(Int, 1, 1),
        b = ones(Int, 1),
        c = zeros(Int, 1),
    ),
)
integrator = CTS.init(problem, forward_euler; dt = day)
CTS.step!(integrator)
```

## Spatial parameters and accelerators

`parameters` may be either one `CASASoilModelParameters` value or a surface
`ClimaCore.Fields.Field` whose elements are `CASASoilModelParameters`. The
latter represents PFT, texture, porosity, and rate maps without scalar indexing
or host-side parameter lookup. For example, given two complete point parameter
sets:

```julia
using ClimaCore

x = Fields.coordinate_field(domain.space.surface).x
parameter_field = @. ifelse(x < 1, forest_parameters, crop_parameters)
model = CASASoilModel{FT}(; parameters = parameter_field, drivers, domain)
```

The field must use `domain.space.surface`; the constructor checks this. The
same point kernel is broadcast over scalar and spatial parameters, so the
field path follows ClimaLand's active CPU or GPU backend.

## Diagnostics and restart

The cache stores temperature, relative saturation, ``f_T``, ``f_W``, and the
three litter inputs. `p.casa_soil.carbon_fluxes` is a static vector containing,
in order, the six pool tendencies, heterotrophic respiration, and passive-soil
input.

Every carbon and nitrogen pool is registered with ClimaLand diagnostics under its component
and field name, for example `casa_soil_c_litter_metabolic` and
`casa_soil_c_soil_passive`. Heterotrophic respiration, passive-pool input, and
the three litter inputs are also registered. Standard ClimaLand checkpoint
files preserve all prognostic pools and can initialize either a standalone or
coupled run. CN diagnostic and checkpoint round-trip tests cover the full
13-state layout.

## Validation status

The environmental kernels reproduce 365 archived productive-cell daily values
exactly at NetCDF `Float32` precision. Across 364 active-pool transitions, the
maximum measured relative differences are ``1.85\times10^{-7}`` for soil
pools, ``1.67\times10^{-4}`` for respiration, and
``3.39\times10^{-4}`` for passive input. These comparisons start from archived
rounded states; full historical initialization remains blocked by an
unpublished spinup restart.

The external grid-transition workflow selects 20 cells covering every
productive archived PFT plus temperature, liquid-saturation, clay, and inactive
boundary extremes. Across 7,280 first-year transitions, maximum relative
errors are ``1.13\times10^{-7}`` for soil pools, ``1.41\times10^{-7}`` for
heterotrophic respiration, and ``1.76\times10^{-7}`` for passive-pool input.
These are measurements, not newly adopted tolerance thresholds.

For CASA CN, the productive fixture validates 364 transitions for soil-organic
N, mineral N, mineralization, immobilization, gaseous loss, and leaching. A
native 86,400-s Forward Euler step reproduces the archived next state, and the
one-year replay checks all 13 states. The published structural litter-N input
diagnostic is excluded as an oracle because its Fortran accumulator is used
without initialization; this limitation and the resulting replay tolerance are
recorded in the CN reference audit.

Scalar and native spatial parameter fields, CN diagnostics/restart, and
plant-soil mineral-N ownership are implemented. The CN archive-grid workflow
validates 6,916 active transitions across 19 representative productive cells,
with maximum pool relative error below ``2.7\times10^{-7}``. One additional
ice/water cell records the driver-mask boundary and is excluded from the
standalone soil-map metrics because the Fortran driver pins its state. Native
root-weighted soil-physics drivers are available through
`CASAPlantEnergyHydrologyModel`.
