# 流水线冒险定向测试（自检查）
#   单周期 CPU 上这些都是普通指令；五级流水线上每一组都对准一种冒险或一个常见 bug。
#   注释里的"距离"指消费者与生产者相隔几条指令（1 = 紧挨着）。

    .data
tohost: .word 0
hdat:   .word 1234
hout:   .word 0
ptr:    .word hout2
hout2:  .word 0
victim: .word 0x5a5a5a5a

    .text
_start:
# ---- 1 EX/MEM 与 MEM/WB 前递（距离 1、2）----
    li   gp, 1
    li   t0, 1
    addi t1, t0, 1            # 2，t0 来自 EX/MEM
    addi t2, t1, 1            # 3
    add  t3, t2, t1           # rs1 来自 EX/MEM（3），rs2 来自 MEM/WB（2）
    li   t6, 5
    bne  t3, t6, fail

# ---- 2 双重冒险：两级都在写同一个寄存器，必须取最新的 ----
    li   gp, 2
    li   t0, 10
    addi t0, t0, 1            # 11（到 MEM/WB）
    addi t0, t0, 1            # 12（在 EX/MEM）
    add  t1, t0, zero
    li   t6, 12
    bne  t1, t6, fail

# ---- 3 写 x0 的结果不能前递 ----
    li   gp, 3
    li   t0, 7
    addi zero, t0, 5          # 结果 12 被丢弃
    add  t1, zero, zero       # 距离 1
    bnez t1, fail
    addi zero, t0, 5
    nop
    add  t1, zero, zero       # 距离 2
    bnez t1, fail

# ---- 4 寄存器堆写穿透（距离 3：WB 写、ID 读在同一拍）----
    li   gp, 4
    li   t1, 77
    nop
    nop
    addi t2, t1, 0
    li   t6, 77
    bne  t2, t6, fail

# ---- 5 load-use：必须停一拍 ----
    li   gp, 5
    la   t0, hdat
    lw   t1, 0(t0)
    addi t2, t1, 1
    li   t6, 1235
    bne  t2, t6, fail

# ---- 6 load 的结果马上作为 store 的数据 ----
    li   gp, 6
    li   t1, 0                # 先改掉旧值：否则旧值恰好也是 1234，store 数据漏前递也测不出来
    lw   t1, 0(t0)
    sw   t1, 4(t0)            # hout = 1234
    lw   t2, 4(t0)
    li   t6, 1234
    bne  t2, t6, fail

# ---- 7 load 的结果马上作为 store 的地址（指针）----
    li   gp, 7
    li   t3, 0x600d
    lw   t1, 8(t0)            # t1 = &hout2
    sw   t3, 0(t1)
    lw   t2, 12(t0)
    bne  t2, t3, fail

# ---- 8 load 后马上分支 ----
    li   gp, 8
    lw   t1, 0(t0)
    li   t6, 1234
    bne  t1, t6, fail
    lw   t1, 0(t0)
    beq  t1, t6, ok8
    j    fail
ok8:

# ---- 9 ALU 结果马上用于分支比较与 jalr 目标 ----
    li   gp, 9
    li   t1, 3
    addi t1, t1, -3
    bnez t1, fail
    la   t1, tgt9
    addi t1, t1, 0
    jalr ra, 0(t1)
link9:
    j    fail
tgt9:
    la   t2, link9
    bne  ra, t2, fail         # jal/jalr 写的链接值也要能前递

# ---- 10 预测错时，跳转后面已经取进来的指令必须冲掉 ----
    li   gp, 10
    li   t5, 0
    la   t4, victim
    beq  zero, zero, skip10   # 一定跳（总预测不跳时会取进下面两条）
    addi t5, zero, 1          # 不该执行
    sw   zero, 0(t4)          # 不该执行：若漏冲掉，内存会被改
skip10:
    bnez t5, fail
    lw   t1, 0(t4)
    li   t6, 0x5a5a5a5a
    bne  t1, t6, fail
    jal  ra, skip10b          # jal 同理
    addi t5, zero, 1
    addi t5, zero, 1
skip10b:
    bnez t5, fail

# ---- 11 load-use + 双重前递混在一起 ----
    li   gp, 11
    la   t0, hdat
    lw   t1, 0(t0)            # 1234
    add  t1, t1, t1           # 2468（load-use）
    add  t1, t1, t1           # 4936
    sub  t2, t1, t1           # 0
    add  t2, t2, t1           # 4936
    li   t6, 4936
    bne  t2, t6, fail

# ---- 12 循环：给分支预测器一点东西 ----
    li   gp, 12
    li   t0, 0
    li   t1, 0
    li   t2, 20
loop12:
    add  t1, t1, t0
    addi t0, t0, 1
    blt  t0, t2, loop12
    li   t6, 190
    bne  t1, t6, fail

pass:
    li   t0, 1
    la   t1, tohost
    sw   t0, 0(t1)
    ecall
    sw   zero, 0(t1)          # 精确停机：ecall 之后的指令不能执行，否则 tohost 被清零
fail:
    slli t0, gp, 1
    ori  t0, t0, 1
    la   t1, tohost
    sw   t0, 0(t1)
    ecall
