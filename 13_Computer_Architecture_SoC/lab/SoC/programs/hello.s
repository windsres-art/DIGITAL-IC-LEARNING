# SoC 启动代码（crt0）+ 外设自检查程序
#   crt0：设 sp → 把 .data 初值从 ROM 0x2000 拷到 RAM → 清零 .bss → 设 mtvec → call main
#         → 把 main 的返回值写到 tohost（0 → 1 表示通过；否则 (测试号 << 1) | 1）
#   main：
#     1 UART 打印 "hello, SoC"（FIFO 满时总线被 PREADY 反压，软件不查状态）
#     2 默认从机与 ROM 写保护：读未映射地址 → mcause 5；写 ROM → mcause 7
#     3 DMA 按描述符链（3 段，顺序打乱）搬 32 个字；搬运期间 CPU 也在读 RAM（总线竞争）；
#       完成中断经 PLIC 源 1 到达；检查 STATUS、COUNT 和目标数据；打印 "dma ok"
#     4 定时器每 300 周期一次，数 5 次；打印 "timer ok"
#     5 打印 "PASS"；打开 UART "全部发完"中断（PLIC 源 2），等它到来再返回——
#       保证最后一个字符已经从 txd 移出，testbench 才能收全
#   等中断的写法：关 MIE → 查标志 → wfi → 开 MIE。wfi 只看 mip & mie，不看 MIE，
#   所以"查完标志、wfi 之前"到来的中断不会丢（MIE=1 时直接 wfi 有可能永远睡下去）
    .equ UART_TX,    0x20000000
    .equ UART_DIV,   0x20000008
    .equ UART_IE,    0x2000000c
    .equ DMA_CTRL,   0x20001000
    .equ DMA_STATUS, 0x20001004
    .equ DMA_DESC,   0x20001014
    .equ DMA_COUNT,  0x20001018
    .equ PLIC,       0x0c000000
    .equ PLIC_EN,    0x0c002000
    .equ PLIC_TH,    0x0c200000
    .equ PLIC_CLAIM, 0x0c200004
    .equ MTIMECMP,   0x02004000
    .equ MTIMECMPH,  0x02004004
    .equ MTIME,      0x0200bff8
    .equ ROM_DATA,   0x2000
    .equ RAM_TOP,    0x10004000
    .equ TICK,       300

    .text
# ================= crt0 =================
_start:
    li   sp, RAM_TOP
    li   t0, ROM_DATA
    la   t1, _sdata
    la   t2, _edata
copy_loop:
    bgeu t1, t2, copy_done
    lw   t3, 0(t0)
    sw   t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j    copy_loop
copy_done:
    la   t2, _ebss
bss_loop:
    bgeu t1, t2, bss_done
    sw   zero, 0(t1)
    addi t1, t1, 4
    j    bss_loop
bss_done:
    la   t0, trap_entry
    csrw mtvec, t0
    call main
    li   t1, 1
    beqz a0, crt_out
    slli t1, a0, 1
    ori  t1, t1, 1
crt_out:
    la   t0, tohost
    sw   t1, 0(t0)
crt_spin:
    j    crt_spin

# ================= main =================
main:
    addi sp, sp, -16
    sw   ra, 12(sp)
    li   t0, UART_DIV
    li   t1, 8
    sw   t1, 0(t0)                  # 每比特 8 个时钟

    # ---------- 1 ----------
    li   s0, 1
    la   a0, str_hello
    call puts

    # ---------- 2 默认从机 / ROM 写保护 ----------
    li   s0, 2
    la   t0, last_exc
    li   t1, 0x40000000
    lw   t2, 0(t1)                  # 没有从机 → 默认从机 err → 加载访问错误
    lw   t1, 0(t0)
    li   t2, 5
    bne  t1, t2, fail
    sw   zero, 0(t0)
    sw   t2, 0x100(zero)            # ROM 只读 → 存储访问错误
    lw   t1, 0(t0)
    li   t2, 7
    bne  t1, t2, fail

    # ---------- 3 DMA 描述符链 + PLIC ----------
    li   s0, 3
    la   t0, srcbuf                 # srcbuf[i] = 0x5A5A0000 + i * 0x01010101
    li   t1, 32
    li   t2, 0x5a5a0000
    li   t3, 0x01010101
gen_loop:
    sw   t2, 0(t0)
    add  t2, t2, t3
    addi t0, t0, 4
    addi t1, t1, -1
    bnez t1, gen_loop
    li   t0, PLIC
    li   t1, 1
    sw   t1, 4(t0)                  # 源 1（DMA）优先级 1
    sw   t1, 8(t0)                  # 源 2（UART）优先级 1
    li   t0, PLIC_EN
    li   t1, 6
    sw   t1, 0(t0)
    li   t0, PLIC_TH
    sw   zero, 0(t0)
    li   t0, 0x800
    csrs mie, t0                    # MEIE
    csrsi mstatus, 8
    li   t0, DMA_DESC
    la   t1, desc0
    sw   t1, 0(t0)
    li   t0, DMA_CTRL
    li   t1, 7                      # START | IE | SG
    sw   t1, 0(t0)
    # DMA 搬运的同时，CPU 连续 8 个 lw 一组读同一块 RAM 求和（两个主机连续争 RAM 从机）
    la   t0, srcbuf
    li   t1, 4
    li   t2, 0
sum_loop:
    lw   t3, 0(t0)
    lw   t4, 4(t0)
    lw   t5, 8(t0)
    lw   t6, 12(t0)
    lw   a3, 16(t0)
    lw   a4, 20(t0)
    lw   a5, 24(t0)
    lw   a6, 28(t0)
    add  t2, t2, t3
    add  t2, t2, t4
    add  t2, t2, t5
    add  t2, t2, t6
    add  t2, t2, a3
    add  t2, t2, a4
    add  t2, t2, a5
    add  t2, t2, a6
    addi t0, t0, 32
    addi t1, t1, -1
    bnez t1, sum_loop
    li   t3, 0x3d31f1f0             # 32 × 0x5A5A0000 + 496 × 0x01010101（mod 2^32）
    bne  t2, t3, fail
dma_wait:
    csrci mstatus, 8
    la   t0, dma_status
    lw   t1, 0(t0)
    bnez t1, dma_got
    wfi
    csrsi mstatus, 8
    j    dma_wait
dma_got:
    csrsi mstatus, 8
    li   t2, 2
    bne  t1, t2, fail               # 中断里读到的 STATUS：只有 DONE
    li   t0, DMA_COUNT
    lw   t1, 0(t0)
    li   t2, 32
    bne  t1, t2, fail
    la   a0, dstbuf
    la   a1, srcbuf + 32
    li   a2, 8
    call memcmp_w
    bnez a0, fail
    la   a0, dstbuf + 32
    la   a1, srcbuf
    li   a2, 8
    call memcmp_w
    bnez a0, fail
    la   a0, dstbuf + 64
    la   a1, srcbuf + 64
    li   a2, 16
    call memcmp_w
    bnez a0, fail
    la   a0, str_dma
    call puts

    # ---------- 4 定时器 ----------
    li   s0, 4
    li   t0, MTIMECMPH
    sw   zero, 0(t0)
    li   t0, MTIME
    lw   s1, 0(t0)
    addi t1, s1, TICK
    la   t2, next_cmp
    sw   t1, 0(t2)
    li   t0, MTIMECMP
    sw   t1, 0(t0)
    li   t0, 0x80
    csrs mie, t0                    # MTIE
tick_wait:
    csrci mstatus, 8
    la   t0, ticks
    lw   t1, 0(t0)
    li   t2, 5
    bge  t1, t2, tick_got
    wfi
    csrsi mstatus, 8
    j    tick_wait
tick_got:
    csrsi mstatus, 8
    li   t0, 0x80
    csrc mie, t0
    li   t0, MTIME
    lw   t1, 0(t0)
    sub  t1, t1, s1
    li   t2, 5 * TICK
    bltu t1, t2, fail               # 5 次中断至少经过 1500 个 mtime 计数
    la   a0, str_timer
    call puts

    # ---------- 5 UART 发完中断 ----------
    li   s0, 5
    la   a0, str_pass
    call puts
    li   t0, UART_IE
    li   t1, 1
    sw   t1, 0(t0)
uart_wait:
    csrci mstatus, 8
    la   t0, uart_done
    lw   t1, 0(t0)
    bnez t1, uart_got
    wfi
    csrsi mstatus, 8
    j    uart_wait
uart_got:
    li   a0, 0
    j    main_ret
fail:
    mv   a0, s0
main_ret:
    lw   ra, 12(sp)
    addi sp, sp, 16
    ret

# puts(a0 = 以 0 结尾的字符串)
puts:
    lbu  t0, 0(a0)
    beqz t0, puts_done
    li   t1, UART_TX
    sw   t0, 0(t1)
    addi a0, a0, 1
    j    puts
puts_done:
    ret

# memcmp_w(a0, a1, a2 = 字数) → a0 = 0 表示相同
memcmp_w:
    beqz a2, mc_same
    lw   t0, 0(a0)
    lw   t1, 0(a1)
    bne  t0, t1, mc_diff
    addi a0, a0, 4
    addi a1, a1, 4
    addi a2, a2, -1
    j    memcmp_w
mc_same:
    li   a0, 0
    ret
mc_diff:
    li   a0, 1
    ret

# ================= trap 入口 =================
trap_entry:
    addi sp, sp, -16
    sw   t0, 0(sp)
    sw   t1, 4(sp)
    sw   t2, 8(sp)
    sw   t3, 12(sp)
    csrr t0, mcause
    bltz t0, t_irq
    la   t1, last_exc               # 异常：记下 cause，跳过出错的指令
    sw   t0, 0(t1)
    csrr t1, mepc
    addi t1, t1, 4
    csrw mepc, t1
    j    t_ret
t_irq:
    andi t0, t0, 0xf
    li   t1, 7
    beq  t0, t1, t_timer
    li   t0, PLIC_CLAIM
    lw   t1, 0(t0)
    li   t2, 1
    beq  t1, t2, t_dma
    li   t2, 2
    beq  t1, t2, t_uart
    beqz t1, t_ret
    j    t_complete
t_dma:
    li   t2, DMA_STATUS
    lw   t3, 0(t2)
    la   t2, dma_status
    sw   t3, 0(t2)
    li   t2, DMA_STATUS
    li   t3, 6
    sw   t3, 0(t2)                  # 写 1 清 DONE / ERR，撤销 irq……
    j    t_complete
t_uart:
    li   t2, UART_IE
    sw   zero, 0(t2)
    la   t2, uart_done
    li   t3, 1
    sw   t3, 0(t2)
t_complete:
    sw   t1, 0(t0)                  # ……再 complete
    j    t_ret
t_timer:
    la   t0, ticks
    lw   t1, 0(t0)
    addi t1, t1, 1
    sw   t1, 0(t0)
    la   t0, next_cmp
    lw   t2, 0(t0)
    addi t2, t2, TICK
    sw   t2, 0(t0)
    li   t3, 5
    blt  t1, t3, t_set
    li   t2, -1                     # 数够了：mtimecmp 设到很远
t_set:
    li   t0, MTIMECMP
    sw   t2, 0(t0)
t_ret:
    lw   t0, 0(sp)
    lw   t1, 4(sp)
    lw   t2, 8(sp)
    lw   t3, 12(sp)
    addi sp, sp, 16
    mret

# ================= .data（初值在 ROM 0x2000，由 crt0 拷到 RAM）=================
    .data
_sdata:
tohost:     .word 0
desc0:      .word srcbuf + 32, dstbuf,      32, desc1
desc1:      .word srcbuf,      dstbuf + 32, 32, desc2
desc2:      .word srcbuf + 64, dstbuf + 64, 64, 0
str_hello:  .asciz "hello, SoC\n"
str_dma:    .asciz "dma ok\n"
str_timer:  .asciz "timer ok\n"
str_pass:   .asciz "PASS\n"
    .align 2
_edata:
# ================= .bss（crt0 清零）=================
last_exc:   .space 4
dma_status: .space 4
ticks:      .space 4
next_cmp:   .space 4
uart_done:  .space 4
srcbuf:     .space 128
dstbuf:     .space 128
_ebss:
