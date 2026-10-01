# 同步异常与 CSR 语义的自检查程序
#   trap 处理程序把 mcause / mtval 记到 s10 / s11、次数加到 s9，把 mepc 加 4 跳过出错指令后 mret。
#   每个测试：s8 = 测试号；执行一条会出异常的指令；检查 s9 / s10 / s11，以及出错指令没有副作用。
#   失败时 tohost = (测试号 << 1) | 1
    .equ BAD,  0x50000000          # 没有映射的地址：访问错误

    .text
_start:
    la   t0, handler
    csrw mtvec, t0
    li   s9, 0

    # ---------- 1 CSR 读写 ----------
    li   s8, 1
    li   t1, 0x12345678
    csrw mscratch, t1
    csrr t2, mscratch
    bne  t2, t1, fail
    csrrsi t3, mscratch, 5          # 旧值 0x12345678，新值 | 5
    bne  t3, t1, fail
    csrrci t3, mscratch, 0x1c       # 旧值 0x1234567d，新值 & ~0x1c
    li   t4, 0x1234567d
    bne  t3, t4, fail
    csrrw t5, mscratch, zero
    li   t4, 0x12345661
    bne  t5, t4, fail
    csrr t5, mscratch
    bnez t5, fail

    # ---------- 2 只读 / WARL 字段 ----------
    li   s8, 2
    csrr t1, misa
    li   t2, 0x40000100
    bne  t1, t2, fail
    csrr t1, mhartid
    bnez t1, fail
    li   t1, -1
    csrw mie, t1                    # 只有 MSIE / MTIE / MEIE 三位可写
    csrr t2, mie
    li   t3, 0x888
    bne  t2, t3, fail
    csrw mie, zero
    csrw mstatus, t1                # 只有 MIE / MPIE 可写，MPP 恒为 11
    csrr t2, mstatus
    li   t3, 0x1888
    bne  t2, t3, fail
    csrw mstatus, zero
    csrr t2, mstatus
    li   t3, 0x1800
    bne  t2, t3, fail
    csrw mepc, t1                   # mepc 低 2 位恒为 0
    csrr t2, mepc
    li   t3, -4
    bne  t2, t3, fail
    csrw mtvec, t1                  # mtvec bit 1 恒为 0
    csrr t2, mtvec
    li   t3, -3
    bne  t2, t3, fail
    la   t0, handler
    csrw mtvec, t0

    # ---------- 3 minstret / mcycle ----------
    li   s8, 3
    csrr t1, minstret
    nop
    nop
    nop
    csrr t2, minstret
    sub  t2, t2, t1
    li   t3, 4                      # 读出的是"本条之前退休了多少条"：csrr + 3 个 nop
    bne  t2, t3, fail
    csrr t1, mcycle
    csrr t2, mcycle
    bgeu t1, t2, fail               # 周期计数单调增

    # ---------- 4 ecall ----------
    li   s8, 4
    ecall
    li   t1, 1
    bne  s9, t1, fail
    li   t1, 11
    bne  s10, t1, fail
    bnez s11, fail

    # ---------- 5 ebreak：mtval = 它自己的 PC ----------
    li   s8, 5
brk:
    ebreak
    li   t1, 3
    bne  s10, t1, fail
    la   t1, brk
    bne  s11, t1, fail

    # ---------- 6 非法指令：mtval = 指令本身 ----------
    li   s8, 6
    .word 0xffffffff
    li   t1, 2
    bne  s10, t1, fail
    li   t1, -1
    bne  s11, t1, fail
    .word 0x00000000                # 全 0 也是非法指令
    li   t1, 2
    bne  s10, t1, fail
    bnez s11, fail
    li   t5, 99
    csrr t5, 0x7c0                  # 不存在的 CSR：非法，rd 不能被写
    li   t1, 2
    bne  s10, t1, fail
    li   t1, 99
    bne  t5, t1, fail
    csrw mhartid, t5                # 写只读 CSR：非法
    li   t1, 2
    bne  s10, t1, fail
    li   t1, 6
    bne  s9, t1, fail               # ecall 1 + ebreak 1 + 非法指令 4 = 6 次

    # ---------- 7 非对齐访存：mtval = 地址 ----------
    li   s8, 7
    la   a0, buf
    li   t5, 99
    lw   t5, 2(a0)
    li   t1, 4
    bne  s10, t1, fail
    addi t1, a0, 2
    bne  s11, t1, fail
    li   t1, 99
    bne  t5, t1, fail               # 出错的 load 不写 rd
    lh   t5, 1(a0)
    li   t1, 4
    bne  s10, t1, fail
    li   t2, 0x55
    sw   t2, 1(a0)                  # store 非对齐
    li   t1, 6
    bne  s10, t1, fail
    lw   t3, 0(a0)
    bnez t3, fail                   # 出错的 store 不写内存

    # ---------- 8 访问错误：没有映射的地址 ----------
    li   s8, 8
    li   a1, BAD
    li   t5, 99
    lw   t5, 0(a1)
    li   t1, 5
    bne  s10, t1, fail
    bne  s11, a1, fail
    li   t1, 99
    bne  t5, t1, fail
    sw   t5, 4(a1)
    li   t1, 7
    bne  s10, t1, fail
    addi t1, a1, 4
    bne  s11, t1, fail

    # ---------- 9 跳转目标非对齐：异常记在跳转指令上，rd 不写 ----------
    li   s8, 9
    la   t1, jtgt
    addi t1, t1, 2
    li   ra, 77
    jalr ra, 0(t1)
    li   t2, 0
    bne  s10, t2, fail
    bne  s11, t1, fail
    li   t2, 77
    bne  ra, t2, fail
    beq  zero, zero, jtgt + 2       # 跳的分支，目标非对齐
    bnez s10, fail
    la   t1, jtgt
    addi t1, t1, 2
    bne  s11, t1, fail
    li   s10, 99
    bne  zero, zero, jtgt + 2       # 不跳的分支：目标非对齐也没关系
    li   t1, 99
    bne  s10, t1, fail
    j    after_j
jtgt:
    nop
    nop
after_j:

    # ---------- 10 向量模式下，异常仍然进 BASE ----------
    li   s8, 10
    la   t0, handler
    ori  t0, t0, 1
    csrw mtvec, t0
    ecall
    li   t1, 11
    bne  s10, t1, fail
    la   t0, handler
    csrw mtvec, t0

    # ---------- 11 trap 的连续性：mepc / MPIE ----------
    li   s8, 11
    csrsi mstatus, 8                # MIE = 1（mie = 0，不会有中断）
    ecall                           # 进入：MPIE <- 1，MIE <- 0；mret：MIE <- MPIE
    csrr t1, mstatus
    li   t2, 0x1888
    bne  t1, t2, fail
    csrci mstatus, 8
    li   t1, 15                     # 一共 15 次 trap
    bne  s9, t1, fail

pass:
    li   t1, 1
    la   t0, tohost
    sw   t1, 0(t0)
pass_spin:
    j    pass_spin

fail:
    slli t1, s8, 1
    ori  t1, t1, 1
    la   t0, tohost
    sw   t1, 0(t0)
fail_spin:
    j    fail_spin

# ---------------- trap 处理程序 ----------------
handler:
    csrw mscratch, t0
    csrr s10, mcause
    csrr s11, mtval
    addi s9, s9, 1
    bltz s10, h_irq                 # 本程序不应有中断
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0
    csrr t0, mscratch
    mret
h_irq:
    li   s8, 99
    j    fail

    .data
tohost: .word 0
buf:    .word 0, 0, 0, 0
