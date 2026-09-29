#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

verilator --lint-only -Wall handshake_sync.v
verilator --lint-only -Wall mcp_sync.v
iverilog -g2012 -o multi_bit_sim handshake_sync.v mcp_sync.v tb_multi_bit_sync.v
vvp -n multi_bit_sim
echo "波形: $(pwd)/multi_bit_sync.vcd  →  gtkwave multi_bit_sync.vcd"
