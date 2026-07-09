.option norvc
.section .text
.globl _start

_start:
    la t0, trap_handler
    csrw mtvec, t0

    li s0, 1
    li s1, 3
    la s2, ebreak_test
    la s3, ebreak_test
ebreak_test:
    ebreak

    li s0, 2
    li s1, 2
    la s2, illegal_test
    li s3, 0
illegal_test:
    .word 0

    li s0, 3
    li s1, 2
    la s2, readonly_csr_test
    li s3, 0xc0001073
readonly_csr_test:
    csrrw x0, cycle, x0

    li s0, 4
    li s1, 0
    la s2, inst_misaligned_test
    la s3, aligned_target + 2
    la t0, aligned_target + 2
inst_misaligned_test:
    jalr x0, 0(t0)

    li s0, 5
    li s1, 4
    la s2, load_misaligned_test
    la s3, data_area + 1
load_misaligned_test:
    lw t1, 0(s3)

    li s0, 6
    li s1, 6
    la s2, store_misaligned_test
    la s3, data_area + 2
store_misaligned_test:
    sw t1, 0(s3)

pass:
    li gp, 1
    j write_tohost

fail:
    slli gp, s0, 1
    ori gp, gp, 1

write_tohost:
    la t0, tohost
    sw gp, 0(t0)
1:
    j 1b

trap_handler:
    csrr t0, mcause
    bne t0, s1, fail
    csrr t0, mepc
    bne t0, s2, fail
    csrr t0, mtval
    bne t0, s3, fail
    addi t0, s2, 4
    csrw mepc, t0
    mret

    .align 2
aligned_target:
    .word 0

    .align 3
data_area:
    .dword 0x0011223344556677

    .align 3
tohost:
    .dword 0
