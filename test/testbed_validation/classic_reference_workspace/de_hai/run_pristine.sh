#!/usr/bin/env bash

set -euo pipefail

usage() {
    printf 'Usage: %s WORKSPACE [RUN_ID]\n' "$0" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 2
fi

workspace=$(realpath "$1")
run_id=${2:-issue-97-de-hai-pristine}
julia_bin=${JULIA:-julia}

if [[ ! $run_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    printf 'RUN_ID must be a single safe path component: %s\n' "$run_id" >&2
    exit 2
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(realpath "$script_dir/../../../..")
control_dir="$repo_root/test/testbed_validation/classic_reference_workspace"

archives="$workspace/immutable/archives"
replaceable="$workspace/replaceable"
extraction_root="$replaceable/extracted/$run_id"
source_dir="$extraction_root/CLASSIC"
fluxnet_stage="$extraction_root/FLUXNET"
published_root="$extraction_root/published"
build_dir="$replaceable/builds/$run_id"
run_dir="$replaceable/runs/$run_id"

source_archive="$archives/zenodo-18188101/classic-CLASSICv2.0.tar.gz"
container_archive="$archives/zenodo-18201505/CLASSIC_container.tar.gz"
benchmark_archive="$archives/zenodo-18202323/Benchmark_CLASSIC_output.tar.gz"
plots_archive="$archives/zenodo-18202323/Benchmark_CLASSIC_plots.tar"
fluxnet_archive="$archives/zenodo-18202323/FLUXNET.tar.gz"

for path in "$extraction_root" "$build_dir" "$run_dir"; do
    if [[ -e $path ]]; then
        printf 'Refusing to replace existing path: %s\n' "$path" >&2
        exit 2
    fi
done

"$julia_bin" --startup-file=no "$control_dir/classic_workspace.jl" \
    verify "$control_dir/manifest.toml" "$workspace"

mkdir -p "$source_dir" "$published_root" "$build_dir" "$run_dir"
commands_log="$build_dir/commands.log"

record_command() {
    printf '$' >> "$commands_log"
    printf ' %q' "$@" >> "$commands_log"
    printf '\n' >> "$commands_log"
}

run_recorded() {
    record_command "$@"
    "$@"
}

run_logged() {
    local log=$1
    shift
    record_command "$@"
    "$@" > "$log" 2>&1
}

run_recorded tar -xzf "$source_archive" --strip-components=1 -C "$source_dir"

container_dir="$source_dir/tools/apptainerContainerRecipe"
run_recorded tar -xzf "$container_archive" -C "$container_dir"

run_recorded tar -xzf "$fluxnet_archive" -C "$extraction_root"
mkdir -p "$source_dir/inputFiles/CO2"
run_recorded mv "$fluxnet_stage/TRENDY_v13_CO2_1700-2023_GCP2024.nc" "$source_dir/inputFiles/CO2/"
run_recorded mv "$fluxnet_stage/meteorology" "$source_dir/inputFiles/"
run_recorded mv "$fluxnet_stage/FLUXNETsites_obs" "$source_dir/inputFiles/"
rmdir "$fluxnet_stage"

run_recorded tar -xzf "$benchmark_archive" -C "$published_root" Benchmark_CLASSIC_output/DE-Hai

sif="$container_dir/CLASSIC_container.sif"
{
    printf 'captured_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'source_tag=CLASSICv2.0\n'
    printf 'source_commit=7dd82c9a48a7c8beb6455a229888c90ba20d8eff\n'
    printf 'source_tag_url=https://gitlab.com/cccma/classic/-/tags/CLASSICv2.0\n'
    printf 'container_record=https://zenodo.org/records/18201505\n'
    printf 'benchmark_record=https://zenodo.org/records/18202323\n'
    printf 'workspace=%s\n' "$workspace"
    printf 'source_dir=%s\n' "$source_dir"
    printf 'build_dir=%s\n' "$build_dir"
    printf 'run_dir=%s\n' "$run_dir"
    printf 'published_de_hai=%s\n' "$published_root/Benchmark_CLASSIC_output/DE-Hai/netCDF"
    uname -a
    "$julia_bin" --version
    apptainer --version
    tar --version
} > "$build_dir/environment.txt"

sha256sum \
    "$source_archive" \
    "$container_archive" \
    "$benchmark_archive" \
    "$plots_archive" \
    "$fluxnet_archive" \
    > "$build_dir/archives.sha256"

md5sum \
    "$source_archive" \
    "$container_archive" \
    "$benchmark_archive" \
    "$plots_archive" \
    "$fluxnet_archive" \
    > "$build_dir/archives.md5"

run_logged "$build_dir/container-inspect.log" apptainer inspect "$sif"
run_logged "$build_dir/container-toolchain.log" \
    apptainer exec --no-mount bind-paths \
    --bind "$source_dir:/work_zone/classic_tmp" \
    "$sif" /bin/bash -c \
    'gfortran --version; python3 --version; nc-config --version; nf-config --version'

run_logged "$build_dir/make-clean.log" \
    apptainer exec --no-mount bind-paths \
    --bind "$source_dir:/work_zone/classic_tmp" \
    "$sif" make -C /work_zone/classic_tmp mode=serial clean

run_logged "$build_dir/make.log" \
    apptainer exec --no-mount bind-paths \
    --bind "$source_dir:/work_zone/classic_tmp" \
    "$sif" make -C /work_zone/classic_tmp mode=serial

binary="$source_dir/bin/CLASSIC_serial"
if [[ ! -x $binary ]]; then
    printf 'Official build did not produce %s\n' "$binary" >&2
    exit 1
fi

run_logged "$run_dir/prep_jobopts.log" \
    "$source_dir/tools/siteLevelFLUXNET/prep_jobopts.sh" "$run_dir"

input_dir="$source_dir/inputFiles"
sha256sum \
    "$sif" \
    "$binary" \
    "$source_dir/configurationFiles/model_parameters.json" \
    "$source_dir/configurationFiles/outputVariableDescriptors.xml" \
    "$source_dir/configurationFiles/template_job_options_file.txt" \
    "$source_dir/inputFiles/FLUXNETsites_12PFT/DE-Hai/DE-Hai_init.cdl" \
    "$source_dir/inputFiles/FLUXNETsites_12PFT/DE-Hai/siteinfo.yaml" \
    "$input_dir/CO2/TRENDY_v13_CO2_1700-2023_GCP2024.nc" \
    "$input_dir/meteorology/DE-Hai/metVar_ap.nc" \
    "$input_dir/meteorology/DE-Hai/metVar_lw.nc" \
    "$input_dir/meteorology/DE-Hai/metVar_pr.nc" \
    "$input_dir/meteorology/DE-Hai/metVar_qa.nc" \
    "$input_dir/meteorology/DE-Hai/metVar_sw.nc" \
    "$input_dir/meteorology/DE-Hai/metVar_ta.nc" \
    "$input_dir/meteorology/DE-Hai/metVar_wi.nc" \
    "$run_dir/model_params.nml" \
    "$run_dir/DE-Hai/DE-Hai_init.nc" \
    "$run_dir/DE-Hai/job_options_file.txt" \
    "$run_dir/DE-Hai/rsfile.nc" \
    > "$run_dir/prepared-inputs.sha256"

run_logged "$run_dir/DE-Hai.log" \
    apptainer exec --no-mount bind-paths \
    --bind "$source_dir:/work_zone/classic_tmp" \
    --bind "$run_dir:/work_zone/run_tmp" \
    "$sif" /work_zone/classic_tmp/bin/CLASSIC_serial \
    /work_zone/run_tmp/DE-Hai/job_options_file.txt 0/0

sha256sum "$run_dir/DE-Hai/rsfile.nc" > "$run_dir/final-restart.sha256"

output_dir="$run_dir/outputFiles/DE-Hai/netCDF"
find "$output_dir" -maxdepth 1 -type f -name '*.nc' -print0 \
    | sort -z \
    | xargs -0 sha256sum \
    > "$run_dir/output-files.sha256"

sha256sum \
    "$commands_log" \
    "$build_dir/environment.txt" \
    "$build_dir/container-inspect.log" \
    "$build_dir/container-toolchain.log" \
    "$build_dir/make-clean.log" \
    "$build_dir/make.log" \
    "$run_dir/prep_jobopts.log" \
    "$run_dir/DE-Hai.log" \
    > "$run_dir/logs.sha256"

output_count=$(find "$output_dir" -maxdepth 1 -type f -name '*.nc' | wc -l)
{
    printf 'completed_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'site=DE-Hai\n'
    printf 'run_status=success\n'
    printf 'output_count=%s\n' "$output_count"
    printf 'output_dir=%s\n' "$output_dir"
    printf 'published_output_dir=%s\n' "$published_root/Benchmark_CLASSIC_output/DE-Hai/netCDF"
    printf 'commands_log=%s\n' "$commands_log"
    printf 'input_hashes=%s\n' "$run_dir/prepared-inputs.sha256"
    printf 'final_restart_hash=%s\n' "$run_dir/final-restart.sha256"
    printf 'output_hashes=%s\n' "$run_dir/output-files.sha256"
    printf 'log_hashes=%s\n' "$run_dir/logs.sha256"
} > "$run_dir/receipt.txt"

printf 'DE-Hai completed with %s NetCDF outputs.\n' "$output_count"
printf 'Receipt: %s\n' "$run_dir/receipt.txt"
