#!/usr/bin/env julia

import ClimaLand

const TRAJECTORY_DIRECTORY = joinpath(@__DIR__, "..", "trajectory_bundle")
include(joinpath(TRAJECTORY_DIRECTORY, "trajectory_bundle.jl"))
include(joinpath(TRAJECTORY_DIRECTORY, "tolerance_contract.jl"))
include(joinpath(TRAJECTORY_DIRECTORY, "free_replay.jl"))
include(joinpath(TRAJECTORY_DIRECTORY, "classic_callback_adapter.jl"))
include("matrix_execution.jl")

using .ClassicToleranceContract: evidence_root_from_env
using .ClassicMatrixExecution: archive_root_from_env, run_real_matrix

function main(args)
    length(args) == 2 || error(
        "usage: run_real_matrix.jl ARCHIVE_MANIFEST_OR_ROOT EXTERNAL_RECEIPT",
    )
    archive_source, output_receipt = abspath.(args)
    receipt = run_real_matrix(
        archive_source,
        output_receipt;
        evidence_root = evidence_root_from_env(),
        archive_root = isfile(archive_source) ? archive_root_from_env() :
                       nothing,
    )
    receipt["status"] == "complete" || exit(1)
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
