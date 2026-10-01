# 冒泡排序 16 个有符号数，然后检查升序、首尾元素和总和（自检查）
#   特点：内层循环 lw; lw; ble 构成 load-use，分支方向与数据相关。

    .data
tohost: .word 0
arr:    .word 37, -5, 1000, 0, -32768, 7, 7, 123456, -1, 42, 3, 99, -200, 65535, 8, 1
    .equ N, 16
    .equ SUM, 157221          # 手算的总和，排序前后不变

    .text
_start:
    la   s0, arr
    li   s1, N
outer:
    addi s1, s1, -1           # 本趟比较 s1 次
    blez s1, check
    li   t0, 0
    mv   t1, s0
inner:
    lw   t2, 0(t1)
    lw   t3, 4(t1)
    ble  t2, t3, noswap
    sw   t3, 0(t1)
    sw   t2, 4(t1)
noswap:
    addi t1, t1, 4
    addi t0, t0, 1
    blt  t0, s1, inner
    j    outer

check:
    li   gp, 1                # 升序
    mv   t1, s0
    li   t0, 1
    li   t4, N
    lw   t5, 0(t1)            # t5 = 累加和
chk:
    lw   t2, 0(t1)
    lw   t3, 4(t1)
    bgt  t2, t3, fail
    add  t5, t5, t3
    addi t1, t1, 4
    addi t0, t0, 1
    blt  t0, t4, chk

    li   gp, 2                # 最小、最大值
    lw   t2, 0(s0)
    li   t6, -32768
    bne  t2, t6, fail
    lw   t2, 60(s0)
    li   t6, 123456
    bne  t2, t6, fail

    li   gp, 3                # 总和
    li   t6, SUM
    bne  t5, t6, fail

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
