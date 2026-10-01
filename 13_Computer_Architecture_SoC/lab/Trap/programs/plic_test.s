# PLIC 外部中断的自检查程序（直接模式 mtvec，处理程序里按 mcause 分发）
#   源的优先级：1→1  2→2  3→2  4→7  5→3  6→0（永不）  7→5
#   1 七个源同时拉高：claim 的顺序必须是 4 7 5 2 3 1（同优先级取小号），源 6 不被 claim 但 pending
#   2 门限 threshold = 4：优先级 3 和 2 的源不能打断；门限降到 0 后依次响应 5、2
#   3 没有待处理时读 claim 返回 0
#   4 wfi 等一个 80 周期后才到来的外部中断
#   5 外部中断与定时器中断同时待处理：先 MEI 后 MTI
#   处理程序：claim → 记录源号 → 通知设备撤销电平 → complete
    .equ PLIC,      0x0c000000
    .equ PENDING,   0x0c001000
    .equ ENABLE,    0x0c002000
    .equ THRESHOLD, 0x0c200000
    .equ CLAIM,     0x0c200004
    .equ DEV_RAISE, 0x30000000
    .equ DEV_CLEAR, 0x30000004
    .equ MTIMECMP,  0x02004000
    .equ MTIMECMPH, 0x02004004

    .text
_start:
    la   sp, stack_top
    la   t0, handler
    csrw mtvec, t0
    li   t0, MTIMECMPH
    sw   zero, 0(t0)
    li   t0, MTIMECMP
    li   t1, -1
    sw   t1, 0(t0)
    # 优先级
    li   t0, PLIC
    li   t1, 1
    sw   t1, 4(t0)
    li   t1, 2
    sw   t1, 8(t0)
    sw   t1, 12(t0)
    li   t1, 7
    sw   t1, 16(t0)
    li   t1, 3
    sw   t1, 20(t0)
    sw   zero, 24(t0)
    li   t1, 5
    sw   t1, 28(t0)
    li   t0, ENABLE
    li   t1, 0xfe
    sw   t1, 0(t0)
    li   t0, THRESHOLD
    sw   zero, 0(t0)
    li   t0, 0x800
    csrs mie, t0                    # MEIE

    # ---------- 1 claim 顺序 ----------
    li   s8, 1
    li   t0, DEV_RAISE
    li   t1, 0xfe                   # 延迟 0，源 1–7 全部拉高
    sw   t1, 0(t0)
    nop
    nop
    li   t0, PENDING
    lw   t1, 0(t0)
    li   t2, 0xfe
    bne  t1, t2, fail               # 网关已把 7 个源都置为 pending
    csrsi mstatus, 8
    li   t2, 50
wait1:
    la   t0, order_n
    lw   t1, 0(t0)
    li   t3, 6
    beq  t1, t3, got1
    addi t2, t2, -1
    bnez t2, wait1
    j    fail
got1:
    csrci mstatus, 8
    la   a0, exp1
    li   a1, 6
    call check_order
    li   t0, PENDING
    lw   t1, 0(t0)
    li   t2, 0x40
    bne  t1, t2, fail               # 只剩源 6（优先级 0）
    li   t0, DEV_CLEAR
    li   t1, 0x40
    sw   t1, 0(t0)

    # ---------- 2 门限 ----------
    li   s8, 2
    la   t0, order_n
    sw   zero, 0(t0)
    li   t0, THRESHOLD
    li   t1, 4
    sw   t1, 0(t0)
    li   t0, DEV_RAISE
    li   t1, 0x24                   # 源 5（优先级 3）和源 2（优先级 2）
    sw   t1, 0(t0)
    csrsi mstatus, 8
    li   t2, 40
spin2:
    addi t2, t2, -1
    bnez t2, spin2
    la   t0, order_n
    lw   t1, 0(t0)
    bnez t1, fail                   # 都不超过门限，不能打断
    csrr t1, mip
    srli t1, t1, 11                 # andi 的立即数是有符号 12 bit，放不下 0x800
    andi t1, t1, 1
    bnez t1, fail                   # MEIP 也不应为 1
    li   t0, THRESHOLD
    sw   zero, 0(t0)                # 降低门限：立即响应
    nop
    nop
    nop
    nop
    csrci mstatus, 8
    la   a0, exp2
    li   a1, 2
    call check_order

    # ---------- 3 空 claim ----------
    li   s8, 3
    li   t0, CLAIM
    lw   t1, 0(t0)
    bnez t1, fail

    # ---------- 4 wfi 等外部中断 ----------
    li   s8, 4
    la   t0, order_n
    sw   zero, 0(t0)
    li   t0, DEV_RAISE
    li   t1, 0x00500008             # 80 周期后拉高源 3
    sw   t1, 0(t0)
    csrsi mstatus, 8
    wfi
    nop
    csrci mstatus, 8
    la   a0, exp4
    li   a1, 1
    call check_order

    # ---------- 5 MEI 先于 MTI ----------
    li   s8, 5
    la   t0, order_n
    sw   zero, 0(t0)
    la   t0, ntimer
    sw   zero, 0(t0)
    la   t0, first_kind
    sw   zero, 0(t0)
    li   t0, DEV_RAISE
    li   t1, 0x02                   # 源 1
    sw   t1, 0(t0)
    li   t0, MTIMECMP
    sw   zero, 0(t0)                # 定时器中断立即待处理
    li   t0, 0x880
    csrs mie, t0
    nop
    nop
    csrsi mstatus, 8
    nop
    nop
    nop
    nop
    csrci mstatus, 8
    la   t0, ntimer
    lw   t1, 0(t0)
    li   t2, 1
    bne  t1, t2, fail
    la   t0, first_kind
    lw   t1, 0(t0)
    li   t2, 11
    bne  t1, t2, fail               # 第一个响应的是外部中断

pass:
    li   t1, 1
    la   t0, tohost
    sw   t1, 0(t0)
pass_spin:
    j    pass_spin
bad:
    li   s8, 99
fail:
    slli t1, s8, 1
    ori  t1, t1, 1
    la   t0, tohost
    sw   t1, 0(t0)
fail_spin:
    j    fail_spin

# order[0..a1-1] 必须等于 a0 指向的表，并且 order_n == a1
check_order:
    la   t0, order_n
    lw   t1, 0(t0)
    bne  t1, a1, fail
    la   t0, order
co_loop:
    beqz a1, co_done
    lw   t1, 0(t0)
    lw   t2, 0(a0)
    bne  t1, t2, fail
    addi t0, t0, 4
    addi a0, a0, 4
    addi a1, a1, -1
    j    co_loop
co_done:
    ret

# ---------------- trap 处理程序 ----------------
handler:
    addi sp, sp, -16
    sw   t0, 0(sp)
    sw   t1, 4(sp)
    sw   t2, 8(sp)
    sw   t3, 12(sp)
    csrr t0, mcause
    bgez t0, bad                    # 本程序不应有异常
    andi t0, t0, 0xf
    la   t1, first_kind
    lw   t2, 0(t1)
    bnez t2, h_kind_done
    sw   t0, 0(t1)                  # 记下第一个中断的种类
h_kind_done:
    li   t1, 7
    beq  t0, t1, h_timer
    li   t1, 11
    bne  t0, t1, bad
    # 外部中断：claim
    li   t0, CLAIM
    lw   t1, 0(t0)
    beqz t1, h_ret                  # 已经被别人 claim 了（不会发生，但规范要求能处理）
    la   t2, order_n
    lw   t3, 0(t2)
    addi t3, t3, 1
    sw   t3, 0(t2)
    slli t3, t3, 2
    la   t2, order - 4
    add  t2, t2, t3
    sw   t1, 0(t2)                  # order[n] = 源号
    li   t2, 1
    sll  t2, t2, t1
    li   t3, DEV_CLEAR
    sw   t2, 0(t3)                  # 先让设备撤销电平……
    sw   t1, 0(t0)                  # ……再 complete，否则网关会立即再次置 pending
    j    h_ret
h_timer:
    li   t0, MTIMECMP
    li   t1, -1
    sw   t1, 0(t0)
    la   t0, ntimer
    lw   t1, 0(t0)
    addi t1, t1, 1
    sw   t1, 0(t0)
h_ret:
    lw   t0, 0(sp)
    lw   t1, 4(sp)
    lw   t2, 8(sp)
    lw   t3, 12(sp)
    addi sp, sp, 16
    mret

    .data
tohost:     .word 0
order_n:    .word 0
ntimer:     .word 0
first_kind: .word 0
exp1:       .word 4, 7, 5, 2, 3, 1
exp2:       .word 5, 2
exp4:       .word 3
order:      .space 64
stack:      .space 256
stack_top:
