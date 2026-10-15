/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Full-core EQ08 witness. No synthetic branch/exception/confirmation signals.
 */
.option norvc
.option norelax
.section .text
.global _start, older_call, divide, fault, younger_call, younger_target, trap, survivor
_start:
    li t0, 0x1200
    csrw mtvec, t0
older_call:
    jal ra, setup
survivor:
    j survivor
.fill (0x40 - (. - _start)) / 4, 4, 0x00000013
setup:
    li a1, 1
    slli a1, a1, 63
    addi a1, a1, 1
    li a2, 1
divide:
    divu a0, a1, a2
fault:
    ld ra, 0(a0)
younger_call:
    jal ra, younger_target
.fill (0x180 - (. - _start)) / 4, 4, 0x00000013
younger_target:
    wfi
.fill (0x200 - (. - _start)) / 4, 4, 0x00000013
trap:
    ret
.fill (0x400 - (. - _start)) / 4, 4, 0x00000013
    nop
