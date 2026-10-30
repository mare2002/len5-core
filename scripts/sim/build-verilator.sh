#!/usr/bin/env bash
# Cache and quiet a native FuseSoC build. Usage: build-verilator.sh target root [flags...]
set -euo pipefail

target=$1
build_root=$2
shift 2
len5_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$len5_root"
config_output=$(bash scripts/sim/config-args.sh all fusesoc)
config_args=()
if [[ -n $config_output ]]; then
    mapfile -t config_args <<< "$config_output"
fi
mkdir -p "$build_root"
build_root=$(cd "$build_root" && pwd)
stamp="$build_root/.verilator.lock"
config="$build_root/.verilator-config"
log="$build_root/build.log"
executable="$build_root/$target-verilator/Vtb_bare"

# Recheck the cache while holding the lock, including across recursive Make runs.
exec 9>"$build_root/.verilator-build.lock"
flock 9

if [[ $target == sim-diff ]]; then
    export CCACHE_DISABLE=1
    export SPIKE_SRC=${SPIKE_SRC:-$len5_root/sw/vendor/riscv-isa-sim}
    export SPIKE_BUILD=${SPIKE_BUILD:-$len5_root/build/spike-build}
    mkdir -p "$SPIKE_BUILD"
    SPIKE_SRC=$(cd "$SPIKE_SRC" && pwd)
    SPIKE_BUILD=$(cd "$SPIKE_BUILD" && pwd)
    bash scripts/sim/prepare-spike.sh
fi

mapfile -t sources < <(
    find . -type d \( -name .git -o -path ./build -o -path ./sw/vendor \) -prune \
        -o -type f -name '*.core' -print
    find rtl tb -type f \( -name '*.sv' -o -name '*.svh' -o -name '*.v' \
        -o -name '*.vlt' -o -name '*.cpp' -o -name '*.hh' \) -print
)
sources+=(makefile scripts/sim/build-verilator.sh scripts/sim/copy-logs.sh scripts/sim/config-args.sh)
if [[ $target == sim-diff ]]; then
    sources+=(scripts/sim/prepare-diff.sh scripts/sim/prepare-spike.sh tb/verilator/diff/layout.py \
        tb/verilator/diff/bootstrap_spike.py)
fi

# Hash sources and configuration so deletions and backdated edits invalidate reuse.
fingerprint=$(
    {
        printf '%s\n' "$target" "$build_root" "${FUSESOC:-fusesoc}" "${VERILATOR:-verilator}" \
            "${SPIKE_SRC-}" "${SPIKE_BUILD-}" "${CC-}" "${CXX-}" "${AR-}" \
            "${CFLAGS-}" "${CXXFLAGS-}" "${CPPFLAGS-}" "${LDFLAGS-}" "$PATH" "$@" "${config_args[@]}"
        "${VERILATOR:-verilator}" --version
        "${FUSESOC:-fusesoc}" --version
        sha256sum "${sources[@]}"
        if [[ $target == sim-diff ]]; then
            stat --printf='%n:%s:%y\n' "$SPIKE_BUILD"/{libriscv,libdisasm,libsoftfloat,libfesvr}.a
        fi
    } | sha256sum
)
if [[ -f $stamp && -x $executable && -f $config && $(cat "$config") == "$fingerprint" ]]; then
    exit 0
fi

verbose=()
case ${VERBOSE:-false} in true|1|yes) verbose=(--verbose);; esac
command=("${FUSESOC:-fusesoc}" "${verbose[@]}" run --no-export --target "$target" \
    --tool verilator --build-root "$build_root" "$@" --setup --build polito:len5:len5 "${config_args[@]}")

rm -f "$stamp"
echo '## Building RTL with Verilator...'
if [[ ${#verbose[@]} != 0 ]]; then
    "${command[@]}"
else
    "${command[@]}" > "$log" 2>&1 || {
        status=$?
        tail -n 60 "$log" >&2
        echo "RTL build failed; see $log" >&2
        exit "$status"
    }
fi
printf '%s\n' "$fingerprint" > "$config"
touch "$stamp"
echo '## RTL build complete.'
