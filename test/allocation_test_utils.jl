module AllocationTestUtils

export allocated_bytes

"""
    allocated_bytes(callable, arguments::Tuple)

Measure allocations after specializing and warming `callable` for the complete
argument tuple type.
"""
function allocated_bytes(callable::F, arguments::T) where {F, T <: Tuple}
    callable(arguments...)
    return @allocated callable(arguments...)
end

end
