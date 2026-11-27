/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
.option norvc
.option norelax
.section .text
.global _start, jump, waiting_operand, ready_operand, destination
_start:
    li a1, 1
    slli a1, a1, 63
    addi a1, a1, 1
    li a2, 1
    la t0, destination
    divu a0, a1, a2
jump:
    jalr t0, 0(t0)
waiting_operand:
    addi s1, t0, 1
    .rept 4
    nop
    .endr
ready_operand:
    addi s2, t0, 2
    wfi
    .fill (0x100 - (. - _start)) / 4, 4, 0x00000013
destination:
    addi s3, t0, 3
    wfi
    .fill (0x400 - (. - _start)) / 4, 4, 0x00000013
    nop
