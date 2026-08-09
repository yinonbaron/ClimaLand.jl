struct ReplayFailure{R} <: Exception
    message::String
    receipt_path::String
    report::R
end

Base.showerror(io::IO, error::ReplayFailure) = print(io, error.message)
