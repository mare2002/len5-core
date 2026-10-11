# Directed RV64F/D fused-operation regression for the bare testbench.
# riscv64-unknown-elf-gcc -march=rv64imfd_zicsr -mabi=lp64d -nostdlib \
#   -Wl,-Ttext=0x10180 -Wl,--no-relax test_fp_fused.S -o fused.elf
# riscv64-unknown-elf-objcopy -O verilog fused.elf fused.hex
# Run fused.hex through sim-diff; expected program exit code is 0.
.option norvc
.section .text
.globl _start

# Load raw operands through the 64-bit move path to preserve single NaN boxing.
# Check result bits and per-operation exception flags independently of the checker.
.macro check op, a, b, c, expected, flags=0, rm=rne
    li t0, \a
    fmv.d.x f1, t0
    li t0, \b
    fmv.d.x f2, t0
    li t0, \c
    fmv.d.x f3, t0
    csrw fflags, zero
    \op f0, f1, f2, f3, \rm
    fmv.x.d t3, f0
    li t4, \expected
    bne t3, t4, fail
    csrr t3, fflags
    li t4, \flags
    bne t3, t4, fail
.endm

_start:
    li t0, 0x6000
    csrs mstatus, t0

    # a=2, b=3, c=4: distinguish all four fused operations in both precisions.
    check fmadd.d,  0x4000000000000000, 0x4008000000000000, 0x4010000000000000, 0x4024000000000000
    check fmsub.d,  0x4000000000000000, 0x4008000000000000, 0x4010000000000000, 0x4000000000000000
    check fnmadd.d, 0x4000000000000000, 0x4008000000000000, 0x4010000000000000, 0xc024000000000000
    check fnmsub.d, 0x4000000000000000, 0x4008000000000000, 0x4010000000000000, 0xc000000000000000
    check fmadd.s,  0xffffffff40000000, 0xffffffff40400000, 0xffffffff40800000, 0xffffffff41200000
    check fmsub.s,  0xffffffff40000000, 0xffffffff40400000, 0xffffffff40800000, 0xffffffff40000000
    check fnmadd.s, 0xffffffff40000000, 0xffffffff40400000, 0xffffffff40800000, 0xffffffffc1200000
    check fnmsub.s, 0xffffffff40000000, 0xffffffff40400000, 0xffffffff40800000, 0xffffffffc0000000

    # Signed zero and cancellation: static RDN produces negative zero.
    check fnmadd.d, 0, 0x3ff0000000000000, 0, 0x8000000000000000
    check fnmsub.d, 0, 0x3ff0000000000000, 0, 0
    check fnmsub.d, 0, 0x3ff0000000000000, 0, 0x8000000000000000, 0, rdn
    check fnmadd.s, 0xffffffff00000000, 0xffffffff3f800000, 0xffffffff00000000, 0xffffffff80000000
    check fnmsub.s, 0xffffffff00000000, 0xffffffff3f800000, 0xffffffff00000000, 0xffffffff00000000
    check fnmsub.s, 0xffffffff00000000, 0xffffffff3f800000, 0xffffffff00000000, 0xffffffff80000000, 0, rdn

    # Quiet/signalling NaNs and invalid infinity cancellation.
    check fnmadd.d, 0x7ff8000000001234, 0x3ff0000000000000, 0, 0x7ff8000000000000
    check fnmsub.d, 0x7ff0000000001234, 0x3ff0000000000000, 0, 0x7ff8000000000000, 16
    check fnmsub.d, 0x7ff0000000000000, 0x3ff0000000000000, 0x7ff0000000000000, 0x7ff8000000000000, 16
    check fnmadd.s, 0xffffffff7fc01234, 0xffffffff3f800000, 0xffffffff00000000, 0xffffffff7fc00000
    check fnmsub.s, 0xffffffff7f801234, 0xffffffff3f800000, 0xffffffff00000000, 0xffffffff7fc00000, 16
    check fnmsub.s, 0xffffffff7f800000, 0xffffffff3f800000, 0xffffffff7f800000, 0xffffffff7fc00000, 16

    # Overflow/inexact and underflow/inexact on a negative product.
    check fnmadd.d, 0x7fefffffffffffff, 0x4000000000000000, 0, 0xfff0000000000000, 5
    check fnmadd.d, 0x7fefffffffffffff, 0x4000000000000000, 0, 0xffefffffffffffff, 5, rtz
    check fnmadd.s, 0xffffffff7f7fffff, 0xffffffff40000000, 0xffffffff00000000, 0xffffffffff800000, 5
    check fnmadd.s, 0xffffffff7f7fffff, 0xffffffff40000000, 0xffffffff00000000, 0xffffffffff7fffff, 5, rtz
    check fnmsub.d, 1, 0x3fe0000000000000, 0, 0x8000000000000000, 3
    check fnmsub.s, 0xffffffff00000001, 0xffffffff3f000000, 0xffffffff00000000, 0xffffffff80000000, 3

    li t1, 0
    j exit
fail:
    li t1, 1
exit:
    li t0, 0x20000100
    sb t1, 0(t0)
halt:
    j halt
