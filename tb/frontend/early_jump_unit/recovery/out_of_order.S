/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
.option norvc
.option norelax
.section .text
.global _start, older_branch, younger_return, wrong_path, correct_path, call, callee, resume
_start:
    li ra, 0x1180
    li a1, 1
    slli a1, a1, 63
    addi a1, a1, 1
    li a2, 1
    divu a0, a1, a2
older_branch:
    beq a0, a1, correct_path
younger_return:
    ret
    wfi
    .fill (0x100 - (. - _start)) / 4, 4, 0x00000013
correct_path:
    bne zero, zero, wrong_path
call:
    jal ra, callee
resume:
    addi t1, zero, 7
    wfi
    .fill (0x140 - (. - _start)) / 4, 4, 0x00000013
callee:
    ret
    .fill (0x180 - (. - _start)) / 4, 4, 0x00000013
wrong_path:
    wfi
    .fill (0x400 - (. - _start)) / 4, 4, 0x00000013
    nop
