/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
.option norvc
.option norelax
.section .text
.global _start, faulting_ret, trap
_start:
    li t0, 0x1200
    csrw mtvec, t0
    li ra, 0x1102
faulting_ret:
    ret
    wfi
    .fill (0x200 - (. - _start)) / 4, 4, 0x00000013
trap:
    addi t1, zero, 7
    wfi
    .fill (0x400 - (. - _start)) / 4, 4, 0x00000013
    nop
