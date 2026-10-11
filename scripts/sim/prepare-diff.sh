#!/usr/bin/env bash
# FuseSoC pre-build hook: prepare Spike and checker metadata, not the RTL binary.
set -euo pipefail

len5_root=$(cd "$FILES_ROOT" && pwd)
spike_source=${SPIKE_SRC:-$len5_root/sw/vendor/riscv-isa-sim}
spike_build=${SPIKE_BUILD:-$len5_root/build/spike-build}
verilator_tool=${VERILATOR:-verilator}

case $("$verilator_tool" --version) in
    'Verilator 5.040'*) ;;
    *) echo 'Differential verification requires Verilator 5.040 (XML API).' >&2; exit 1 ;;
esac

SPIKE_SRC="$spike_source" SPIKE_BUILD="$spike_build" \
    bash "$len5_root/scripts/sim/prepare-spike.sh"
spike_source=$(cd "$spike_source" && pwd)
spike_build=$(cd "$spike_build" && pwd)

# Edalize consumes this options file when it invokes Verilator and Make.
cat > diff-options.vc <<EOF
-CFLAGS "-std=c++17 -DLEN5_DIFF -I. -I$spike_build -I$spike_source -I$spike_source/riscv -I$spike_source/softfloat"
-LDFLAGS "$spike_build/libriscv.a $spike_build/libdisasm.a $spike_build/libsoftfloat.a $spike_build/libfesvr.a -ldl -lpthread -lz"
EOF

# Use Edalize's generated XML target; Python only reads metadata into a header.
# Verilator diagnoses --xml-only while parsing it, before trailing options.
make --no-print-directory -s xml-only "VERILATOR=$verilator_tool -Wno-DEPRECATED" > diff-xml.log 2>&1 || {
    tail -n 60 diff-xml.log >&2
    exit 1
}
python3 "$len5_root/tb/verilator/diff/layout.py" Vtb_bare.xml diff_layout.hh \
    --words-output diff-vpi-words.txt
printf '\n-CFLAGS "-DVL_VALUE_STRING_MAX_WORDS=%s"\n' "$(cat diff-vpi-words.txt)" >> diff-options.vc
printf '\nMAKE_OPTIONS += -j%s\n' "${JOBS:-4}" >> config.mk

# Ensure FuseSoC regenerates the model after RTL or checker options change.
rm -f Vtb_bare.mk
