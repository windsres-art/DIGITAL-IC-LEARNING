#!/usr/bin/env bash
# 变异测试：注入三个典型错误，确认 testbench 能抓到。bash mutation.sh
#   M1 WRAP 回绕窗口算成 len × size（应为 (len+1) × size）
#   M2 每写一拍就回一个 B（没等 WLAST）
#   M3 R 输出寄存器不管 RREADY 就装下一拍（反压时数据被覆盖）
# 变异文件写到 build_mut/，不改原 RTL；每个变异都应该打印 FAIL
set -uo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment
mkdir -p build_mut

run() {  # $1 名称  $2 变异后的 axi_ram
  grep -q . "$2" || { echo "变异文件为空"; return; }
  if cmp -s "$2" axi_ram.v; then echo "sed 没有匹配"; return; fi
  iverilog -g2012 -P tb_axi.MAX_OUT=4 -o "build_mut/$1" axi_fifo.v "$2" tb_axi.v
  vvp -n "build_mut/$1" | awk '/ERROR/ && n < 2 {print; n++} /PASS|FAIL/ {print}'
}

echo "===== M1: WRAP 窗口少一拍 ====="
sed 's/(({{(AW-8){1'"'"'b0}}, len} + 1'"'"'b1) << size)/({{(AW-8){1'"'"'b0}}, len} << size)/' axi_ram.v > build_mut/ram_m1.v
run m1 build_mut/ram_m1.v

echo "===== M2: 每拍都回 B ====="
sed 's/\.push(w_last_hs), \.din({wc_id/.push(w_hs), .din({wc_id/' axi_ram.v > build_mut/ram_m2.v
run m2 build_mut/ram_m2.v

echo "===== M3: R 输出不等 RREADY ====="
sed 's/wire r_load = ~arq_empty & (~rvalid | rready);/wire r_load = ~arq_empty;/' axi_ram.v > build_mut/ram_m3.v
run m3 build_mut/ram_m3.v
