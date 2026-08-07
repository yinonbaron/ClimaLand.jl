module ClassicReferenceWorkspace

using Downloads
using TOML

export check_environment,
    fetch_resources,
    initialize_workspace,
    load_manifest,
    main,
    validate_workspace_location,
    verify_workspace

const USAGE = """usage:
  classic_workspace.jl check  <manifest.toml> <workspace>
  classic_workspace.jl init   <manifest.toml> <workspace>
  classic_workspace.jl status <manifest.toml> <workspace> [resource-id ...]
  classic_workspace.jl fetch  <manifest.toml> <workspace> [resource-id ...]
  classic_workspace.jl verify <manifest.toml> <workspace> [resource-id ...]
"""

function require_keys(table, keys, context)
    for key in keys
        haskey(table, key) || throw(ArgumentError("$context is missing '$key'"))
    end
end

function validate_relative_path(path, context)
    isabspath(path) && throw(ArgumentError("$context must be relative"))
    normalized = normpath(path)
    (
        normalized == ".." ||
        startswith(normalized, ".." * Base.Filesystem.path_separator)
    ) && throw(ArgumentError("$context escapes the workspace"))
    return normalized
end

function is_below(path, root)
    relative = relpath(path, root)
    return relative != ".." &&
           !startswith(relative, ".." * Base.Filesystem.path_separator)
end

function validate_manifest(manifest)
    require_keys(
        manifest,
        ("schema_version", "workspace", "prerequisites", "resource"),
        "manifest",
    )
    manifest["schema_version"] == 1 ||
        throw(ArgumentError("unsupported manifest schema_version"))

    workspace = manifest["workspace"]
    require_keys(
        workspace,
        (
            "canonical_allocation_env",
            "directory_name",
            "minimum_free_bytes",
            "immutable_directories",
            "replaceable_directories",
        ),
        "workspace",
    )
    workspace["minimum_free_bytes"] >= 0 ||
        throw(ArgumentError("workspace minimum_free_bytes must be nonnegative"))
    immutable = Set(
        validate_relative_path(path, "immutable directory") for
        path in workspace["immutable_directories"]
    )
    replaceable = Set(
        validate_relative_path(path, "replaceable directory") for
        path in workspace["replaceable_directories"]
    )
    any(
        is_below(immutable_path, replaceable_path) ||
            is_below(replaceable_path, immutable_path) for
        immutable_path in immutable for replaceable_path in replaceable
    ) && throw(ArgumentError("immutable and replaceable directories overlap"))

    prerequisites = manifest["prerequisites"]
    require_keys(prerequisites, ("platform", "commands"), "prerequisites")
    isempty(prerequisites["commands"]) &&
        throw(ArgumentError("at least one prerequisite command is required"))

    resource_ids = Set{String}()
    destinations = Set{String}()
    for resource in manifest["resource"]
        require_keys(
            resource,
            (
                "id",
                "record_id",
                "doi",
                "record_url",
                "version",
                "publication_date",
                "record_license",
                "file",
            ),
            "resource",
        )
        resource["id"] in resource_ids &&
            throw(ArgumentError("duplicate resource id: $(resource["id"])"))
        push!(resource_ids, resource["id"])
        resource["record_id"] > 0 ||
            throw(ArgumentError("record_id must be positive"))
        expected_record_url = "https://zenodo.org/records/$(resource["record_id"])"
        resource["record_url"] == expected_record_url ||
            throw(ArgumentError("record_url does not match record_id"))

        for file in resource["file"]
            require_keys(
                file,
                ("filename", "relative_path", "bytes", "md5", "url"),
                "resource file",
            )
            file["bytes"] >= 0 ||
                throw(ArgumentError("file bytes must be nonnegative"))
            occursin(r"^[0-9a-f]{32}$", file["md5"]) || throw(
                ArgumentError(
                    "file md5 must be 32 lowercase hexadecimal characters",
                ),
            )
            relative_path = validate_relative_path(
                file["relative_path"],
                "resource file path",
            )
            any(is_below(relative_path, root) for root in immutable) || throw(
                ArgumentError(
                    "resource file must be under an immutable directory",
                ),
            )
            relative_path in destinations && throw(
                ArgumentError("duplicate resource file path: $relative_path"),
            )
            push!(destinations, relative_path)
            expected_url_prefix = "https://zenodo.org/api/records/$(resource["record_id"])/files/"
            startswith(file["url"], expected_url_prefix) || throw(
                ArgumentError("file URL does not match resource record_id"),
            )
        end
    end
    isempty(resource_ids) && throw(ArgumentError("manifest has no resources"))
    return manifest
end

function load_manifest(path)
    isfile(path) ||
        throw(ArgumentError("manifest does not exist: $(abspath(path))"))
    return validate_manifest(TOML.parsefile(path))
end

function resolved_path(path)
    candidate = abspath(path)
    suffix = String[]
    while !ispath(candidate)
        parent = dirname(candidate)
        parent == candidate &&
            throw(ArgumentError("cannot resolve path: $path"))
        pushfirst!(suffix, basename(candidate))
        candidate = parent
    end
    return normpath(joinpath(realpath(candidate), suffix...))
end

function validate_workspace_location(
    workspace,
    allocation_root,
    repository_root,
)
    resolved_workspace = resolved_path(workspace)
    resolved_allocation = resolved_path(allocation_root)
    resolved_repository = resolved_path(repository_root)
    is_below(resolved_workspace, resolved_allocation) || throw(
        ArgumentError(
            "workspace must be inside canonical allocation $resolved_allocation",
        ),
    )
    is_below(resolved_workspace, resolved_repository) &&
        throw(ArgumentError("workspace must be outside the Git repository"))
    resolved_workspace == resolved_allocation && throw(
        ArgumentError("workspace must be a subdirectory of the allocation"),
    )
    return resolved_workspace
end

function validate_workspace_member(path, workspace)
    resolved_workspace = resolved_path(workspace)
    resolved_member = resolved_path(path)
    is_below(resolved_member, resolved_workspace) ||
        throw(ArgumentError("workspace path escapes through a symlink: $path"))
    return resolved_member
end

function validate_configured_workspace(
    manifest,
    workspace,
    repository_root;
    environment = ENV,
)
    workspace_config = manifest["workspace"]
    allocation_variable = workspace_config["canonical_allocation_env"]
    allocation_root = get(environment, allocation_variable, "")
    isempty(allocation_root) && throw(
        ArgumentError("environment variable $allocation_variable is not set"),
    )
    resolved_workspace =
        validate_workspace_location(workspace, allocation_root, repository_root)
    basename(resolved_workspace) == workspace_config["directory_name"] || throw(
        ArgumentError(
            "workspace basename must be $(workspace_config["directory_name"])",
        ),
    )
    return (; allocation_root, resolved_workspace)
end

function selected_resources(manifest, resource_ids)
    resources = manifest["resource"]
    isempty(resource_ids) && return resources
    by_id = Dict(resource["id"] => resource for resource in resources)
    unknown = setdiff(Set(resource_ids), Set(keys(by_id)))
    isempty(unknown) || throw(
        ArgumentError(
            "unknown resource id(s): $(join(sort!(collect(unknown)), ", "))",
        ),
    )
    return [by_id[id] for id in resource_ids]
end

function md5sum(path)
    executable = Sys.which("md5sum")
    isnothing(executable) &&
        throw(ArgumentError("required command is unavailable: md5sum"))
    return first(split(read(Cmd([executable, path]), String)))
end

function file_report(resource, file, workspace)
    path = joinpath(workspace, file["relative_path"])
    common = (; resource = resource["id"], filename = file["filename"], path)
    isfile(path) || return (;
        common...,
        status = :missing,
        actual_bytes = nothing,
        actual_md5 = nothing,
    )
    actual_bytes = filesize(path)
    actual_bytes == file["bytes"] || return (;
        common...,
        status = :size_mismatch,
        actual_bytes,
        actual_md5 = nothing,
    )
    actual_md5 = md5sum(path)
    actual_md5 == file["md5"] || return (;
        common...,
        status = :checksum_mismatch,
        actual_bytes,
        actual_md5,
    )
    return (; common..., status = :verified, actual_bytes, actual_md5)
end

function verify_workspace(manifest, workspace; resource_ids = String[])
    files = [
        file_report(resource, file, workspace) for
        resource in selected_resources(manifest, resource_ids) for
        file in resource["file"]
    ]
    return (; ok = all(file.status == :verified for file in files), files)
end

function available_capacity(path)
    existing = resolved_path(path)
    while !isdir(existing)
        existing = dirname(existing)
    end
    blocks = split(strip(read(`df -Pk $existing`, String)), '\n')
    inodes = split(strip(read(`df -Pi $existing`, String)), '\n')
    block_fields = split(last(blocks))
    inode_fields = split(last(inodes))
    return (;
        available_bytes = parse(Int, block_fields[4]) * 1024,
        available_inodes = parse(Int, inode_fields[4]),
        filesystem = first(block_fields),
    )
end

function writable_probe(path)
    try
        probe, io = mktemp(path)
        close(io)
        rm(probe)
        return true
    catch
        return false
    end
end

function command_report(command)
    executable = Sys.which(command)
    isnothing(executable) &&
        return (; command, available = false, path = nothing, version = nothing)
    version = try
        first(split(strip(read(Cmd([executable, "--version"]), String)), '\n'))
    catch error
        "version probe failed: $(sprint(showerror, error))"
    end
    return (; command, available = true, path = executable, version)
end

function check_environment(
    manifest,
    workspace,
    repository_root;
    environment = ENV,
)
    workspace_config = manifest["workspace"]
    allocation_variable = workspace_config["canonical_allocation_env"]
    issues = String[]
    allocation_root = get(environment, allocation_variable, "")
    isempty(allocation_root) &&
        push!(issues, "environment variable $allocation_variable is not set")

    resolved_workspace = nothing
    if !isempty(allocation_root)
        try
            location = validate_configured_workspace(
                manifest,
                workspace,
                repository_root;
                environment,
            )
            resolved_workspace = location.resolved_workspace
            isdir(allocation_root) ||
                push!(issues, "allocation does not exist: $allocation_root")
            isdir(allocation_root) && writable_probe(allocation_root) ||
                push!(issues, "allocation is not writable: $allocation_root")
        catch error
            push!(issues, sprint(showerror, error))
        end
    end

    platform = lowercase(string(Sys.KERNEL))
    platform == lowercase(manifest["prerequisites"]["platform"]) || push!(
        issues,
        "platform must be $(manifest["prerequisites"]["platform"]), found $platform",
    )
    commands = [
        command_report(command) for
        command in manifest["prerequisites"]["commands"]
    ]
    for command in commands
        command.available ||
            push!(issues, "required command is unavailable: $(command.command)")
    end

    capacity = nothing
    if !isempty(allocation_root) && isdir(allocation_root)
        try
            capacity = available_capacity(allocation_root)
            capacity.available_bytes >=
            workspace_config["minimum_free_bytes"] || push!(
                issues,
                "allocation has insufficient free storage: $(capacity.available_bytes) bytes available",
            )
        catch error
            push!(issues, "storage probe failed: $(sprint(showerror, error))")
        end
    end
    return (;
        ok = isempty(issues),
        issues,
        allocation_root,
        resolved_workspace,
        capacity,
        commands,
    )
end

function initialize_workspace(
    manifest,
    workspace,
    repository_root;
    environment = ENV,
)
    report =
        check_environment(manifest, workspace, repository_root; environment)
    report.ok || throw(ArgumentError(join(report.issues, "; ")))
    config = manifest["workspace"]
    for relative_path in
        vcat(config["immutable_directories"], config["replaceable_directories"])
        mkpath(joinpath(workspace, relative_path))
    end
    return report
end

function fetch_resources(
    manifest,
    workspace;
    resource_ids = String[],
    downloader = Downloads.download,
)
    staging = joinpath(workspace, "replaceable", "staging")
    validate_workspace_member(staging, workspace)
    isdir(staging) ||
        throw(ArgumentError("workspace is not initialized: missing $staging"))
    fetched = String[]
    for resource in selected_resources(manifest, resource_ids)
        for file in resource["file"]
            destination = joinpath(workspace, file["relative_path"])
            validate_workspace_member(destination, workspace)
            if ispath(destination)
                report = file_report(resource, file, workspace)
                report.status == :verified || throw(
                    ArgumentError(
                        "refusing to replace immutable file with status $(report.status): $destination",
                    ),
                )
                continue
            end
            mkpath(dirname(destination))
            temporary = tempname(staging)
            try
                downloader(file["url"], temporary)
                filesize(temporary) == file["bytes"] || throw(
                    ArgumentError(
                        "download size mismatch for $(file["filename"])",
                    ),
                )
                md5sum(temporary) == file["md5"] || throw(
                    ArgumentError(
                        "download checksum mismatch for $(file["filename"])",
                    ),
                )
                mv(temporary, destination)
                push!(fetched, destination)
            finally
                ispath(temporary) && rm(temporary; force = true)
            end
        end
    end
    return fetched
end

function print_environment(io, report)
    println(
        io,
        "allocation: ",
        isempty(report.allocation_root) ? "unset" : report.allocation_root,
    )
    if !isnothing(report.capacity)
        println(io, "filesystem: ", report.capacity.filesystem)
        println(io, "available bytes: ", report.capacity.available_bytes)
        println(io, "available inodes: ", report.capacity.available_inodes)
    end
    for command in report.commands
        state = command.available ? "available ($(command.version))" : "missing"
        println(io, command.command, ": ", state)
    end
    for issue in report.issues
        println(io, "BLOCKED: ", issue)
    end
end

function print_verification(io, report)
    for file in report.files
        println(io, file.resource, "/", file.filename, ": ", file.status)
    end
end

function main(
    arguments = ARGS;
    stdout = Base.stdout,
    stderr = Base.stderr,
    environment = ENV,
    repository_root = normpath(joinpath(@__DIR__, "..", "..", "..")),
)
    isempty(arguments) && (print(stderr, USAGE); return 2)
    command = first(arguments)
    command in ("check", "init", "status", "fetch", "verify") ||
        (print(stderr, USAGE); return 2)
    length(arguments) >= 3 || (print(stderr, USAGE); return 2)
    manifest_path, workspace = arguments[2:3]
    resource_ids = arguments[4:end]

    try
        manifest = load_manifest(manifest_path)
        if command == "check"
            isempty(resource_ids) ||
                throw(ArgumentError("check does not accept resource ids"))
            report = check_environment(
                manifest,
                workspace,
                repository_root;
                environment,
            )
            print_environment(stdout, report)
            return report.ok ? 0 : 1
        elseif command == "init"
            isempty(resource_ids) ||
                throw(ArgumentError("init does not accept resource ids"))
            report = initialize_workspace(
                manifest,
                workspace,
                repository_root;
                environment,
            )
            print_environment(stdout, report)
            println(stdout, "initialized: ", workspace)
            return 0
        elseif command == "fetch"
            validate_configured_workspace(
                manifest,
                workspace,
                repository_root;
                environment,
            )
            environment_report = check_environment(
                manifest,
                workspace,
                repository_root;
                environment,
            )
            if !environment_report.ok
                print_environment(stdout, environment_report)
                return 1
            end
            fetched = fetch_resources(manifest, workspace; resource_ids)
            for path in fetched
                println(stdout, "fetched: ", path)
            end
            report = verify_workspace(manifest, workspace; resource_ids)
            print_verification(stdout, report)
            return report.ok ? 0 : 1
        else
            validate_configured_workspace(
                manifest,
                workspace,
                repository_root;
                environment,
            )
            report = verify_workspace(manifest, workspace; resource_ids)
            print_verification(stdout, report)
            return command == "status" || report.ok ? 0 : 1
        end
    catch error
        println(stderr, "ERROR: ", sprint(showerror, error))
        return error isa ArgumentError ? 2 : 1
    end
end

end
