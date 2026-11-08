#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
# 学习版保留直接的整数常量写法；仅略过已审查的扩展/截断提示。
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

for n in 2 4 6; do verilator --lint-only -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -GN=$n clk_div_even.v; done
for n in 3 5 7; do verilator --lint-only -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -GN=$n clk_div_odd.v; done
verilator --lint-only -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC clk_div_frac.v
verilator --lint-only -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -GM=5 -GD=2 clk_div_frac.v

echo "===== tb_clk_div ====="
iverilog -g2012 -o clk_div_sim clk_div_even.v clk_div_odd.v clk_div_frac.v tb_clk_div.v
vvp -n clk_div_sim
echo "波形: clk_div.vcd"
