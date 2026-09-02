.section .text.init
.global _start

_start:
    # Keep the load away from the ROB head long enough to make its consumer
    # wait in the ALU issue queue.
    li      t0, 100
    li      t1, 3
    div     t2, t0, t1

    la      t3, test_data
    ld      t4, 0(t3)

    # This older ADD waits for the load result.  The younger XOR is independent
    # and should therefore complete first.
    add     t5, t4, t0
    xor     t6, t0, t1

    # Finish the simulator by writing 1 to the debug device.
    li      a0, 1
    li      a1, 0x40000000
    sd      a0, 0(a1)

1:
    j       1b

.section .data
.align 3
test_data:
    .dword  0x1122334455667788
