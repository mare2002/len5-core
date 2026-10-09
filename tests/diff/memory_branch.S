.option norvc
.section .text
.globl _start
_start:
    la s0, data
    li t0, -128
    sd t0, 0(s0)
    lb t1, 0(s0)
    lbu t2, 0(s0)
    ld t3, 0(s0)
    ld t4, 0(s0)
    add t5, t1, t3
    li t6, 128
    bne t2, t6, fail
    li t0, 8
    li s1, 0
loop:
    addi s1, s1, 1
    addi t0, t0, -1
    bnez t0, loop
    jal ra, function
    li t1, 8
    bne s1, t1, fail
    li a0, 0x20000100
    sb zero, 0(a0)
done: j done
function:
    mul a1, s1, s1
    div a2, a1, s1
    beq a2, s1, return
    sd zero, 0(s0)  # wrong path; must not write memory
return:
    ret
fail:
    li a0, 0x20000100
    li a1, 1
    sb a1, 0(a0)
    j done
    .rept 32
    nop
    .endr
.section .data
.balign 8
data:
    .dword 0
