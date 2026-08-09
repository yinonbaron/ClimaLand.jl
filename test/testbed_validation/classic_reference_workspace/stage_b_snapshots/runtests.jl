using Test
project = dirname(Base.active_project())

for test_file in (
    "snapshot_tests.jl",
    "schema_tests.jl",
    "evidence_gate_tests.jl",
    "path_escape_tests.jl",
    "complete_schema_tests.jl",
    "schema_strict_tests.jl",
    "time_index_contract_tests.jl",
    "execution_receipt_tests.jl",
    "complete_evidence_tests.jl",
    "instrumentation_generator_tests.jl",
    "seal_raw_snapshot_tests.jl",
    "comparison_receipt_tests.jl",
)
    command = `$(Base.julia_cmd()) --project=$project --startup-file=no $(joinpath(@__DIR__, test_file))`
    @test success(pipeline(command; stdout = stdout, stderr = stderr))
end
