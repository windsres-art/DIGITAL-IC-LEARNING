# CLINT 中断的自检查程序（向量模式 mtvec）
#   1 软件中断：写 msip = 1 立即进入 MSI，处理程序清 msip
#   2 周期定时器中断 + 计算循环：同一个循环先关中断跑一遍、再开着每 PERIOD 个 mtime 被打断一次跑一遍，
#     结果必须相同（中断对被打断的程序透明），并且确实被打断了足够多次
#   3 wfi：MIE = 0 时 wfi 也会被"待处理且被 mie 允许"的中断唤醒，但不进入处理程序；
#     之后打开 MIE，中断立即被响应
#   4 优先级：MSI 与 MTI 同时待处理，先响应 MSI
    .equ MSIP,      0x02000000
    .equ MTIMECMP,  0x02004000
    .equ MTIMECMPH, 0x02004004
    .equ MTIME,     0x0200bff8
    .equ PERIOD,    150
    .equ N,         600

    .text
_start:
    j    main
# 向量表：异常进 vtable，中断 n 进 vtable + 4n
vtable:
    j    bad                        # 0：异常（本程序不应有）
    j    bad
    j    bad
    j    msi_handler                # 3：机器软件中断
    j    bad
    j    bad
    j    bad
    j    mti_handler                # 7：机器定时器中断
    j    bad
    j    bad
    j    bad
    j    bad                        # 11：外部中断（本程序不用）

main:
    la   sp, stack_top
    la   t0, vtable
    ori  t0, t0, 1
    csrw mtvec, t0
    li   t0, MTIMECMPH
    sw   zero, 0(t0)                # mtimecmp 高 32 位 = 0（仿真里 mtime 不会超过 2^32）
    li   t0, MTIMECMP
    li   t1, -1
    sw   t1, 0(t0)

    # ---------- 1 软件中断 ----------
    li   s8, 1
    li   t0, 8
    csrs mie, t0                    # MSIE
    csrsi mstatus, 8                # MIE
    li   t0, MSIP
    li   t1, 1
    sw   t1, 0(t0)
    li   t2, 100
wait_msi:
    la   t0, msi_cnt
    lw   t1, 0(t0)
    bnez t1, got_msi
    addi t2, t2, -1
    bnez t2, wait_msi
    j    fail
got_msi:
    li   t2, 1
    bne  t1, t2, fail
    csrci mstatus, 8
    csrw mie, zero

    # ---------- 2 周期中断下的计算 ----------
    li   s8, 2
    call compute                    # 关中断：参考结果
    mv   s2, a0
    la   t0, tmode
    li   t1, 1
    sw   t1, 0(t0)                  # 周期模式
    call arm_timer
    li   t0, 0x80
    csrs mie, t0                    # MTIE
    csrsi mstatus, 8
    call compute                    # 开中断再算一遍
    csrci mstatus, 8
    csrw mie, zero
    bne  a0, s2, fail
    la   t0, ticks
    lw   s3, 0(t0)
    li   t1, 20
    blt  s3, t1, fail               # 至少被打断 20 次

    # ---------- 3 wfi，MIE = 0 ----------
    li   s8, 3
    la   t0, tmode
    sw   zero, 0(t0)                # 单次模式：处理程序把 mtimecmp 设成"永不"
    li   t0, 0x80
    csrs mie, t0
    call arm_timer
    wfi                             # MIE = 0：被唤醒，但不进处理程序
    csrr t1, mip
    andi t1, t1, 0x80
    beqz t1, fail                   # 醒来时 MTIP 确实待处理
    la   t0, ticks
    lw   t1, 0(t0)
    bne  t1, s3, fail               # 没有进处理程序
    csrsi mstatus, 8                # 打开 MIE：立即响应
    nop
    nop
    lw   t1, 0(t0)
    addi t2, s3, 1
    bne  t1, t2, fail
    csrci mstatus, 8

    # ---------- 4 同时待处理：MSI 先于 MTI ----------
    li   s8, 4
    la   t0, order_n
    sw   zero, 0(t0)
    li   t0, MSIP
    li   t1, 1
    sw   t1, 0(t0)
    li   t0, MTIMECMP
    sw   zero, 0(t0)                # mtimecmp = 0：MTIP 立即为 1
    li   t0, 0x88
    csrs mie, t0
    csrsi mstatus, 8
    nop
    nop
    nop
    nop
    csrci mstatus, 8
    la   t0, order_n
    lw   t1, 0(t0)
    li   t2, 2
    bne  t1, t2, fail
    la   t0, order
    lw   t1, 0(t0)
    li   t2, 3
    bne  t1, t2, fail
    lw   t1, 4(t0)
    li   t2, 7
    bne  t1, t2, fail

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

# ---------------- 子程序 ----------------
# a0 = 计算结果。循环里有 load-use、store、分支，被中断打断的位置是随机的
compute:
    la   t0, arr
    li   t1, 64
clr:
    sw   zero, 0(t0)
    addi t0, t0, 4
    addi t1, t1, -1
    bnez t1, clr
    li   a0, 0
    li   t4, 0
    li   t5, N
    la   t6, arr
cloop:
    andi t0, t4, 63
    slli t0, t0, 2
    add  t0, t0, t6
    lw   t1, 0(t0)
    add  t1, t1, t4                 # load-use
    sw   t1, 0(t0)
    xor  a0, a0, t1
    slli t2, a0, 1
    srli t3, a0, 31
    or   a0, t2, t3                 # 循环左移 1 位
    andi t2, t4, 7
    bnez t2, cskip
    addi a0, a0, 13
cskip:
    addi t4, t4, 1
    blt  t4, t5, cloop
    ret

# mtimecmp = mtime + PERIOD
arm_timer:
    li   t0, MTIME
    lw   t1, 0(t0)
    addi t1, t1, PERIOD
    li   t0, MTIMECMP
    sw   t1, 0(t0)
    ret

# 记录中断顺序：order[order_n++] = mcause & 0xf
record:
    csrr t0, mcause
    andi t0, t0, 0xf
    la   t1, order_n
    lw   t2, 0(t1)
    li   t3, 255
    bgeu t2, t3, rec_full           # 最多记 255 个
    slli t3, t2, 2
    la   t4, order
    add  t3, t3, t4
    sw   t0, 0(t3)
    addi t2, t2, 1
    sw   t2, 0(t1)
rec_full:
    ret

# ---------------- 中断处理程序 ----------------
# 保存全部用到的寄存器（包括 ra：record 是用 call 调用的）
msi_handler:
    addi sp, sp, -24
    sw   ra, 0(sp)
    sw   t0, 4(sp)
    sw   t1, 8(sp)
    sw   t2, 12(sp)
    sw   t3, 16(sp)
    sw   t4, 20(sp)
    csrr t0, mcause
    li   t1, 0x80000003
    bne  t0, t1, bad
    li   t0, MSIP
    sw   zero, 0(t0)
    la   t0, msi_cnt
    lw   t1, 0(t0)
    addi t1, t1, 1
    sw   t1, 0(t0)
    call record
    j    irq_ret

mti_handler:
    addi sp, sp, -24
    sw   ra, 0(sp)
    sw   t0, 4(sp)
    sw   t1, 8(sp)
    sw   t2, 12(sp)
    sw   t3, 16(sp)
    sw   t4, 20(sp)
    csrr t0, mcause
    li   t1, 0x80000007
    bne  t0, t1, bad
    la   t0, ticks
    lw   t1, 0(t0)
    addi t1, t1, 1
    sw   t1, 0(t0)
    la   t0, tmode
    lw   t1, 0(t0)
    li   t0, MTIMECMP
    beqz t1, mti_once
    lw   t1, 0(t0)                  # 周期：mtimecmp += PERIOD（不随处理延迟漂移）
    addi t1, t1, PERIOD
    sw   t1, 0(t0)
    j    mti_done
mti_once:
    li   t1, -1
    sw   t1, 0(t0)
mti_done:
    call record
irq_ret:
    lw   ra, 0(sp)
    lw   t0, 4(sp)
    lw   t1, 8(sp)
    lw   t2, 12(sp)
    lw   t3, 16(sp)
    lw   t4, 20(sp)
    addi sp, sp, 24
    mret

    .data
tohost:  .word 0
msi_cnt: .word 0
ticks:   .word 0
tmode:   .word 0
order_n: .word 0
order:   .space 1024
arr:     .space 256
stack:   .space 512
stack_top:
