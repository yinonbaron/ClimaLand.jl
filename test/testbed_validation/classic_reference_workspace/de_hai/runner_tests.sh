#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
runner="$script_dir/run_pristine.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/workspace"
marker="$tmp/julia-arguments.txt"
fake_julia="$tmp/fake-julia"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" > "$TEST_MARKER"' \
    'exit 23' \
    > "$fake_julia"
chmod +x "$fake_julia"

set +e
TEST_MARKER="$marker" JULIA="$fake_julia" \
    "$runner" "$tmp/workspace" ../escape \
    > "$tmp/traversal-stdout" 2> "$tmp/traversal-stderr"
traversal_status=$?
set -e

[[ $traversal_status -eq 2 ]]
grep -F -- 'single safe path component' "$tmp/traversal-stderr" > /dev/null
[[ ! -e $marker ]]
[[ ! -e "$tmp/escape" ]]
[[ ! -e "$tmp/workspace/replaceable" ]]

set +e
TEST_MARKER="$marker" JULIA="$fake_julia" \
    "$runner" "$tmp/workspace" contract-test \
    > "$tmp/stdout" 2> "$tmp/stderr"
status=$?
set -e

[[ $status -eq 23 ]]
grep -F -- '--startup-file=no' "$marker" > /dev/null
grep -F -- 'classic_workspace.jl verify' "$marker" > /dev/null
grep -F -- "$tmp/workspace" "$marker" > /dev/null
[[ ! -e "$tmp/workspace/replaceable" ]]

printf 'runner contract: ok\n'
