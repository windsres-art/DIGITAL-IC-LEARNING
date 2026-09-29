#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-MULTITOP clk_mux.v
iverilog -g2012 -o clk_mux_sim clk_mux.v tb_clk_mux.v
vvp -n clk_mux_sim
echo "波形: $(pwd)/clk_mux.vcd  →  gtkwave clk_mux.vcd"
