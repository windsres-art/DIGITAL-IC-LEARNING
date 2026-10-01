# RV32I 指令定向测试（自检查）
#   每个测试先把测试号放进 gp，算出结果后和期望值比较，不等就跳 fail。
#   结束时写 tohost：1 = 通过，(gp << 1) | 1 = 第 gp 号测试失败。
#   期望值全部手算，和 ISS / RTL 都无关，所以三者互相独立。

    .data
tohost: .word 0
tdat:   .word 0x00ff00ff, 0xff00ff00, 0x0ff00ff0, 0xf00ff00f
buf:    .word 0, 0, 0, 0

    .text
_start:
    li   sp, 0x10004000

# ---- 1 addi 负立即数 ----
    li   gp, 1
    li   t0, 5
    addi t1, t0, -7
    li   t6, -2
    bne  t1, t6, fail

# ---- 2 写 x0 无效 ----
    li   gp, 2
    addi zero, zero, 123
    li   t0, 99
    add  zero, t0, t0
    bnez zero, fail

# ---- 3 slti 有符号 / sltiu 无符号 ----
    li   gp, 3
    li   t0, -1
    slti  t1, t0, 0          # -1 < 0
    sltiu t2, t0, 0          # 0xffffffff < 0 不成立
    li   t6, 1
    bne  t1, t6, fail
    bnez t2, fail

# ---- 4 sltiu：立即数先符号扩展，再按无符号比较 ----
    li   gp, 4
    li   t0, 5
    sltiu t1, t0, -1         # 5 < 0xffffffff
    li   t6, 1
    bne  t1, t6, fail
    seqz t2, zero            # sltiu t2, zero, 1
    bne  t2, t6, fail

# ---- 5 xori / ori / andi ----
    li   gp, 5
    li   t0, 0x0ff0
    xori t1, t0, -1
    li   t6, 0xfffff00f
    bne  t1, t6, fail
    ori  t1, t0, 0x00f
    li   t6, 0x0fff
    bne  t1, t6, fail
    andi t1, t0, 0x0f0
    li   t6, 0x0f0
    bne  t1, t6, fail

# ---- 6 立即数移位 ----
    li   gp, 6
    li   t0, 0x80000001
    slli t1, t0, 1
    li   t6, 2
    bne  t1, t6, fail
    srli t1, t0, 31
    li   t6, 1
    bne  t1, t6, fail
    srai t1, t0, 31
    li   t6, -1
    bne  t1, t6, fail
    srai t1, t0, 4
    li   t6, 0xf8000000
    bne  t1, t6, fail

# ---- 7 add / sub 溢出回绕 ----
    li   gp, 7
    li   t0, 0x7fffffff
    li   t1, 1
    add  t2, t0, t1
    li   t6, 0x80000000
    bne  t2, t6, fail
    sub  t2, zero, t1
    li   t6, -1
    bne  t2, t6, fail
    sub  t2, t1, t0
    li   t6, 0x80000002
    bne  t2, t6, fail

# ---- 8 slt / sltu ----
    li   gp, 8
    li   t0, -5
    li   t1, 3
    slt  t2, t0, t1
    li   t6, 1
    bne  t2, t6, fail
    sltu t2, t0, t1
    bnez t2, fail
    slt  t2, t1, t0
    bnez t2, fail
    sltu t2, t1, t0
    bne  t2, t6, fail
    snez t2, t0              # sltu t2, zero, t0
    bne  t2, t6, fail

# ---- 9 xor / or / and ----
    li   gp, 9
    li   t0, 0x12345678
    li   t1, 0x0f0f0f0f
    xor  t2, t0, t1
    li   t6, 0x1d3b5977
    bne  t2, t6, fail
    or   t2, t0, t1
    li   t6, 0x1f3f5f7f
    bne  t2, t6, fail
    and  t2, t0, t1
    li   t6, 0x02040608
    bne  t2, t6, fail

# ---- 10 寄存器移位只用低 5 位 ----
    li   gp, 10
    li   t0, 0x80000000
    li   t1, 33              # 低 5 位 = 1
    srl  t2, t0, t1
    li   t6, 0x40000000
    bne  t2, t6, fail
    sra  t2, t0, t1
    li   t6, 0xc0000000
    bne  t2, t6, fail
    sll  t2, t0, t1
    bnez t2, fail
    li   t1, -1              # 低 5 位 = 31
    srl  t2, t0, t1
    li   t6, 1
    bne  t2, t6, fail

# ---- 11 lui / auipc ----
    li   gp, 11
    lui  t0, 0xfffff
    li   t6, 0xfffff000
    bne  t0, t6, fail
here:
    auipc t0, 1              # t0 = here + 0x1000
    la   t6, here + 0x1000
    bne  t0, t6, fail

# ---- 12 jal：跳转与链接值 ----
    li   gp, 12
    jal  t0, j_target
j_link:
    j    fail
j_target:
    la   t6, j_link
    bne  t0, t6, fail

# ---- 13 jalr：目标地址最低位清零；rd == rs1 时先算目标再写链接 ----
    li   gp, 13
    la   t1, jr_target
    addi t1, t1, 1
    jalr t2, 0(t1)
jr_link:
    j    fail
jr_target:
    la   t6, jr_link
    bne  t2, t6, fail
    la   t1, jr_target2
    jalr t1, 0(t1)
jr_link2:
    j    fail
jr_target2:
    la   t6, jr_link2
    bne  t1, t6, fail

# ---- 14 六种分支，跳 / 不跳都覆盖 ----
    li   gp, 14
    li   t0, -1
    li   t1, 1
    blt  t0, t1, ok1         # -1 < 1
    j    fail
ok1:
    bltu t0, t1, fail        # 0xffffffff < 1 不成立
    bge  t1, t0, ok2
    j    fail
ok2:
    bgeu t1, t0, fail
    beq  t0, t0, ok3
    j    fail
ok3:
    bne  t0, t0, fail
    bge  t0, t0, ok4         # 相等也算 >=
    j    fail
ok4:
    bgeu t0, t0, ok5
    j    fail
ok5:
    blt  t0, t0, fail
    bltu t1, t1, fail

# ---- 15 load：符号扩展与字节通道 ----
    li   gp, 15
    la   t0, tdat
    lw   t1, 0(t0)
    li   t6, 0x00ff00ff
    bne  t1, t6, fail
    lb   t1, 0(t0)           # 0xff
    li   t6, -1
    bne  t1, t6, fail
    lbu  t1, 0(t0)
    li   t6, 0xff
    bne  t1, t6, fail
    lb   t1, 1(t0)           # 0x00
    bnez t1, fail
    lh   t1, 0(t0)           # 0x00ff
    li   t6, 0xff
    bne  t1, t6, fail
    lh   t1, 4(t0)           # 0xff00 -> 符号扩展
    li   t6, 0xffffff00
    bne  t1, t6, fail
    lhu  t1, 6(t0)           # 0xff00
    li   t6, 0xff00
    bne  t1, t6, fail
    lb   t1, 7(t0)           # 0xff
    li   t6, -1
    bne  t1, t6, fail
    addi t2, t0, 8
    lw   t1, -4(t2)          # 负偏移
    li   t6, 0xff00ff00
    bne  t1, t6, fail

# ---- 16 store：字节 / 半字写到正确的通道，不碰其它字节 ----
    li   gp, 16
    la   t0, buf
    li   t1, -1
    sw   t1, 0(t0)
    li   t1, 0x11223344
    sb   t1, 1(t0)           # 0xffff44ff
    lw   t2, 0(t0)
    li   t6, 0xffff44ff
    bne  t2, t6, fail
    sh   t1, 2(t0)           # 0x334444ff
    lw   t2, 0(t0)
    li   t6, 0x334444ff
    bne  t2, t6, fail
    sb   zero, 0(t0)         # 0x33444400
    lbu  t2, 0(t0)
    bnez t2, fail
    lw   t2, 0(t0)
    li   t6, 0x33444400
    bne  t2, t6, fail

# ---- 17 fence 当作 nop ----
    li   gp, 17
    fence
    li   t0, 1
    beqz t0, fail

pass:
    li   t0, 1
    la   t1, tohost
    sw   t0, 0(t1)
    ecall
fail:
    slli t0, gp, 1
    ori  t0, t0, 1
    la   t1, tohost
    sw   t0, 0(t1)
    ecall
