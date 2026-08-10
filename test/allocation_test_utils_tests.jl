using Test

include("allocation_test_utils.jl")
using .AllocationTestUtils: allocated_bytes

function allocation_probe(first, second)
    return (; values = (first, second), sum = first + second)
end

@testset "specialized allocation measurement" begin
    arguments = (1.0, 2.0)
    @test allocation_probe(arguments...) == (; values = arguments, sum = 3.0)
    @test allocated_bytes(allocation_probe, arguments) == 0
end
