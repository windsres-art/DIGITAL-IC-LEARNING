#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

verilator --lint-only -Wall edge_detect.v
verilator --lint-only -Wall -GREG_OUT=1 edge_detect.v
verilator --lint-only -Wall edge_detect_async.v

echo "===== tb_edge_detect ====="
iverilog -g2012 -o edge_detect_sim edge_detect.v edge_detect_async.v tb_edge_detect.v
vvp -n edge_detect_sim
echo "波形: edge_detect.vcd"
