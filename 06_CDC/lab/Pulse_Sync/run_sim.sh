#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-MULTITOP pulse_sync.v
iverilog -g2012 -o pulse_sync_sim pulse_sync.v tb_pulse_sync.v
vvp -n pulse_sync_sim
echo "波形: $(pwd)/pulse_sync.vcd  →  gtkwave pulse_sync.vcd"
