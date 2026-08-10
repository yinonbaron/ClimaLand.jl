"""
    semantic_time_sha256(times, calendar, units)

Hash the canonical UTF-8 serialization of a decoded time coordinate. The
serialization is schema version, calendar, units, coordinate length, then one
ISO timestamp per line in coordinate order, with a final newline. This binds
time semantics independently of NetCDF container encoding.
"""
function semantic_time_sha256(times, calendar, units)
    lines = String[
        "schema_version=1",
        "calendar=$(String(calendar))",
        "units=$(String(units))",
        "length=$(length(times))",
    ]
    append!(lines, ("timestamp=$(string(value))" for value in times))
    payload = join(lines, "\n") * "\n"
    return bytes2hex(SHA.sha256(codeunits(payload)))
end
