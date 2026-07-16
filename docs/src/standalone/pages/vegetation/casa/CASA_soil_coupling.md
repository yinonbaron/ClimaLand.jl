# Coupling CASA vegetation to soil biogeochemistry

`CASAPlantSoilModel` composes a `CASAPlantModel` with one
`CASASoilModel`, `MIMICSSoilModel`, or `CORPSESoilModel`. It uses ClimaLand's
standard `AbstractLandModel` initialization, cache, tendency, and
ClimaTimeSteppers paths.

## Litter exchange

The plant model computes leaf, wood, and fine-root turnover before the
inter-component boundary-flux update. `LitterCouplingParameters` partitions
leaf and root turnover between metabolic/labile and
structural/recalcitrant litter:

```math
I_{met} = f_{leaf}F_{leaf} + f_{root}F_{root},
```

```math
I_{str} = (1-f_{leaf})F_{leaf} + (1-f_{root})F_{root}.
```

Wood turnover enters CWD. For CORPSE, CASA root exudate enters the
rhizosphere labile pool. Carbon-only CASA soil and MIMICS currently require
zero root exudation because those parity configurations do not have an
exudate receiver.

In carbon-nitrogen mode, plant and soil nutrient configurations must match.
Plant litter-N and mineral-N uptake are copied into preallocated coupling
fields, and the selected soil component remains the single mineral-N owner.
CASA uses its dynamic lignin:N litter partition. MIMICS applies its bounded
plant C:N rule, dynamically computes input-weighted metabolic quality, and
routes CWD-N loss into structural litter.

Without prognostic soil physics, soil temperature and moisture come from the
selected BGC model's prescribed drivers. For MIMICS, annual NPP and the litter
quality scalar remain prescribed in carbon-only mode. CN coupling replaces
litter quality with the live plant/CWD calculation.

## Construction and stepping

Construct the plant and selected soil standalone models on the same domain,
then wrap them:

```julia
coupling = LitterCouplingParameters{FT}(;
    leaf_metabolic_fraction = FT(0.56),
    root_metabolic_fraction = FT(0.557),
)

land = CASAPlantSoilModel{FT}(plant, soil, coupling)
Y, p, _ = initialize(land)
tendency! = make_exp_tendency(land)
make_set_initial_cache(land)(p, Y, zero(FT))

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

## Native soil energy and hydrology drivers

Construct the plant and BGC models on the same vertically resolved domain as
an `EnergyHydrology` model, then wrap the already-coupled model:

```julia
coupled_bgc = CASAPlantSoilModel{FT}(plant, bgc_soil, coupling)
land = CASAPlantEnergyHydrologyModel{FT}(
    energy_hydrology,
    coupled_bgc;
    rooting_depth = FT(0.5),
)
```

`rooting_depth` is the exponential e-folding depth in metres and may be a
scalar or a surface `Field`. The integrated model normalizes the root-density
profile over the represented soil column, then computes root-weighted soil
temperature, volumetric liquid water, liquid saturation, and frozen
saturation. Root-weighted liquid saturation drives CASA drought stress; CASA
soil receives temperature and volumetric liquid water, while MIMICS and CORPSE
receive temperature plus liquid and frozen saturation. Litter, CWD, and
mineral-N exchange use the same preallocated coupling fields as the
prescribed-driver model.

The returned components are `soil`, `casa_plant`, and one of `casa_soil`,
`mimics_soil`, or `corpse_soil`. ClimaLand therefore assembles their explicit
and implicit tendencies and component diagnostics through the normal
`AbstractLandModel` interfaces. The state layout also follows the standard
checkpoint interface. Standalone and integrated checkpoint round trips are
validated for CASA, MIMICS, and CORPSE, including carbon-nitrogen states. On
`ColumnGrid` and rectilinear latitude-longitude vertical domains, ClimaLand
stores field values independently of the unsupported ClimaCore grid reader and
restores them onto an equivalent initialized domain without dropping state.

For a PFT mosaic, `coupling` may instead be a surface
`ClimaCore.Fields.Field` of `LitterCouplingParameters`. Its axes must match the
shared model surface space. This makes leaf and root litter quality vary with
the plant and soil parameter maps. The CASA and MIMICS constructors also check
the complete plant parameter field for root exudation using backend and
communicator reductions, rather than assuming one scalar PFT.

The returned concrete model has components named `casa_plant` and one of
`casa_soil`, `mimics_soil`, or `corpse_soil`. Their states and caches retain
the same names used by the standalone models. Coupled litter exchange is
stored in preallocated surface auxiliary fields and is safe for field and GPU
broadcast execution.
