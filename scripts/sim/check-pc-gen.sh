#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
# Native FuseSoC build/run with a private evidence directory per invocation.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"
build_root=${BUILD_DIR:-"$repo_root/build"}/pc-gen
boot_pc=${BOOT_PC:-0}
boot_fields=$(python3 -c 'import sys
value = int(sys.argv[1], 0)
if not 0 <= value < 2**64:
    raise ValueError("BOOT_PC must be an unsigned 64-bit address")
print(value >> 32, value & 0xffffffff)' "$boot_pc")
read -r boot_high boot_low <<< "$boot_fields"
seed=${SEED:-1}
scenario=${SCENARIO:-all}
mkdir -p "$build_root"
touch "${BUILD_DIR:-$repo_root/build}/FUSESOC_IGNORE"
mkdir -p "$repo_root/build"
touch "$repo_root/build/FUSESOC_IGNORE"
# The executable name is fixed by the test-only top. Distinct boot parameters
# have distinct build directories. FuseSoC still owns compilation and execution.
model_dir=$(python3 tb/frontend/pc_gen/configuration.py --model-dir --boot "$boot_pc" --build-dir "${BUILD_DIR:-$repo_root/build}")
fingerprint=${model_dir##*issues-*-}
mkdir -p "$model_dir"
exec 9>"$model_dir/build.lock"
flock 9
if [[ ${VERILATOR:-verilator} == */* ]]; then
    export PATH="$(dirname -- "$VERILATOR"):$PATH"
fi
echo '## Building pc_gen simulation model with Verilator...'
if ! "${FUSESOC:-fusesoc}" run --no-export --target sim --tool verilator \
    --build-root "$model_dir" --setup --build polito:len5:pc-gen-tb \
    --BOOT_PC_HI="$boot_high" --BOOT_PC_LO="$boot_low" > "$model_dir/build.log" 2>&1; then
    tail -n 60 "$model_dir/build.log" >&2
    echo "pc_gen build failed; see $model_dir/build.log" >&2
    echo "Test failed: pc_gen build" >&2
    exit 2
fi
echo '## pc_gen build complete.'
python3 tb/frontend/pc_gen/configuration.py --boot "$boot_pc" --build-dir "${BUILD_DIR:-$repo_root/build}" \
    --expect-fingerprint "$fingerprint" --write-manifest "$model_dir/sim-verilator"
if [[ ${PC_GEN_BUILD_ONLY:-false} == true ]]; then exit 0; fi
mkdir -p "$build_root/run"
run_dir=$(mktemp -d "$build_root/run/$scenario-$seed-XXXXXX")
echo "## pc_gen evidence: $run_dir"
cycle_limit=${MAX_CYCLES:-50000}
if [[ ${RANDOM_MODE:-false} == true && -z ${MAX_CYCLES:-} ]]; then cycle_limit=${CYCLES:-10000}; fi
arguments=(--BOOT_PC_HI="$boot_high" --BOOT_PC_LO="$boot_low" --seed="$seed" --scenario="$scenario"
    --log_level="${LOG_LEVEL:-LOG_LOW}" --max_cycles="$cycle_limit"
    --dump_waves="${DUMP_WAVES:-false}" --contract="${PC_GEN_CONTRACT:-proposed}" --run_dir="$run_dir")
if [[ ${RANDOM_MODE:-false} == true ]]; then
    arguments+=(--random --cycles="${CYCLES:-10000}" --campaign="${CAMPAIGN:-all}"
        --weights="${WEIGHTS:-}" --guided="${GUIDED:-true}" --journal="${JOURNAL:-auto}")
fi
if [[ -n ${EARLY_ACCEPT:-} ]]; then arguments+=(--early_accept="$EARLY_ACCEPT"); fi
if [[ -n ${EARLY_TARGET:-} ]]; then arguments+=(--early_target="$EARLY_TARGET"); fi
if [[ -n ${INJECT_FAILURE:-} ]]; then arguments+=(--inject_failure="$INJECT_FAILURE"); fi
set +e
"${FUSESOC:-fusesoc}" run --no-export --target sim --tool verilator \
    --build-root "$model_dir" --run polito:len5:pc-gen-tb "${arguments[@]}" \
    > "$run_dir/console.log" 2>&1
result=$?
set -e
cat "$run_dir/console.log"
echo "## pc_gen console log: $run_dir/console.log"
if [[ $result == 0 ]]; then
    echo 'Test successfully passed: pc_gen run'
else
    echo 'Test failed: pc_gen run'
fi
exit "$result"
