# 递归 Fibonacci：fib(12) = 144（自检查）
#   覆盖调用约定：call / ret、栈帧（sp 向下增长）、callee-saved 寄存器 s0/s1 的保存与恢复。
#   每次返回都是 jalr，返回地址在运行时才知道 —— 对分支预测最不友好的一类跳转。

    .data
tohost: .word 0

    .text
_start:
    li   sp, 0x10004000       # 栈顶 = 数据存储器末尾
    li   a0, 12
    call fib
    li   gp, 1
    li   t6, 144
    bne  a0, t6, fail
    li   gp, 2                # 栈指针必须恢复原值
    li   t6, 0x10004000
    bne  sp, t6, fail
    j    pass

# a0 = fib(a0)
fib:
    li   t0, 2
    blt  a0, t0, fib_ret      # n < 2 时返回 n
    addi sp, sp, -12
    sw   ra, 8(sp)
    sw   s0, 4(sp)
    sw   s1, 0(sp)
    mv   s0, a0
    addi a0, s0, -1
    call fib                  # fib(n-1)
    mv   s1, a0
    addi a0, s0, -2
    call fib                  # fib(n-2)
    add  a0, a0, s1
    lw   s1, 0(sp)
    lw   s0, 4(sp)
    lw   ra, 8(sp)
    addi sp, sp, 12
fib_ret:
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
