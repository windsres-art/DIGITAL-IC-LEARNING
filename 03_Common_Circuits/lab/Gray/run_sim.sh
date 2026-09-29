#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

for f in bin2gray.v gray2bin.v gray2bin_log.v gray_cnt_dual.v gray_cnt_pure.v; do
  verilator --lint-only -Wall "$f"
done

echo "===== tb_gray ====="
iverilog -g2012 -o gray_sim bin2gray.v gray2bin.v gray2bin_log.v gray_cnt_dual.v gray_cnt_pure.v tb_gray.v
vvp -n gray_sim
echo "波形: gray.vcd"
