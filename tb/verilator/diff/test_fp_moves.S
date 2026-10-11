# Directed RV64F/D move regression for the bare differential testbench.
# Build with:
# riscv64-unknown-elf-gcc -march=rv64imfd_zicsr -mabi=lp64d -nostdlib \
#   -Wl,-Ttext=0x10180 -Wl,--no-relax test_fp_moves.S -o moves.elf
# riscv64-unknown-elf-objcopy -O verilog moves.elf moves.hex
# Run moves.hex through the sim-diff target; expected program exit code is 0.
.option norvc
.section .text
.globl _start
_start:
    li t0, 0x6000
    csrs mstatus, t0
    li s4, 0x60                  # FRM=RUP, initially no exception flags

restart:
    csrw fcsr, s4
    la s0, patterns
    la s1, patterns_end

next_pattern:
    ld t2, 0(s0)

    # Copy all 64 bits, including NaN payloads and signed zero, via writable f0.
    fmv.d.x f0, t2
    fmv.x.d t3, f0
    bne t2, t3, fail

    # FMV.X.W ignores upper-bit boxing and sign-extends bit 31 to XLEN.
    sext.w t4, t2
    fmv.x.w t3, f0
    bne t3, t4, fail

    # FMV.W.X copies only the low word and NaN-boxes it in the FP register.
    fmv.w.x f1, t2
    fmv.x.w t3, f1
    bne t3, t4, fail
    slli t4, t2, 32
    srli t4, t4, 32
    li t5, -1
    slli t5, t5, 32
    or t4, t4, t5
    fmv.x.d t3, f1
    bne t3, t4, fail

    # Integer x0 destinations discard results without affecting FP state.
    fmv.x.w zero, f0
    fmv.x.d zero, f0
    csrr t3, fcsr
    bne t3, s4, fail

    addi s0, s0, 8
    bne s0, s1, next_pattern
    li t0, 0x60
    bne s4, t0, conversions
    addi s4, s4, 5               # Repeat with pre-existing NX and OF flags
    j restart

conversions:
    # The distinct move controls must leave genuine numeric conversions intact.
    li t2, 25
    fcvt.d.l f2, t2, rne
    fmv.x.d t3, f2
    li t4, 0x4039000000000000
    bne t3, t4, fail
    fcvt.l.d t3, f2, rtz
    bne t3, t2, fail
    li t2, 0x3ff4000000000000     # Raw bits of double 1.25
    fmv.d.x f2, t2
    fcvt.l.d t3, f2, rne
    li t4, 1                    # Static RNE overrides the current FRM=RUP
    bne t3, t4, fail
    fmv.x.d t3, f2
    bne t3, t2, fail

    li t1, 0
    j exit
fail:
    li t1, 1
exit:
    li t0, 0x20000100
    sb t1, 0(t0)
halt:
    j halt

.balign 8
patterns:
    .quad 0x0000000000000000     # Positive zero
    .quad 0x8000000000000000     # Negative zero
    .quad 0x000000000000002a     # Integer 42 / double subnormal
    .quad 0x3ff8000000000000     # Double 1.5
    .quad 0x7ff0000000000000     # Positive infinity
    .quad 0xfff0000000000000     # Negative infinity
    .quad 0x7ff8000012345678     # Quiet NaN with payload
    .quad 0x7ff0000080000001     # Signalling NaN / negative low word
    .quad 0xffffffff3fc00000     # Boxed single 1.5
    .quad 0xffffffff80000000     # Boxed single negative zero
    .quad 0x000000007f812345     # Unboxed single signalling NaN
    .quad 0xffffffff7fc12345     # Boxed single quiet NaN with payload
    .quad 0x0123456789abcdef     # Arbitrary bits and negative low word
    .quad 0xffffffffffffffff
patterns_end:
