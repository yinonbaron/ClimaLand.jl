import ClimaCore: Fields, InputOutput, Spaces
import ClimaUtilities

const PORTABLE_CHECKPOINT_PATH = "checkpoint_values"

function _requires_portable_checkpoint(grid::ClimaCore.Grids.ColumnGrid)
    return true
end

function _requires_portable_checkpoint(
    grid::ClimaCore.Grids.ExtrudedFiniteDifferenceGrid,
)
    return _requires_portable_checkpoint(grid.horizontal_grid)
end

function _requires_portable_checkpoint(
    grid::ClimaCore.Grids.SpectralElementGrid2D,
)
    mesh = Spaces.topology(grid).mesh
    mesh isa ClimaCore.Meshes.RectilinearMesh || return false
    domains = (mesh.intervalmesh1.domain, mesh.intervalmesh2.domain)
    return any(domains) do domain
        coordinate_type = ClimaCore.Domains.coordinate_type(domain)
        coordinate_type <:
        Union{ClimaCore.Geometry.LatPoint, ClimaCore.Geometry.LongPoint}
    end
end

_requires_portable_checkpoint(grid) = false

function _requires_portable_checkpoint(field::Fields.Field)
    space = axes(field)
    return !(space isa Spaces.AbstractPointSpace) &&
           _requires_portable_checkpoint(Spaces.grid(space))
end

function _requires_portable_checkpoint(Y::Fields.FieldVector)
    return any(propertynames(Y)) do property
        _requires_portable_checkpoint(getproperty(Y, property))
    end
end

function _write_checkpoint_values!(group, field::Fields.Field, name)
    InputOutput.write_plain_array!(group, Array(parent(field)), name)
    return nothing
end

function _write_checkpoint_values!(group, Y::Fields.FieldVector, name)
    child_group = InputOutput.create_group(group, name)
    for property in propertynames(Y)
        _write_checkpoint_values!(
            child_group,
            getproperty(Y, property),
            string(property),
        )
    end
    return nothing
end

function _read_checkpoint_values!(field::Fields.Field, dataset, path)
    values = InputOutput.HDF5.read(dataset)
    size(values) == size(parent(field)) || error(
        "Checkpoint field $path has size $(size(values)); expected $(size(parent(field)))",
    )
    copyto!(parent(field), values)
    return nothing
end

function _read_checkpoint_values!(Y::Fields.FieldVector, group, path)
    expected = Set(string.(propertynames(Y)))
    stored = Set(String.(keys(group)))
    expected == stored || error(
        "Checkpoint state $path has fields $(sort!(collect(stored))); expected $(sort!(collect(expected)))",
    )
    for property in propertynames(Y)
        name = string(property)
        _read_checkpoint_values!(
            getproperty(Y, property),
            group[name],
            "$path.$name",
        )
    end
    return nothing
end

function _copy_checkpoint_values!(destination::Fields.Field, source, path)
    size(parent(source)) == size(parent(destination)) || error(
        "Checkpoint field $path has size $(size(parent(source))); expected $(size(parent(destination)))",
    )
    copyto!(parent(destination), parent(source))
    return nothing
end

function _copy_checkpoint_values!(destination::Fields.FieldVector, source, path)
    expected = Set(propertynames(destination))
    stored = Set(propertynames(source))
    expected == stored || error(
        "Checkpoint state $path has fields $(sort!(collect(stored))); expected $(sort!(collect(expected)))",
    )
    for property in propertynames(destination)
        _copy_checkpoint_values!(
            getproperty(destination, property),
            getproperty(source, property),
            "$path.$property",
        )
    end
    return nothing
end

"""
    _checkpoint_attributes(reader, restart_file, model)

Read checkpoint attributes and warn when the model hash differs.
"""
function _checkpoint_attributes(reader, restart_file, model)
    attributes = InputOutput.read_attributes(reader, "/")
    if !isnothing(model) && hash(model) != attributes["land_model_hash"]
        @warn "Restart file $(restart_file) was constructed with a different land model"
    end
    return attributes
end

"""
    ClimaLand.find_restart(output_dir)

Find the most recent restart file in the specified output directory.

This function utilizes `ClimaUtilities.OutputPathGenerator.detect_restart_file`
to locate the latest restart file within the output directory structure,
assuming the `ActiveLinkStyle` is used for managing output folders.

# Arguments
- `output_dir`: The base output directory where the simulation results are stored.

# Returns
- The path to the most recent restart file found, or `nothing` if no restart
  file is found.
"""
function find_restart(output_dir)
    return ClimaUtilities.OutputPathGenerator.detect_restart_file(
        output_dir;
        style = ClimaUtilities.OutputPathGenerator.ActiveLinkStyle(),
    )
end

"""
    set_initial_conditions_from_checkpoint!(Y, restart_file; model::AbstractModel = nothing)

Read restart file in `restart_file` and write its content in `Y`.

The optional argument `model` is used to verify that the checkpoint contains the
same model (as verified by the hash).

See also [`ClimaLand.read_checkpoint`](@ref).
"""
function set_initial_conditions_from_checkpoint!(
    Y,
    restart_file;
    model = nothing,
)
    context = isnothing(model) ? _context_from_Y(Y) : ClimaComms.context(model)
    hdfreader = InputOutput.HDF5Reader(restart_file, context)
    try
        _checkpoint_attributes(hdfreader, restart_file, model)
        if haskey(hdfreader.file, PORTABLE_CHECKPOINT_PATH)
            _read_checkpoint_values!(
                Y,
                hdfreader.file[PORTABLE_CHECKPOINT_PATH],
                "Y",
            )
        else
            Y_restart = InputOutput.read_field(hdfreader, "Y")
            _copy_checkpoint_values!(Y, Y_restart, "Y")
        end
    finally
        Base.close(hdfreader)
    end
    return nothing
end

"""
    initial_time_from_checkpoint(restart_file; model::AbstractModel = nothing)

Read and return the restart time in `restart_file`.

The optional argument `model` is used to verify that the checkpoint contains the
same model (as verified by the hash).
"""
function initial_time_from_checkpoint(restart_file; model = nothing)
    context =
        isnothing(model) ? ClimaComms.context() : ClimaComms.context(model)
    hdfreader = InputOutput.HDF5Reader(restart_file, context)
    try
        attributes = _checkpoint_attributes(hdfreader, restart_file, model)
        return attributes["time"]
    finally
        Base.close(hdfreader)
    end
end

"""
    _context_from_Y(Y)

Try extracting the context from the FieldVector Y.

Typically Y has a structure like:
```
Y
 .bucket
        .T
        .W
        .Ws
```

`_context_from_Y` tries to obtain the context from a Field in the hierarchy.
"""
function _context_from_Y(Y::Fields.FieldVector)
    for p in propertynames(Y)
        maybe_return = _context_from_Y(getproperty(Y, p))
        isnothing(maybe_return) || return maybe_return
    end
end

function _context_from_Y(Y::Fields.Field)
    return ClimaComms.context(Y)
end

function _context_from_Y(Y)
    return nothing
end

"""
    ClimaLand.save_checkpoint(Y, t, output_dir; model = nothing, context = ClimaComms.context(Y))

Save a simulation checkpoint to an HDF5 file.

This function saves the current state of the simulation, including the state
vector `Y` and the current simulation time `t`, to an HDF5 file within the
specified output directory.

# Arguments
- `Y`: The state of the simulation.
- `t`: The current simulation time.
- `output_dir`: The directory where the checkpoint file will be saved.
- `model` (Optional): The ClimaLand model object. If provided the hash of the model
  will be stored in the checkpoint file. Defaults to `nothing`. This is used
  to check for consistency.
- `context` (Optional): The ClimaComms context. This is used for distributed I/O
  operations. Defaults to the context extracted from the state vector `Y` or the `model`.

Unsupported `ColumnGrid` and rectilinear latitude-longitude grids use a
field-value checkpoint on singleton contexts.
"""
function save_checkpoint(
    Y,
    t,
    output_dir;
    model = nothing,
    context = isnothing(model) ? _context_from_Y(Y) : ClimaComms.context(model),
)
    day = floor(Int, t / (60 * 60 * 24))
    sec = floor(Int, t % (60 * 60 * 24))
    output_file = joinpath(output_dir, "day$day.$sec.hdf5")
    hdfwriter = InputOutput.HDF5Writer(output_file, context)
    try
        # If model was passed, add its hash, otherwise add nothing
        hash_model = isnothing(model) ? "nothing" : hash(model)
        InputOutput.write_attributes!(
            hdfwriter,
            "/",
            Dict("time" => t, "land_model_hash" => hash_model),
        )
        if _requires_portable_checkpoint(Y)
            context isa ClimaComms.SingletonCommsContext || error(
                "Portable vertical-domain checkpoints require a singleton context",
            )
            _write_checkpoint_values!(
                hdfwriter.file,
                Y,
                PORTABLE_CHECKPOINT_PATH,
            )
        else
            InputOutput.write!(hdfwriter, Y, "Y")
        end
    finally
        Base.close(hdfwriter)
    end
    return nothing
end

"""
    ClimaLand.read_checkpoint(file_path; model = nothing, context = ClimaComms.context())

Read a simulation checkpoint from an HDF5 file.

This function loads the simulation state from a previously saved checkpoint file.

# Arguments
- `file_path`: The path to the HDF5 checkpoint file.
- `model`: The ClimaLand model object. It is required for field-value checkpoints
  so the destination state can be initialized. For native checkpoints it is
  optional and defaults to `nothing`. When supplied, its hash is compared with
  the stored model hash and a warning is issued if they do not match.
- `context` (Optional): The ClimaComms context. This is used for parallel I/O
  operations. Defaults to the default ClimaComms context.

# Returns
- `Y`: The state vector loaded from the checkpoint file.
- `t`: The simulation time loaded from the checkpoint file.
"""
function read_checkpoint(
    file_path;
    model = nothing,
    context = isnothing(model) ? ClimaComms.context() :
              ClimaComms.context(model),
)
    hdfreader = InputOutput.HDF5Reader(file_path, context)
    try
        attributes = _checkpoint_attributes(hdfreader, file_path, model)
        if haskey(hdfreader.file, PORTABLE_CHECKPOINT_PATH)
            isnothing(model) && error(
                "This checkpoint requires `model` to reconstruct its domain",
            )
            Y, _, _ = initialize(model)
            _read_checkpoint_values!(
                Y,
                hdfreader.file[PORTABLE_CHECKPOINT_PATH],
                "Y",
            )
        else
            Y_checkpoint = InputOutput.read_field(hdfreader, "Y")
            if isnothing(model)
                Y = Y_checkpoint
            else
                Y, _, _ = initialize(model)
                _copy_checkpoint_values!(Y, Y_checkpoint, "Y")
            end
        end
        return Y, attributes["time"]
    finally
        Base.close(hdfreader)
    end
end
