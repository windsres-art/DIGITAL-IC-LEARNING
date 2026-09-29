#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

verilator --lint-only -Wall hs_stage_bubble.v
verilator --lint-only -Wall hs_stage_pipe.v

echo "===== tb_handshake ====="
iverilog -g2012 -o handshake_sim hs_stage_bubble.v hs_stage_pipe.v tb_handshake.v
vvp -n handshake_sim
echo "波形: handshake.vcd"
