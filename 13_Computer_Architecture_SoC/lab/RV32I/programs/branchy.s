# 分支预测实验用程序（自检查）
#   外层 50 次 × 内层 8 次的双重循环；内层里有一个按奇偶交替的分支，再调用一个小函数。
#   - 内层回跳分支：大多数时候跳，每 8 次不跳一次      → 2 bit 计数器很擅长
#   - 奇偶分支：跳 / 不跳交替                         → 静态预测与 2 bit 计数器都只有约一半
#   - 函数返回 jalr：目标在运行时才知道               → 本章预测器不预测 jalr，每次都要冲刷

    .data
tohost: .word 0

    .text
_start:
    li   s0, 0                # 外层计数
    li   s2, 0                # 累加结果
    li   s3, 50
outer:
    li   s1, 0                # 内层计数
inner:
    andi t0, s1, 1
    beqz t0, even             # 奇偶交替
    addi s2, s2, 3
    j    next
even:
    addi s2, s2, 1
next:
    mv   a0, s1
    call twice
    add  s2, s2, a0
    addi s1, s1, 1
    li   t1, 8
    blt  s1, t1, inner
    addi s0, s0, 1
    blt  s0, s3, outer

    # 每次外层：奇偶部分 4×3 + 4×1 = 16，twice 部分 2×(0+1+...+7) = 56，共 72
    li   gp, 1
    li   t6, 3600             # 72 × 50
    bne  s2, t6, fail
    j    pass

twice:
    add  a0, a0, a0
    ret

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
