#!/usr/bin/env bash
# Show actual Spike build progress while saving compiler output in bootstrap.log.
set -euo pipefail

len5_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
spike_source=${SPIKE_SRC:-$len5_root/sw/vendor/riscv-isa-sim}
spike_build=${SPIKE_BUILD:-$len5_root/build/spike-build}
mkdir -p "$spike_build"
log="$spike_build/bootstrap.log"
# Keep concurrent callers from truncating another build's diagnostics.
exec 8>"$spike_build/.len5-spike-output.lock"
flock 8
: > "$log"

if python3 "$len5_root/tb/verilator/diff/bootstrap_spike.py" \
    --source "$spike_source" --build "$spike_build" -j "${JOBS:-4}" --progress 2>&1 |
    while IFS= read -r line || [[ -n $line ]]; do
        case $line in
            __LEN5_SPIKE_BUILD_STARTED__) echo '## Building Spike reference libraries...';;
            __LEN5_SPIKE_BUILD_FINISHED__) echo '## Spike reference library build complete.';;
            *) printf '%s\n' "$line" >> "$log";;
        esac
    done
then
    exit 0
else
    status=$?
    tail -n 60 "$log" >&2
    echo "Spike build failed; see $log" >&2
    exit "$status"
fi
