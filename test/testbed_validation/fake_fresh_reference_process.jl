import TOML

mode = first(ARGS)
if mode == "build"
    _, build_directory, audit_directory, behavior = ARGS
    audit_path = joinpath(audit_directory, "build.toml")
    invocations =
        isfile(audit_path) ?
        TOML.parsefile(audit_path)["invocations"] + 1 : 1
    open(audit_path, "w") do io
        TOML.print(
            io,
            Dict(
                "build_directory" => build_directory,
                "invocations" => invocations,
                "working_directory" => pwd(),
            ),
        )
    end
    behavior == "fail" && error("requested fake Fortran build failure")
    if behavior != "missing"
        open(joinpath(build_directory, "build_metadata.toml"), "w") do io
            TOML.print(
                io,
                Dict("verified" => behavior != "unverified"),
            )
        end
    end
elseif mode == "worker"
    _, model, run_directory, build_directory, audit_directory, behavior = ARGS
    isfile(joinpath(build_directory, "build_metadata.toml")) ||
        error("fake worker started before the shared build")
    open(joinpath(audit_directory, "$model.toml"), "w") do io
        TOML.print(
            io,
            Dict(
                "build_directory" => build_directory,
                "run_directory" => run_directory,
                "working_directory" => pwd(),
            ),
        )
    end
    for name in ("fortran_output", "julia_output", "comparison")
        open(joinpath(run_directory, "$name.toml"), "w") do io
            TOML.print(io, Dict("model" => model))
        end
    end
    if behavior == "nonfinite"
        open(joinpath(run_directory, "nonfinite_results.toml"), "w") do io
            TOML.print(
                io,
                Dict(
                    "schema_version" => 1,
                    "nonfinite" => [
                        Dict(
                            "cell_id" => 51,
                            "evidence_side" => "fortran",
                            "first_nonfinite_date" => "1920-12-31",
                            "first_nonfinite_stage" => "historical",
                            "first_nonfinite_variable" => "c_pool",
                            "reason" => "fresh trajectory became nonfinite",
                        ),
                    ],
                );
                sorted = true,
            )
        end
    end
    behavior == "fail" && error("requested fake model worker failure")
else
    error("unknown fake fresh-reference mode: $mode")
end
