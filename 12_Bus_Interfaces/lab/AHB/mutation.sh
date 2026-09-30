#!/usr/bin/env bash
# 变异测试：注入两个典型错误，确认 testbench 能抓到。bash mutation.sh
#   M1 SRAM 去掉写后读旁路（同步读在写提交的同一沿读到旧值）
#   M2 响应 MUX 用地址阶段的组合译码选择（没有寄存到数据阶段）
# 变异文件写到 build_mut/，不改原 RTL；每个变异都应该打印 FAIL
set -uo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment
mkdir -p build_mut

run() {  # $1 名称  $2 sram  $3 decoder_mux
  iverilog -g2012 -o "build_mut/$1" "$2" "$3" tb_ahb.v
  vvp -n "build_mut/$1" | awk '/ERROR/ && n < 2 {print; n++} /PASS|FAIL/ {print}'
}

echo "===== M1: 去掉写后读旁路 ====="
sed 's/wire        raw    = wr_commit & (dp_widx == ap_widx);/wire        raw    = 1'"'"'b0;/' ahb_sram.v > build_mut/sram_m1.v
grep -q "raw    = 1'b0" build_mut/sram_m1.v || { echo "sed 没有匹配"; exit 1; }
run m1 build_mut/sram_m1.v ahb_decoder_mux.v

echo "===== M2: 响应 MUX 用地址阶段选择 ====="
sed 's/case (sel_dp)/case (sel_ap)/' ahb_decoder_mux.v > build_mut/ic_m2.v
run m2 ahb_sram.v build_mut/ic_m2.v
