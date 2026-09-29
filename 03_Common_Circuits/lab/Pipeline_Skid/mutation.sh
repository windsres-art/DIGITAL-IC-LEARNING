#!/usr/bin/env bash
# 变异测试：往 RTL 里注入两个典型错误，确认 testbench 能抓到。bash mutation.sh
#   M1 skid_buffer 去掉 skid 捕获（ready 寄存了，但滑出来的数据没地方放）
#   M2 pipe_mac 的 c 没有随数据打拍（S2 直接用输入口的 c）
# 变异文件写到 build_mut/，不改原 RTL
set -uo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

mkdir -p build_mut

echo "===== M1: skid_buffer 不捕获滑出的数据 ====="
sed "s/skid_valid <= 1'b1;/skid_valid <= 1'b0;/" skid_buffer.v > build_mut/skid_m1.v
iverilog -g2012 -o build_mut/m1 build_mut/skid_m1.v pipe_mac.v tb_pipeline_skid.v
vvp -n build_mut/m1 | grep -vE 'VCD|finish'

echo "===== M2: pipe_mac 的 c 没有打拍对齐 ====="
sed "s/{1'b0, c1}/{1'b0, c}/" pipe_mac.v > build_mut/mac_m2.v
iverilog -g2012 -o build_mut/m2 skid_buffer.v build_mut/mac_m2.v tb_pipeline_skid.v
vvp -n build_mut/m2 | grep -vE 'VCD|finish'
