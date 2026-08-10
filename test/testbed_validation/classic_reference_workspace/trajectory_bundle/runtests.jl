using Test

include("trajectory_bundle.jl")
using .ClassicTrajectoryBundle

include("trajectory_generator.jl")
using .ClassicTrajectoryGenerator

include("free_replay.jl")
using .ClassicFreeReplay

include("classic_callback_adapter.jl")
using .ClassicCallbackAdapter

include("test_helpers.jl")
include("schema_tests.jl")
include("validation_tests.jl")
include("replay_tests.jl")
include("generator_test_helpers.jl")
include("generator_tests.jl")
include("seasonal_gate_tests.jl")
include("receipt_gate_tests.jl")
include("classic_callback_adapter_tests.jl")
include("ledger_gate_tests.jl")
include("event_index_tests.jl")
include("derived_audit_tests.jl")
include("free_replay_tests.jl")
include("compensated_drift_tests.jl")
include("day_one_gate_tests.jl")
include("per_field_report_tests.jl")
include("replay_receipt_tests.jl")
include("acceptance_tests.jl")
