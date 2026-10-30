#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Adapted from check-pc-gen.sh: source fingerprint, build lock and private evidence.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"
config_output=$(bash scripts/sim/config-args.sh rtl fusesoc)
config_args=()
if [[ -n $config_output ]]; then mapfile -t config_args <<< "$config_output"; fi
build_root=${BUILD_DIR:-"$repo_root/build"}/early-jump
model_dir=$(python3 tb/frontend/early_jump_unit/configuration.py --model-dir --build-dir "${BUILD_DIR:-$repo_root/build}")
fingerprint=${model_dir##*-}
mkdir -p "$model_dir"
mkdir -p "$repo_root/build"
touch "$repo_root/build/FUSESOC_IGNORE"
touch "${BUILD_DIR:-$repo_root/build}/FUSESOC_IGNORE"
exec 9>"$model_dir/build.lock"
flock 9
if [[ ${VERILATOR:-verilator} == */* ]]; then export PATH="$(dirname -- "$VERILATOR"):$PATH"; fi
if [[ ! -x "$model_dir/sim-verilator/Vearly_jump_tb" || ! -f "$model_dir/sim-verilator/early_jump_build.cfg" ]]; then
    echo '## Building early_jump_unit with real RAS using Verilator...'
    if ! "${FUSESOC:-fusesoc}" run --no-export --target sim --tool verilator \
        --build-root "$model_dir" --setup --build polito:len5:early-jump-tb "${config_args[@]}" > "$model_dir/build.log" 2>&1; then
        tail -n 60 "$model_dir/build.log" >&2
        echo "Test failed: early_jump build; see $model_dir/build.log" >&2
        exit 2
    fi
    python3 tb/frontend/early_jump_unit/configuration.py --build-dir "${BUILD_DIR:-$repo_root/build}" \
        --expect-fingerprint "$fingerprint" --write-manifest "$model_dir/sim-verilator"
fi
echo '## early_jump build complete (source-fingerprinted configuration).'
if [[ ${EARLY_JUMP_BUILD_ONLY:-false} == true ]]; then exit 0; fi
flock -u 9
mkdir -p "$build_root/run"
run_dir=$(mktemp -d "$build_root/run/${SCENARIO:-all}-${SEED:-1}-XXXXXX")
arguments=(--seed="${SEED:-1}" --scenario="${SCENARIO:-all}" --run_dir="$run_dir"
    --log_level="${LOG_LEVEL:-LOG_LOW}" --max_cycles="${MAX_CYCLES:-100000}"
    --dump_waves="${DUMP_WAVES:-false}" --contract="${EARLY_JUMP_CONTRACT:-len5_minimal}")
if [[ ${RANDOM_MODE:-false} == true ]]; then
    arguments+=(--random --cycles="${CYCLES:-10000}" --campaign="${CAMPAIGN:-all}"
        --weights="${WEIGHTS:-}" --guided="${GUIDED:-true}" --journal="${JOURNAL:-auto}")
fi
for pair in "order:${RAS_ORDER:-}" "exception:${RAS_EXCEPTION:-}" "boundaries:${RAS_BOUNDARIES:-}" "lifecycle:${EARLY_LIFECYCLE:-}"; do
    key=${pair%%:*}; value=${pair#*:}
    if [[ -n $value ]]; then arguments+=("--$key=$value"); fi
done
if [[ -n ${INJECT_FAILURE:-} ]]; then arguments+=(--inject_failure="$INJECT_FAILURE"); fi
set +e
"$model_dir/sim-verilator/Vearly_jump_tb" "${arguments[@]}" > "$run_dir/console.log" 2>&1
result=$?
set -e
cat "$run_dir/console.log"
echo "## early_jump evidence: $run_dir"
if [[ $result == 0 ]]; then echo 'Test successfully passed: early_jump run'; else echo 'Test failed: early_jump run'; fi
exit "$result"
