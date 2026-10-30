#!/usr/bin/env bash
# Translate explicit environment overrides to tool arguments; defaults/derivations live in SV.
set -euo pipefail
kind=${1:-all}
format=${2:-fusesoc}
exclude=${3:-}
rtl='BOOT_VM_MODE BOOT_PC LEN5_MULTIPLE_ISSUES LEN5_M_EN LEN5_DIV_EN LEN5_F_EN LEN5_D_EN LEN5_C_EN LEN5_A_EN LEN5_STORE_LOAD_FWD_EN MAX_EU_N ONLY_DOUBLEWORD_MEM_ACCESSES LEN5_CSR_HPMCOUNTERS_EN MMAP_MASK BPU_HLEN BPU_BTB_BITS RAS_DEPTH FETCH_MEMIF_FIFO_DEPTH FETCH_MEM_DRAIN_ON_FLUSH LOAD_BUFFER_DRAIN_ON_FLUSH FETCH_REQ_SPILL_SKIP FETCH_ANS_SPILL_SKIP IQ_DEPTH LDBUFF_DEPTH STBUFF_DEPTH LSU_SPILL_SKIP ALU_RS_DEPTH ALU_SPILL_SKIP ALU_RR_ARBITER MULT_RS_DEPTH LEN5_MULT_SERIAL MULT_PIPE_DEPTH MULT_RR_ARBITER DIV_RS_DEPTH DIV_RR_ARBITER FPU_RS_DEPTH FPU_RR_ARBITER FPU_PIPE_DEPTH FPU_SPILL_SKIP BU_RS_DEPTH BU_SPILL_SKIP ROB_DEPTH COMMIT_SPILL_SKIP BPU_INIT_C2B'
tb='MEMORY_BACKEND AXI_CLOCK_HALF_PERIOD_PS IMEM_BASE_ADDR IMEM_SIZE_BYTES IMEM_LATENCY DMEM_BASE_ADDR DMEM_SIZE_BYTES DMEM_LATENCY SERIAL_ADDR EXIT_ADDR SRAM_SIM_INIT'
case $kind in rtl) names=$rtl;; tb) names=$tb;; all) names="$rtl $tb";; *) echo "Invalid configuration domain: $kind" >&2; exit 2;; esac
for name in $names; do
    [[ -v $name && ,$exclude, != *,$name,* ]] || continue
    value=${!name}
    if [[ $name == SRAM_SIM_INIT ]]; then
        case $value in none|zeros|ones|random) ;; *) echo 'Invalid SRAM_SIM_INIT' >&2; exit 2;; esac
        if [[ $format == verilator ]]; then printf '%s\n' "-G$name=\"$value\""; else printf '%s\n' "--$name=$value"; fi
        continue
    fi
    case $value in
        true|yes|BARE|LEGACY|MEM_BACKEND_LEGACY) value=0; [[ ${!name} == true || ${!name} == yes ]] && value=1;;
        false|no) value=0;;
        SV39|TC_SRAM|MEM_BACKEND_TC_SRAM) value=1;;
        SV48|AXI_SIM|MEM_BACKEND_AXI_SIM) value=2;;
    esac
    literal_bits=64
    if [[ $value =~ ^([0-9]+)\'[sS]?([bBoOdDhH])([0-9a-fA-F_]+)$ ]]; then
        literal_bits=${BASH_REMATCH[1]}
        base=${BASH_REMATCH[2],,}
        digits=${BASH_REMATCH[3]//_/}
        [[ $literal_bits -ge 1 && $literal_bits -le 64 ]] || exit 2
        case $base in
            h) value=0x$digits;;
            d) [[ $digits =~ ^[0-9]+$ ]] || exit 2; value=$digits;;
            b) [[ $digits =~ ^[01]{1,64}$ ]] || exit 2; printf -v value '%u' "$((2#$digits))";;
            o) [[ $digits =~ ^[0-7]{1,22}$ ]] || exit 2
               [[ ${#digits} -lt 22 || ${digits:0:1} -le 1 ]] || exit 2
               printf -v value '%u' "$((8#$digits))";;
        esac
    elif [[ $value =~ ^[0-9[:space:]*+/()-]+$ && ! $value =~ ^[0-9]+$ ]]; then
        # Numeric-only arithmetic is safe to evaluate; names/subscripts/commands are rejected.
        value=$((value))
        [[ $value -ge 0 ]] || exit 2
    fi
    if [[ ! $value =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]]; then
        echo "$name must be an unsigned decimal/hex integer, boolean, or supported enum" >&2; exit 2
    fi
    if [[ $value =~ ^[0-9]+$ ]]; then
        value=${value#"${value%%[!0]*}"}
        value=${value:-0}
    fi
    # printf parses numeric input without evaluating it as shell arithmetic/code.
    printf -v number '%u' "$value" || exit 2
    if [[ $literal_bits -lt 64 && $((number >> literal_bits)) != 0 ]]; then
        echo "$name contains a truncated SV literal" >&2; exit 2
    fi
    width=32
    case $name in BOOT_PC|MMAP_MASK|IMEM_BASE_ADDR|DMEM_BASE_ADDR|SERIAL_ADDR|EXIT_ADDR) width=64;;
        LEN5_*_EN|LEN5_MULT_SERIAL|ONLY_DOUBLEWORD_MEM_ACCESSES|*_SPILL_SKIP|*_RR_ARBITER|*_DRAIN_ON_FLUSH) width=1;;
    esac
    if [[ $width != 64 && ( ${#number} -gt 10 || ( ${#number} -eq 10 && $number > 4294967295 ) ) ]]; then
        echo "$name exceeds 32 bits" >&2; exit 2
    fi
    if [[ $width == 1 && $number != 0 && $number != 1 ]] ||
       [[ $name == BPU_INIT_C2B && $number -gt 3 ]] ||
       [[ ( $name == BOOT_VM_MODE || $name == MEMORY_BACKEND ) && $number -gt 2 ]]; then
        echo "Invalid $name: $number" >&2; exit 2
    fi
    if [[ $format == verilator ]]; then
        printf -- "-G%s=%s'h%x\n" "$name" "$width" "$number"
    elif [[ $width == 64 ]]; then
        printf -- '--%s_HI=%u\n--%s_LO=%u\n' "$name" "$(( (number >> 32) & 0xffffffff ))" "$name" "$(( number & 0xffffffff ))"
    else
        printf -- '--%s=%s\n' "$name" "$number"
    fi
done
