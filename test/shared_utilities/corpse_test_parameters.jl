module TestCORPSEParameters

import ClimaLand

const CORPSE = ClimaLand.Soil.Biogeochemistry.CORPSE

function corpse_carbon_parameters(::Type{FT}) where {FT}
    return CORPSE.CarbonParameters{FT}(;
        vmax_reference = FT.((1000, 25, 400)),
        activation_energy = FT.((5000, 30000, 3000)),
        michaelis_constant = FT.((0.01, 0.01, 0.01)),
        minimum_microbe_fraction = FT(0.001),
        microbe_turnover_time = FT(0.25),
        uptake_efficiency = FT.((0.6, 0.05, 0.6)),
        protection_rate = FT(1.5),
        protection_species = FT.((0.11, 0.002, 1)),
        protected_turnover_time = FT(75),
        protected_decomposition_factor = zero(FT),
        turnover_efficiency = FT(0.6),
        enzyme_fraction = one(FT),
        turnover_factor = FT.((1, 1, 1)),
        gas_diffusion_exponent = FT(2.5),
        minimum_anaerobic_factor = FT(0.003),
        minimum_moisture_factor = FT(0.001),
        litter_density = FT(22),
    )
end

end
