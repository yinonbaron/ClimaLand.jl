function testbed_state_diagnostics(
    component,
    model_name,
    variables;
    element = "C",
)
    return map(variables) do variable
        variable_name = replace(String(variable), "_" => " ")
        (;
            short_name = string(component, "_", variable),
            long_name = string(model_name, " ", variable_name),
            units = string("kg ", element, " m^-2"),
            comments = string(
                element == "C" ? "Carbon" : "Nitrogen",
                " stock in the ",
                model_name,
                " ",
                variable_name,
                " state.",
            ),
            component,
            source = :state,
            variable,
            index = 0,
        )
    end
end

function testbed_aux_diagnostic(
    component,
    short_name,
    long_name,
    variable;
    units = "kg C m^-2 s^-1",
    comments = long_name,
)
    return (;
        short_name,
        long_name,
        units,
        comments,
        component,
        source = :aux,
        variable,
        index = 0,
    )
end

function testbed_flux_diagnostic(
    component,
    short_name,
    long_name,
    index;
    units = "kg C m^-2 s^-1",
    comments = long_name,
    variable = :carbon_fluxes,
)
    return (;
        short_name,
        long_name,
        units,
        comments,
        component,
        source = :aux,
        variable,
        index,
    )
end

const TESTBED_DIAGNOSTICS = let
    plant_states = testbed_state_diagnostics(
        :casa_plant,
        "CASA plant",
        (:c_leaf, :c_wood, :c_fine_root, :c_labile),
    )
    plant_fluxes = (
        testbed_flux_diagnostic(
            :casa_plant,
            "casa_plant_gpp",
            "CASA plant gross primary production",
            14,
        ),
        testbed_flux_diagnostic(
            :casa_plant,
            "casa_plant_npp",
            "CASA plant net primary production",
            15,
        ),
        testbed_flux_diagnostic(
            :casa_plant,
            "casa_plant_autotrophic_respiration",
            "CASA plant autotrophic respiration",
            16,
        ),
        testbed_flux_diagnostic(
            :casa_plant,
            "casa_plant_leaf_litter",
            "CASA plant leaf litter flux",
            8,
        ),
        testbed_flux_diagnostic(
            :casa_plant,
            "casa_plant_wood_litter",
            "CASA plant wood litter flux",
            9,
        ),
        testbed_flux_diagnostic(
            :casa_plant,
            "casa_plant_root_litter",
            "CASA plant fine-root litter flux",
            10,
        ),
        testbed_flux_diagnostic(
            :casa_plant,
            "casa_plant_root_exudate",
            "CASA plant root-exudate flux",
            20,
        ),
        testbed_flux_diagnostic(
            :casa_plant,
            "casa_plant_lai",
            "CASA plant leaf area index",
            19;
            units = "m^2 m^-2",
        ),
    )
    plant_nitrogen_states = testbed_state_diagnostics(
        :casa_plant,
        "CASA plant",
        (:n_leaf, :n_wood, :n_fine_root);
        element = "N",
    )
    plant_nitrogen_fluxes = (
        testbed_flux_diagnostic(
            :casa_plant,
            "casa_plant_n_litter_metabolic",
            "CASA plant metabolic-litter nitrogen input",
            4;
            units = "kg N m^-2 s^-1",
            variable = :nitrogen_fluxes,
        ),
        testbed_flux_diagnostic(
            :casa_plant,
            "casa_plant_n_litter_structural",
            "CASA plant structural-litter nitrogen input",
            5;
            units = "kg N m^-2 s^-1",
            variable = :nitrogen_fluxes,
        ),
        testbed_flux_diagnostic(
            :casa_plant,
            "casa_plant_n_litter_cwd",
            "CASA plant coarse-woody-debris nitrogen input",
            6;
            units = "kg N m^-2 s^-1",
            variable = :nitrogen_fluxes,
        ),
        testbed_flux_diagnostic(
            :casa_plant,
            "casa_plant_n_uptake",
            "CASA plant mineral-nitrogen uptake",
            7;
            units = "kg N m^-2 s^-1",
            variable = :nitrogen_fluxes,
        ),
    )

    casa_states = testbed_state_diagnostics(
        :casa_soil,
        "CASA soil",
        (
            :c_litter_metabolic,
            :c_litter_structural,
            :c_litter_cwd,
            :c_soil_microbial,
            :c_soil_slow,
            :c_soil_passive,
        ),
    )
    casa_fluxes = (
        testbed_flux_diagnostic(
            :casa_soil,
            "casa_soil_heterotrophic_respiration",
            "CASA soil heterotrophic respiration",
            7,
        ),
        testbed_flux_diagnostic(
            :casa_soil,
            "casa_soil_passive_input",
            "CASA soil passive-pool input",
            8,
        ),
        testbed_aux_diagnostic(
            :casa_soil,
            "casa_soil_metabolic_litter_input",
            "CASA soil metabolic-litter input",
            :litter_metabolic_input,
        ),
        testbed_aux_diagnostic(
            :casa_soil,
            "casa_soil_structural_litter_input",
            "CASA soil structural-litter input",
            :litter_structural_input,
        ),
        testbed_aux_diagnostic(
            :casa_soil,
            "casa_soil_cwd_input",
            "CASA soil coarse-woody-debris input",
            :litter_cwd_input,
        ),
    )
    casa_nitrogen_states = testbed_state_diagnostics(
        :casa_soil,
        "CASA soil",
        (
            :n_litter_metabolic,
            :n_litter_structural,
            :n_litter_cwd,
            :n_soil_microbial,
            :n_soil_slow,
            :n_soil_passive,
            :n_mineral,
        );
        element = "N",
    )
    casa_nitrogen_fluxes = (
        testbed_flux_diagnostic(
            :casa_soil,
            "casa_soil_n_gaseous_loss",
            "CASA soil gaseous nitrogen loss",
            12;
            units = "kg N m^-2 s^-1",
            variable = :nitrogen_fluxes,
        ),
        testbed_flux_diagnostic(
            :casa_soil,
            "casa_soil_n_leaching",
            "CASA soil nitrogen leaching",
            13;
            units = "kg N m^-2 s^-1",
            variable = :nitrogen_fluxes,
        ),
    )

    mimics_states = testbed_state_diagnostics(
        :mimics_soil,
        "MIMICS soil",
        (
            :c_litter_metabolic,
            :c_litter_structural,
            :c_litter_cwd,
            :c_microbe_r,
            :c_microbe_k,
            :c_soil_available,
            :c_soil_chemical,
            :c_soil_physical,
        ),
    )
    mimics_fluxes = (
        testbed_flux_diagnostic(
            :mimics_soil,
            "mimics_soil_heterotrophic_respiration",
            "MIMICS soil heterotrophic respiration",
            9,
        ),
        testbed_aux_diagnostic(
            :mimics_soil,
            "mimics_soil_metabolic_litter_input",
            "MIMICS soil metabolic-litter input",
            :litter_metabolic_input,
        ),
        testbed_aux_diagnostic(
            :mimics_soil,
            "mimics_soil_structural_litter_input",
            "MIMICS soil structural-litter input",
            :litter_structural_input,
        ),
        testbed_aux_diagnostic(
            :mimics_soil,
            "mimics_soil_cwd_input",
            "MIMICS soil coarse-woody-debris input",
            :litter_cwd_input,
        ),
    )
    mimics_nitrogen_states = testbed_state_diagnostics(
        :mimics_soil,
        "MIMICS soil",
        (
            :n_litter_metabolic,
            :n_litter_structural,
            :n_microbe_r,
            :n_microbe_k,
            :n_soil_available,
            :n_soil_chemical,
            :n_soil_physical,
            :n_litter_cwd,
            :n_mineral,
        );
        element = "N",
    )
    mimics_nitrogen_fluxes = (
        testbed_flux_diagnostic(
            :mimics_soil,
            "mimics_soil_n_gaseous_loss",
            "MIMICS soil gaseous nitrogen loss",
            10;
            units = "kg N m^-2 s^-1",
            variable = :nitrogen_fluxes,
        ),
        testbed_flux_diagnostic(
            :mimics_soil,
            "mimics_soil_n_leaching",
            "MIMICS soil nitrogen leaching",
            11;
            units = "kg N m^-2 s^-1",
            variable = :nitrogen_fluxes,
        ),
    )

    corpse_states = testbed_state_diagnostics(
        :corpse_soil,
        "CORPSE soil",
        ClimaLand.Soil.Biogeochemistry.CORPSE.PROGNOSTIC_VARIABLES,
    )
    corpse_fluxes = (
        testbed_flux_diagnostic(
            :corpse_soil,
            "corpse_soil_heterotrophic_respiration",
            "CORPSE soil heterotrophic respiration",
            38,
        ),
        testbed_aux_diagnostic(
            :corpse_soil,
            "corpse_soil_leaf_labile_input",
            "CORPSE soil labile leaf-litter input",
            :leaf_labile_input,
        ),
        testbed_aux_diagnostic(
            :corpse_soil,
            "corpse_soil_leaf_recalcitrant_input",
            "CORPSE soil recalcitrant leaf-litter input",
            :leaf_recalcitrant_input,
        ),
        testbed_aux_diagnostic(
            :corpse_soil,
            "corpse_soil_root_labile_input",
            "CORPSE soil labile root-litter input",
            :root_labile_input,
        ),
        testbed_aux_diagnostic(
            :corpse_soil,
            "corpse_soil_root_recalcitrant_input",
            "CORPSE soil recalcitrant root-litter input",
            :root_recalcitrant_input,
        ),
        testbed_aux_diagnostic(
            :corpse_soil,
            "corpse_soil_exudate_input",
            "CORPSE soil root-exudate input",
            :exudate_labile_input,
        ),
        testbed_aux_diagnostic(
            :corpse_soil,
            "corpse_soil_cwd_input",
            "CORPSE soil coarse-woody-debris input",
            :litter_cwd_input,
        ),
    )

    vcat(
        collect(plant_states),
        collect(plant_fluxes),
        collect(plant_nitrogen_states),
        collect(plant_nitrogen_fluxes),
        collect(casa_states),
        collect(casa_fluxes),
        collect(casa_nitrogen_states),
        collect(casa_nitrogen_fluxes),
        collect(mimics_states),
        collect(mimics_fluxes),
        collect(mimics_nitrogen_states),
        collect(mimics_nitrogen_fluxes),
        collect(corpse_states),
        collect(corpse_fluxes),
    )
end

function testbed_diagnostic_names(model::ClimaLand.AbstractModel)
    component = ClimaLand.name(model)
    state_variables = ClimaLand.prognostic_vars(model)
    auxiliary_variables = ClimaLand.auxiliary_vars(model)
    specs = filter(TESTBED_DIAGNOSTICS) do spec
        spec.component == component && (
            spec.source == :state ? spec.variable in state_variables :
            spec.variable in auxiliary_variables
        )
    end
    return map(spec -> spec.short_name, specs)
end

function testbed_diagnostic_names(component::Symbol)
    return map(
        spec -> spec.short_name,
        filter(spec -> spec.component == component, TESTBED_DIAGNOSTICS),
    )
end

function compute_testbed_diagnostic!(out, Y, p, t, land_model, spec)
    state = getproperty(Y, spec.component)
    source = spec.source == :state ? state : getproperty(p, spec.component)
    field = getproperty(source, spec.variable)
    if isnothing(out)
        template = getproperty(state, first(propertynames(state)))
        out = similar(template)
        fill!(field_values(out), NaN)
    end
    if iszero(spec.index)
        out .= field
    else
        index = spec.index
        @. out = getindex(field, index)
    end
    return out
end

function define_testbed_diagnostics!(land_model, possible_diags)
    for spec in TESTBED_DIAGNOSTICS
        conditional_add_diagnostic_variable!(
            possible_diags;
            short_name = spec.short_name,
            long_name = spec.long_name,
            units = spec.units,
            comments = spec.comments,
            compute! = (out, Y, p, t) ->
                compute_testbed_diagnostic!(out, Y, p, t, land_model, spec),
        )
    end
    return nothing
end
