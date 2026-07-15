include("candidate_reconstruction.jl")
TestbedCandidateReconstruction.self_test()
include("casa_c_reconstruction.jl")
TestbedCASACReconstruction.self_test()
