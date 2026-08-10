module RealGFGuyRoot

export required_archive_root

function required_archive_root(args = ARGS, environment = ENV)
    length(args) <= 1 || throw(
        ArgumentError(
            "usage: real_gf_guy.jl [ARCHIVE_ROOT] or set CLASSIC_ALL_SITE_ARCHIVE_ROOT",
        ),
    )
    configured = if length(args) == 1
        only(args)
    else
        get(environment, "CLASSIC_ALL_SITE_ARCHIVE_ROOT", nothing)
    end
    (isnothing(configured) || isempty(strip(configured))) && throw(
        ArgumentError("pass ARCHIVE_ROOT or set CLASSIC_ALL_SITE_ARCHIVE_ROOT"),
    )
    root = abspath(configured)
    isdir(root) || throw(ArgumentError("archive root is unavailable: $root"))
    return root
end

end
