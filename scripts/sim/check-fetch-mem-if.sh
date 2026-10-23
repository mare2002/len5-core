#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Adapted from check-pc-gen.sh: source fingerprint, build lock and private evidence.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"
build_root=${BUILD_DIR:-"$repo_root/build"}/fetch-mem-if
model_dir=$(python3 tb/frontend/fetch_mem_if/configuration.py --model-dir --build-dir "${BUILD_DIR:-$repo_root/build}")
fingerprint=${model_dir##*-}
metadata_depth=$(python3 tb/frontend/fetch_mem_if/configuration.py --depth)
mkdir -p "$model_dir"
touch "${BUILD_DIR:-$repo_root/build}/FUSESOC_IGNORE"
exec 9>"$model_dir/build.lock"
flock 9
if [[ ${VERILATOR:-verilator} == */* ]]; then export PATH="$(dirname -- "$VERILATOR"):$PATH"; fi
if [[ ! -x "$model_dir/sim-verilator/Vfetch_mem_tb" || ! -f "$model_dir/sim-verilator/fetch_mem_build.cfg" ]]; then
    echo '## Building fetch_mem_if with real FIFO/spills using Verilator...'
    if ! "${FUSESOC:-fusesoc}" run --target sim --tool verilator \
        --build-root "$model_dir" --setup --build polito:len5:fetch-mem-if-tb --MEM_DEPTH="$metadata_depth" > "$model_dir/build.log" 2>&1; then
        tail -n 60 "$model_dir/build.log" >&2
        echo "Test failed: fetch_mem build; see $model_dir/build.log" >&2
        exit 2
    fi
    python3 tb/frontend/fetch_mem_if/configuration.py --build-dir "${BUILD_DIR:-$repo_root/build}" \
        --expect-fingerprint "$fingerprint" --write-manifest "$model_dir/sim-verilator"
fi
echo '## fetch_mem build complete (source-fingerprinted configuration).'
if [[ ${FETCH_MEM_BUILD_ONLY:-false} == true ]]; then exit 0; fi
flock -u 9
mkdir -p "$build_root/run"
run_dir=$(mktemp -d "$build_root/run/${SCENARIO:-all}-${SEED:-1}-XXXXXX")
arguments=(--seed="${SEED:-1}" --scenario="${SCENARIO:-all}" --run_dir="$run_dir"
    --log_level="${LOG_LEVEL:-LOG_LOW}" --max_cycles="${MAX_CYCLES:-100000}"
    --dump_waves="${DUMP_WAVES:-false}" --contract="${FETCH_MEM_CONTRACT:-integrated}")
if [[ ${RANDOM_MODE:-false} == true ]]; then
    arguments+=(--random --cycles="${CYCLES:-10000}" --campaign="${CAMPAIGN:-all}"
        --weights="${WEIGHTS:-}" --guided="${GUIDED:-true}" --journal="${JOURNAL:-auto}")
fi
if [[ -n ${INJECT_FAILURE:-} ]]; then arguments+=(--inject_failure="$INJECT_FAILURE"); fi
set +e
"$model_dir/sim-verilator/Vfetch_mem_tb" "${arguments[@]}" > "$run_dir/console.log" 2>&1
result=$?
set -e
cat "$run_dir/console.log"
echo "## fetch_mem evidence: $run_dir"
if [[ $result == 0 ]]; then echo 'Test successfully passed: fetch_mem run'; else echo 'Test failed: fetch_mem run'; fi
exit "$result"
