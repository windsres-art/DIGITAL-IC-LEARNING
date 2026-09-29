#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

# 一个文件放了多个模块，关掉文件名/多顶层两条风格警告
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-MULTITOP clk_gate.v
iverilog -g2012 -o clk_gate_sim clk_gate.v tb_clk_gate.v
vvp -n clk_gate_sim
echo "波形: $(pwd)/clk_gate.vcd  →  gtkwave clk_gate.vcd"
