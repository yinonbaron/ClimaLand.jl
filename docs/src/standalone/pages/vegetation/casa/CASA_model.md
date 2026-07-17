# CASA plant carbon and nitrogen

The standalone `CASAPlantModel` ports the plant module from the soil
biogeochemical testbed. `CarbonOnly()` retains prescribed tissue nitrogen;
`CarbonNitrogen()` adds prognostic tissue nitrogen, mineral-N uptake,
retranslocation, and litter-N production. The model can be stepped on its own
and is the common plant component for CASA, MIMICS, and CORPSE soil
configurations.

The `LegacyDaily` implementation follows the pinned Fortran routines `casa_rplant`,
`casa_allocation`, `casa_xrateplant`, `casa_coeffplant`, `casa_delplant`, and
the plant part of `casa_cnpcycle`. The parity configuration uses the testbed's
fixed carbon allocation mode. Dynamic and Wolf allocation are not part of the
reference runs.

## State and units

All stocks are column-integrated surface fields.

| State | Meaning | Unit |
|---|---|---|
| `c_leaf` | live leaf carbon | kg C m⁻² |
| `c_wood` | live wood carbon | kg C m⁻² |
| `c_fine_root` | live fine-root carbon | kg C m⁻² |
| `c_labile` | labile plant carbon | kg C m⁻² |
| `n_leaf` | live leaf nitrogen (CN mode) | kg N m⁻² |
| `n_wood` | live wood nitrogen (CN mode) | kg N m⁻² |
| `n_fine_root` | live fine-root nitrogen (CN mode) | kg N m⁻² |

Rates and fluxes use seconds and kg C m⁻² s⁻¹ internally. Legacy
per-year and g C m⁻² values are converted at input boundaries.

## Prescribed drivers

`PrescribedDrivers` supplies functions of simulation time for GPP, air and
root-zone soil temperature, soil-water stress (`btran`), prescribed phenology
phase (0--3), the NPP perturbation scalar, and the fraction of GPP sent to the
labile pool. Reference experiments prescribe these values. The
`CASAPlantEnergyHydrologyModel` adapter replaces root-zone temperature and
water stress with root-weighted native soil fields. Coupling GPP to native
canopy photosynthesis remains a post-parity task.

## Autotrophic respiration

The temperature response for wood and fine-root maintenance respiration is

```math
f_T(T) = \exp\left[308.56\left(\frac{1}{56.02} -
\frac{1}{T + 46.02 - T_0}\right)\right],
```

where ``T_0`` is the freezing temperature. Wood uses air temperature and fine
roots use root-zone soil temperature:

```math
R_{m,i} = r_{m,i} N_i f_T(T_i).
```

The carbon-only testbed keeps plant N fixed for this calculation. Growth
efficiency, growth respiration, and NPP are

```math
Y_g = 0.65 + 0.2\frac{P_{leaf}/N_{leaf}}
{P_{leaf}/N_{leaf} + 1/15},
```

```math
R_g = (1-Y_g)\max(0, GPP-R_m), \qquad
NPP = GPP - R_m - R_g.
```

As in the pinned routine, leaf maintenance respiration is zero. Carbon-only
plant N and leaf P:N are parameters. In CN mode the three tissue-N stocks are
prognostic and supply the respiration calculation.

## Allocation and phenology

Configured leaf, wood, and fine-root allocation fractions are normalized. The
testbed then applies, in order, the phase 0, phase 1, phase 3, maximum-LAI,
minimum-LAI, and negative-NPP overrides. Phase 1 sends 80% to leaves; phases 0
and 3 send none. Negative NPP is distributed in proportion to tissue
maintenance respiration.

LAI is diagnosed from current leaf carbon:

```math
LAI = \min(LAI_{max}, \max(LAI_{min}, SLA\,C_{leaf})).
```

## Turnover and tendencies

Cold stress uses the corrected five-kelvin linear transition in the pinned
Fortran source. Drought stress is a power of ``1-btran``:

```math
k_{leaf} = k_{leaf,0} I_{phase\ne1} +
k_{cold,max}(1-x_{cold})^{e_{cold}} +
k_{dry,max}(1-btran)^{e_{dry}}.
```

Leaf turnover is zero at minimum LAI. Wood and fine roots use their base
rates. For tissue ``i``:

```math
\frac{dC_i}{dt} = a_i NPP - k_i C_i.
```

The model retains each tissue turnover flux separately. A plant-soil model can
therefore apply the litter-quality rules of CASA, MIMICS, or CORPSE without
changing the plant equations. The labile tendency is

```math
\frac{dC_{labile}}{dt} = f_{labile}(GPP-C_{exudate}) -
k_{labile}C_{labile}f_T.
```

Root exudation defaults to zero, matching the accepted carbon reference.

## Carbon-nitrogen mode

Construct CN mode with `configuration = CarbonNitrogen()`, a
`CASAPlantNitrogenParameters` value or surface field, and
`NitrogenPrescribedDrivers`. The standalone nitrogen drivers provide the
mineral-N stock, the plant demand fraction, and the CASA limitation scalar.
In an integrated model these quantities are supplied by the selected soil
component, which remains the single mineral-N owner.

The demand fraction interpolates between configured minimum and maximum
tissue N:C ratios. `nitrogen_uptake` combines that demand with mineral-N
availability and retranslocation from senescing tissue. Tissue-N tendencies
are uptake minus turnover. Leaf and fine-root turnover are divided between
metabolic and structural litter using the testbed lignin:N rule; wood turnover
enters CWD-N. MIMICS coupling instead applies its bounded plant C:N rule and
input-weighted metabolic quality. All litter and uptake transfers are
equal-and-opposite between plant and soil tendencies.

## Temporal formulations

`CASAPlantModel` has two compile-time temporal modes. The default,
`temporal_mode = LegacyDaily()`, preserves the reference testbed map. It
computes carbon and nitrogen deltas from the state at the beginning of the
day, applies the plant-carbon update first, updates tissue nitrogen only when
the resulting leaf-carbon pool is positive, and resets negative tissue C and N
to zero. In ClimaLand this map is exposed as

```math
\dot Y = \frac{\Phi_{day}(Y)-Y}{86400}.
```

Use `LegacyDaily` only with Forward Euler and `dt = 86400` seconds. A smaller
timestep or a multistage solver reevaluates a map that was defined to run once
per day and therefore does not retain archive semantics. The legacy bounds are
part of parity, not a general positivity treatment; when activated they can
discard mass just as the pinned source does.

`temporal_mode = ContinuousRate()` selects the timestep-independent ODE. GPP,
respiration, allocation, turnover, litter production, exudation, nutrient
demand, mineral-N uptake, and tissue tendencies are all evaluated in SI rates
from one current state. No hidden day, within-call state update, or generic
pool clamp enters this RHS. Choose an ODE solver and timestep from accuracy and
stability tests for the intended forcing and parameter range. Explicit Euler
refinement from 86400 to 2700 seconds over the committed 30-day representative
case converges monotonically; the 2700-second solution is `2.50825e-4` relative
L1 from the daily legacy map.

## Cache contract

`p.casa_plant.carbon_fluxes` is a static GPU-compatible vector.

| Entries | Quantity |
|---|---|
| 1--4 | leaf, wood, fine-root, and labile tendencies |
| 5--7 | leaf, wood, and fine-root allocation fractions |
| 8--10 | leaf, wood, and fine-root turnover fluxes |
| 11--13 | leaf, wood, and fine-root turnover rates |
| 14--15 | GPP and NPP |
| 16--18 | total, maintenance, and growth respiration |
| 19--21 | LAI, root exudation, and labile loss |

## Standalone stepping

```julia
import ClimaTimeSteppers as CTS
using ClimaLand
using ClimaLand.Vegetation

const CASA = Vegetation.CASA
model = CASA.CASAPlantModel{Float64}(;
    parameters,
    drivers,
    domain,
    temporal_mode = CASA.LegacyDaily(),
)
Y, p, _ = initialize(model)

# Set the four fields in Y.casa_plant before stepping.
tendency! = make_exp_tendency(model)
problem = CTS.ODEProblem(
    CTS.ClimaODEFunction((T_exp!) = tendency!),
    Y,
    (0.0, 86400.0),
    p,
)
forward_euler = CTS.ExplicitAlgorithm(
    CTS.ExplicitTableau(;
        a = zeros(Int, 1, 1),
        b = ones(Int, 1),
        c = zeros(Int, 1),
    ),
)
integrator = CTS.init(problem, forward_euler; dt = 86400.0)
CTS.step!(integrator)
```

A one-day Euler step applies the complete `LegacyDaily` map while drivers
remain fixed. For a normal ODE solve, construct the model with
`temporal_mode = CASA.ContinuousRate()` and select the timestep independently.

## Spatial PFT parameters and accelerators

`CASAPlantModel` accepts either one `CASAPlantModelParameters` value or a
surface `ClimaCore.Fields.Field` of those point values. A field can hold the
complete gridded PFT parameter set, including allocation, turnover,
respiration, LAI limits, phenology response, and the nonwoody flag. Its axes
must equal `domain.space.surface`. The existing point kernel is broadcast over
that field without scalar indexing and follows ClimaLand's active CPU or GPU
backend.

## Diagnostics and restart

`ClimaLand.Diagnostics.default_diagnostics` supports the standalone model and
the integrated CASA plant-soil models. All four plant carbon states are
available as `casa_plant_c_leaf`, `casa_plant_c_wood`,
`casa_plant_c_fine_root`, and `casa_plant_c_labile`. Registered fluxes include
GPP, NPP, autotrophic respiration, leaf/wood/root litter, root exudation, and
LAI, all with the `casa_plant_` prefix. CN mode also registers the three
tissue-N states, metabolic/structural/CWD litter-N fluxes, and mineral-N
uptake.

The normal `ClimaLand.save_checkpoint` and
`set_initial_conditions_from_checkpoint!` workflow preserves every plant
state. The same interface works on point and gridded domains.

## Validation boundary

Scalar kernels are tested in `Float32` and `Float64` for inference, no hot-path
allocation, rule ordering, turnover limits, and carbon conservation. The field
model is tested with ClimaLand initialization, native Euler stepping,
heterogeneous PFT parameter fields, diagnostics, and checkpoint restart. Full
productive-cell archive parity still depends on the unpublished spinup restart
and its exact plant initialization. CN plant states and fluxes reproduce 364
productive-cell daily transitions and pass coupled CASA- and MIMICS-soil
nitrogen conservation gates.

Phosphorus, dynamic allocation, and native canopy GPP remain post-parity tasks.
