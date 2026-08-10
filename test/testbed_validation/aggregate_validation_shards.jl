include(joinpath(@__DIR__, "validation_shard_aggregation.jl"))

if abspath(PROGRAM_FILE) == @__FILE__
    exit(TestbedValidationShardAggregation.main())
end
