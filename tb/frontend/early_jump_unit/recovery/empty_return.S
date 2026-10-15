/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 * Empty-RAS fallback control: no recognized call before the canonical return.
 */
.option norvc
.option norelax
.section .text
.global _start, empty_ret, destination
_start:
    li ra, 0x1100
empty_ret:
    ret
.fill (0x100 - (. - _start)) / 4, 4, 0x00000013
destination:
    addi t1, zero, 7
    wfi
.fill (0x400 - (. - _start)) / 4, 4, 0x00000013
    nop
