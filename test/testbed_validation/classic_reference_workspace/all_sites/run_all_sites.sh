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
run_id=${2:-issue-98-all-sites-pristine}
julia_bin=${JULIA:-julia}

if [[ ! $run_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    printf 'RUN_ID must be a single safe path component: %s\n' "$run_id" >&2
    exit 2
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(realpath "$script_dir/../../../..")
control_dir="$repo_root/test/testbed_validation/classic_reference_workspace"
campaign_julia="$script_dir/campaign.jl"

archives="$workspace/immutable/archives"
replaceable="$workspace/replaceable"
extraction_root="$replaceable/extracted/$run_id"
source_dir="$extraction_root/CLASSIC"
fluxnet_stage="$extraction_root/FLUXNET"
published_root="$extraction_root/published"
build_dir="$replaceable/builds/$run_id"
run_dir="$replaceable/runs/$run_id"
evidence_root="$run_dir/site-evidence"

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

mkdir -p "$source_dir" "$published_root" "$build_dir" "$run_dir" "$evidence_root"
commands_log="$build_dir/commands.log"

record_command_to() {
    local destination=$1
    shift
    printf '$' >> "$destination"
    printf ' %q' "$@" >> "$destination"
    printf '\n' >> "$destination"
}

record_command() {
    record_command_to "$commands_log" "$@"
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
run_recorded mv \
    "$fluxnet_stage/TRENDY_v13_CO2_1700-2023_GCP2024.nc" \
    "$source_dir/inputFiles/CO2/"
run_recorded mv "$fluxnet_stage/meteorology" "$source_dir/inputFiles/"
run_recorded mv "$fluxnet_stage/FLUXNETsites_obs" "$source_dir/inputFiles/"
rmdir "$fluxnet_stage"
run_recorded tar -xzf "$benchmark_archive" -C "$published_root"

sif="$container_dir/CLASSIC_container.sif"
{
    printf 'captured_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'source_tag=CLASSICv2.0\n'
    printf 'source_commit=7dd82c9a48a7c8beb6455a229888c90ba20d8eff\n'
    printf 'source_tag_url=https://gitlab.com/cccma/classic/-/tags/CLASSICv2.0\n'
    printf 'container_record=https://zenodo.org/records/18201505\n'
    printf 'benchmark_record=https://zenodo.org/records/18202323\n'
    printf 'oracle_kind=fresh_local_fortran\n'
    printf 'published_parity_claimed=false\n'
    printf 'workspace=%s\n' "$workspace"
    printf 'source_dir=%s\n' "$source_dir"
    printf 'build_dir=%s\n' "$build_dir"
    printf 'run_dir=%s\n' "$run_dir"
    uname -a
    "$julia_bin" --version
    apptainer --version
    tar --version
} > "$build_dir/environment.txt"

sha256sum \
    "$source_archive" "$container_archive" "$benchmark_archive" \
    "$plots_archive" "$fluxnet_archive" > "$build_dir/archives.sha256"
md5sum \
    "$source_archive" "$container_archive" "$benchmark_archive" \
    "$plots_archive" "$fluxnet_archive" > "$build_dir/archives.md5"

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

published_sites="$published_root/Benchmark_CLASSIC_output"
configuration_sites="$source_dir/inputFiles/FLUXNETsites_12PFT"
site_list="$run_dir/site-list.txt"
"$julia_bin" --project="$repo_root/.buildkite" --startup-file=no \
    "$campaign_julia" validate-sites \
    "$configuration_sites" "$published_sites" "$site_list"

sha256sum \
    "$sif" "$binary" \
    "$source_dir/configurationFiles/model_parameters.json" \
    "$source_dir/configurationFiles/outputVariableDescriptors.xml" \
    "$source_dir/configurationFiles/template_job_options_file.txt" \
    "$run_dir/model_params.nml" \
    > "$build_dir/shared-execution-inputs.sha256"

campaign_failed=0
while IFS= read -r site; do
    evidence="$evidence_root/$site"
    run_site="$run_dir/$site"
    output_dir="$run_dir/outputFiles/$site/netCDF"
    published_dir="$published_sites/$site/netCDF"
    mkdir -p "$evidence"

    sha256sum \
        "$configuration_sites/$site/${site}_init.cdl" \
        "$configuration_sites/$site/siteinfo.yaml" \
        "$source_dir/inputFiles/meteorology/$site/metVar_ap.nc" \
        "$source_dir/inputFiles/meteorology/$site/metVar_lw.nc" \
        "$source_dir/inputFiles/meteorology/$site/metVar_pr.nc" \
        "$source_dir/inputFiles/meteorology/$site/metVar_qa.nc" \
        "$source_dir/inputFiles/meteorology/$site/metVar_sw.nc" \
        "$source_dir/inputFiles/meteorology/$site/metVar_ta.nc" \
        "$source_dir/inputFiles/meteorology/$site/metVar_wi.nc" \
        "$source_dir/inputFiles/CO2/TRENDY_v13_CO2_1700-2023_GCP2024.nc" \
        "$run_dir/model_params.nml" \
        "$run_site/${site}_init.nc" \
        "$run_site/job_options_file.txt" \
        > "$evidence/prepared-inputs.sha256"
    sha256sum "$run_site/rsfile.nc" > "$evidence/initial-restart.sha256"

    model_command=(
        apptainer exec --no-mount bind-paths
        --bind "$source_dir:/work_zone/classic_tmp"
        --bind "$run_dir:/work_zone/run_tmp"
        "$sif" /work_zone/classic_tmp/bin/CLASSIC_serial
        "/work_zone/run_tmp/$site/job_options_file.txt" 0/0
    )
    : > "$evidence/command.txt"
    record_command_to "$evidence/command.txt" "${model_command[@]}"

    set +e
    "${model_command[@]}" > "$evidence/run.log" 2>&1
    run_status=$?
    set -e

    if [[ $run_status -eq 0 ]]; then
        sha256sum "$run_site/rsfile.nc" > "$evidence/final-restart.sha256"
        find "$output_dir" -maxdepth 1 -type f -name '*.nc' -print0 \
            | sort -z | xargs -0 -r sha256sum \
            > "$evidence/outputs.sha256"
    fi

    set +e
    "$julia_bin" --project="$repo_root/.buildkite" --startup-file=no \
        "$campaign_julia" compare-site \
        "$site" "$published_dir" "$output_dir" \
        "$evidence/published-comparison.toml" \
        > "$evidence/comparison.log" 2>&1
    comparison_status=$?
    "$julia_bin" --project="$repo_root/.buildkite" --startup-file=no \
        "$campaign_julia" site-receipt \
        "$site" "$evidence" "$run_site" "$output_dir" \
        "$evidence/receipt.toml" "$run_status" "$comparison_status" \
        >> "$evidence/comparison.log" 2>&1
    receipt_status=$?
    set -e

    if [[ $run_status -ne 0 || $comparison_status -ne 0 || $receipt_status -ne 0 ]]; then
        campaign_failed=1
    fi
done < "$site_list"

set +e
"$julia_bin" --project="$repo_root/.buildkite" --startup-file=no \
    "$campaign_julia" campaign-summary \
    "$site_list" "$evidence_root" "$run_dir/campaign-summary.toml"
summary_status=$?
set -e

sha256sum \
    "$commands_log" "$build_dir/environment.txt" \
    "$build_dir/archives.sha256" \
    "$build_dir/shared-execution-inputs.sha256" \
    "$build_dir/container-inspect.log" \
    "$build_dir/container-toolchain.log" \
    "$build_dir/make-clean.log" "$build_dir/make.log" \
    "$run_dir/prep_jobopts.log" "$site_list" \
    "$run_dir/campaign-summary.toml" \
    > "$run_dir/campaign-evidence.sha256"

if [[ $campaign_failed -ne 0 || $summary_status -ne 0 ]]; then
    printf 'Campaign incomplete; inspect %s\n' "$run_dir/campaign-summary.toml" >&2
    exit 1
fi

printf 'All 59 fresh local Fortran runs completed.\n'
printf 'Published comparison status is recorded separately in %s\n' \
    "$run_dir/campaign-summary.toml"
