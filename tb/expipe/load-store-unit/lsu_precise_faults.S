/* Copyright 2026 Politecnico di Torino. SPDX-License-Identifier: SHL-2.0 */
/* Self-checking trap test: younger register/memory effects must be absent in
 * the handler, then execute normally when the faulting instruction is skipped. */
.section .text
.globl _start
_start:
    li s0, 0x50000
    sd zero, 0(s0)
    la t0, trap
    csrw mtvec, t0
    li s1, 0
    li s7, 0x123
    li s8, 0x789

    li s2, 7                       /* store access fault */
    li t1, 0xdead0000
    mv s3, t1
    la s4, store_access
    mv a0, s7
    mv a1, s8
store_access:
    sd s7, 0(t1)
    li a0, 0x456
    sd s7, 0(s0)
    li t0, 1
    bne s1, t0, fail
    ld t0, 0(s0)
    bne t0, s7, fail
    sd zero, 0(s0)

    li s2, 5                       /* load access fault */
    la s4, load_access
    mv a0, s7
    mv a1, s8
load_access:
    ld a1, 0(t1)
    li a0, 0x456
    sd s7, 0(s0)
    li t0, 2
    bne s1, t0, fail
    ld t0, 0(s0)
    bne t0, s7, fail
    sd zero, 0(s0)

    li s2, 6                       /* store address misaligned */
    addi t1, s0, 1
    mv s3, t1
    la s4, store_alignment
    mv a0, s7
    mv a1, s8
store_alignment:
    sh s7, 0(t1)
    lbu a1, 0(t1)
    li a0, 0x456
    sd s7, 0(s0)
    li t0, 3
    bne s1, t0, fail
    sd zero, 0(s0)

    li s2, 4                       /* load address misaligned */
    la s4, load_alignment
    mv a0, s7
    mv a1, s8
load_alignment:
    lw a1, 0(t1)
    li a0, 0x456
    sd s7, 0(s0)
    li t0, 4
    bne s1, t0, fail
    li t0, 0x456
    bne a0, t0, fail
    li t0, 0x20000100
    sd zero, 0(t0)
1:  j 1b

.balign 4
trap:
    csrr t3, mcause
    bne t3, s2, fail
    csrr t3, mtval
    bne t3, s3, fail
    csrr t3, mepc
    bne t3, s4, fail
    bne a0, s7, fail
    bne a1, s8, fail
    ld t4, 0(s0)
    bnez t4, fail
    addi s1, s1, 1
    addi t3, t3, 4
    csrw mepc, t3
    mret
fail:
    addi t3, s1, 1
    li t4, 0x20000100
    sd t3, 0(t4)
2:  j 2b
