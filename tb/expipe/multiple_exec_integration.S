/* SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1 */
/* Short full-core workload checked instruction-by-instruction by Spike. */
.option norvc
.option norelax
.section .text
.globl _start
_start:
  li s0, 0x50000
  li s1, 0x20000100
  li t0, 0x6000
  csrs mstatus, t0
  csrw fcsr, zero

  li a0, 3
  li a1, 5
  li a2, 7
  li a3, 11
  mul t3, a0, a1
  mul t4, a2, a3
  mul t5, a1, a2
  mul t6, a0, a3
  add a4, t3, t4
  add a5, t5, t6
  add a4, a4, a5
  li a5, 160
  bne a4, a5, fail
  sd a4, 0(s0)
  ld a5, 0(s0)
  bne a4, a5, fail

  li a0, 0x100000001
  li a1, 1
  divu a2, a0, a1
  divuw a3, a0, a1
  bne a2, a0, fail
  bne a3, a1, fail
  li a0, -33
  li a1, 7
  div a2, a0, a1
  rem a3, a0, a1
  divw a4, a0, a1
  li a5, -4
  bne a2, a5, fail
  bne a4, a5, fail
  li a5, -5
  bne a3, a5, fail

  li a0, 3
  li a1, 5
  fcvt.s.w f0, a0
  fcvt.s.w f1, a1
  fadd.s f2, f0, f1
  fmul.s f3, f0, f1
  fmadd.s f4, f0, f1, f2
  fadd.s f5, f0, f0
  fadd.s f6, f1, f1
  fmadd.s f7, f5, f6, f4
  fcvt.w.s a0, f7, rtz
  li a1, 83
  bne a0, a1, fail
#if defined(LEN5_FP32_ONLY) || defined(LEN5_REPRO_FLW_BOXING)
  fsw f7, 8(s0)
  flw f9, 8(s0)
#else
  fsd f7, 8(s0)
  fld f9, 8(s0)
#endif
  fcvt.w.s a0, f9, rtz
  bne a0, a1, fail

  li t0, 0x3fc00000
  fmv.w.x f8, t0
  li t0, 1
  csrw frm, t0
  fcvt.w.s a1, f8, dyn
  fcvt.w.s a2, f8, rup
  li a3, 1
  bne a1, a3, fail
  li a3, 2
  bne a2, a3, fail
  csrr t0, fflags
  andi t0, t0, 1
  beqz t0, fail
  csrw fflags, zero

#ifndef LEN5_FP32_ONLY
  li a0, 3
  fcvt.d.w f10, a0
  fadd.d f11, f10, f10
  fdiv.d f12, f11, f10
  fsd f12, 16(s0)
  fld f13, 16(s0)
  fcvt.w.d a0, f13, rtz
  li a1, 2
  bne a0, a1, fail
#endif

  li t0, 4
  li t1, 0
loop:
  add t1, t1, t0
  addi t0, t0, -1
  bnez t0, loop
  li t2, 10
  bne t1, t2, fail

.globl success
success:
  sd zero, 0(s1)
  j success
.globl fail
fail:
  li a0, 1
  sd a0, 0(s1)
  j fail
  .rept 32
  nop
  .endr
