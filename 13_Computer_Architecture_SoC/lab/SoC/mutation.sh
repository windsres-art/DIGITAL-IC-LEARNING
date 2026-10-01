#!/usr/bin/env bash
# 变异测试：bash mutation.sh（先跑过 run_sim.sh，build/hello.* 要已经汇编好）
#   每个变异跑一次 SoC 仿真，再把日志交给 trap_iss.py；任何一项报错就算抓到
#   互联：  S1 轮转指针更新反了（赢家继续优先）   S2 固定优先级（DMA 永远赢）
#           S3 默认从机不回 err                   S4 APB 桥在 SETUP 拍就给 ready
#   外设：  S5 UART 高位先发                      S6 UART FIFO 满时不反压
#           S7 UART 停止位没发                    S8 ROM 可写（不回 err）
#           S9 PLIC 源接反（DMA ↔ UART）
#   软件：  S10 crt0 不清 .bss                    S11 crt0 不拷 .data
set -uo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment
mkdir -p build_mut
CORE="../Trap/rv32i_trap.v ../RV32I/rv32i_decode.v ../RV32I/rv32i_alu.v ../RV32I/rv32i_branch.v ../RV32I/rv32i_lsu.v ../RV32I/rv32i_regfile.v"
PERI="../Trap/clint.v ../Trap/plic.v ../Trap/dma.v"

soc_run() {  # $1 名称  $2 源文件列表  $3 程序前缀
  local res
  iverilog -g2012 -o build_mut/$1 tb_soc.v $2 $PERI $CORE || return
  res=$(timeout 120 vvp -n build_mut/$1 +prog=$3 +log=build_mut/$1.log +expect=programs/hello.expect |
        grep -a -E '^PASS|^FAIL|^ERROR' | head -2 | tr '\n' ' ')
  res="$res/ $(python3 ../Trap/trap_iss.py $3 build_mut/$1.log --map soc | grep -a -E 'MISMATCH|MATCH|FAIL' | head -1)"
  echo "  $res"
  echo "$res" | grep -q -e FAIL -e ERROR -e MISMATCH && echo "  => 抓到" || echo "  => 没抓到"
}

mut() {  # $1 输出文件  $2 原文件  $3 sed 表达式
  sed "$3" "$2" > "$1"
  if cmp -s "$1" "$2"; then echo "  sed 没有匹配"; return 1; fi
}

# $1 名称  $2 被变异的文件  $3 sed：其余 SoC 文件用原版
rtl() {
  local f srcs=""
  mut build_mut/$1.v "$2" "$3" || return
  for f in soc_top.v soc_bus.v apb_bridge.v uart_tx.v; do
    [ "$f" = "$2" ] && srcs="$srcs build_mut/$1.v" || srcs="$srcs $f"
  done
  soc_run $1 "$srcs" build/hello
}

# $1 名称  $2 sed：变异 hello.s
prog() {
  mut build_mut/$1.s programs/hello.s "$2" || return
  python3 ../RV32I/rv32_asm.py build_mut/$1.s -o build_mut/$1 > /dev/null || return
  soc_run $1 "soc_top.v soc_bus.v apb_bridge.v uart_tx.v" build_mut/$1
}

echo "===== S1: 轮转指针更新反了 ====="
rtl s1 soc_bus.v 's/rr\[j\] <= !g1\[j\];/rr[j] <= g1[j];/'
echo "===== S2: 固定优先级（DMA 永远赢）====="
rtl s2 soc_bus.v 's/assign g1\[k\]    = want1\[k\] \&\& (!want0\[k\] || rr\[k\]);/assign g1[k]    = want1[k];/'
echo "===== S3: 默认从机不回 err ====="
rtl s3 soc_bus.v 's/assign m0_err   = r0 \&\& ((t0 == S_ERR) || (hit0 \&\& s_err\[t0\]));/assign m0_err   = r0 \&\& hit0 \&\& s_err[t0];/'
echo "===== S4: APB 桥在 SETUP 拍就给 ready ====="
rtl s4 apb_bridge.v 's/assign ready = done;/assign ready = psel \& pready;/'
echo "===== S5: UART 高位先发 ====="
rtl s5 uart_tx.v 's/? 1.b1 : sh\[0\];/? 1'"'"'b1 : sh[7];/; s/sh   <= {1.b0, sh\[7:1\]};/sh   <= {sh[6:0], 1'"'"'b0};/'
echo "===== S6: UART FIFO 满时不反压 ====="
rtl s6 uart_tx.v 's/assign pready  = !(access \&\& pwrite \&\& a == 4.h0 \&\& full);/assign pready  = 1'"'"'b1;/'
echo "===== S7: UART 停止位没发 ====="
rtl s7 uart_tx.v "s/if (nbit == 4'd10) begin/if (nbit == 4'd9) begin/"
echo "===== S8: ROM 可写 ====="
rtl s8 soc_top.v "s/assign s_err\[0\]   = s_we\[0\];/assign s_err[0]   = 1'b0;/"
echo "===== S9: PLIC 源接反 ====="
rtl s9 soc_top.v 's/.src({1.b0, uart_irq, dma_irq, 1.b0})/.src({1'"'"'b0, dma_irq, uart_irq, 1'"'"'b0})/'
echo "===== S10: crt0 不清 .bss ====="
prog s10 's/bgeu t1, t2, bss_done/j    bss_done/'
echo "===== S11: crt0 不拷 .data ====="
prog s11 's/bgeu t1, t2, copy_done/j    copy_done/'
