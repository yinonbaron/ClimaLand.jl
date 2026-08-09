@testset "trajectory bundle schema" begin
    schema_path = joinpath(@__DIR__, "schema.toml")
    schema = load_bundle_schema(schema_path)

    @test schema["schema_version"] == 1
    @test Set(field["section"] for field in schema["field"]) == Set((
        "static_data",
        "initial_state",
        "drivers",
        "reference_state",
        "audit_diagnostics",
    ))
    @test schema["dimensions"]["pft_and_bare"] == 13
    @test schema["dimensions"]["soil_layer"] == 20
    @test length(schema["field"]) == 70
end

@testset "schema encodes the Stage B ownership boundary" begin
    fields = Dict(
        field["name"] => field for field in
        load_bundle_schema(joinpath(@__DIR__, "schema.toml"))["field"]
    )

    @test all(
        haskey(fields, name) for name in (
            "static.isand",
            "parameter.bsratelt",
            "initial.soilcmas",
            "driver.pre_resp_competition_delta_soil",
            "driver.post_resp_turnover_delta_soil",
            "reference.post_soilcmas",
            "audit.turbation_soil_column_residual",
            "audit.hetrsveg",
            "audit.litres",
            "audit.socres",
            "audit.hetrores",
            "audit.soilresp",
            "audit.humiftrs",
            "parameter.tfrez",
            "static.mineral_mask",
            "static.zbot",
            "static.delzw",
        )
    )
    @test fields["static.isand"]["dtype"] == "int32"
    @test fields["driver.pre_resp_competition_delta_soil"]["sampling"] ==
          "interval_sum"
    integer_fields = Set(("static.isand", "static.sort", "parameter.spinfast"))
    integer_fields = union(
        integer_fields,
        Set(("static.mineral_mask", "parameter.turbation_on")),
    )
    @test all(fields[name]["dtype"] == "int32" for name in integer_fields)
    @test all(
        field["dtype"] == "float64" for
        (name, field) in fields if name ∉ integer_fields
    )
    @test fields["driver.pre_resp_competition_delta_litter"]["application_phase"] ==
          "competition"
    @test fields["driver.pre_resp_land_use_delta_litter"]["application_phase"] ==
          "land_use"
    @test fields["driver.pre_resp_harvest_delta_litter"]["application_phase"] ==
          "timber_harvest"
    @test fields["driver.post_resp_turnover_delta_litter"]["application_phase"] ==
          "turnover_and_reproduction"
    @test fields["driver.post_resp_disturbance_delta_litter"]["application_phase"] ==
          "disturbance_and_fire"

end
