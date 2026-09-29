#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

verilator --lint-only -Wall sync_2ff.v

echo "===== tb_sync_2ff：单 bit 电平同步 ====="
iverilog -g2012 -o sync_2ff_sim sync_2ff.v tb_sync_2ff.v
vvp -n sync_2ff_sim

echo "===== tb_bus_skew：多 bit 总线直接打两拍 ====="
iverilog -g2012 -o bus_skew_sim sync_2ff.v tb_bus_skew.v
vvp -n bus_skew_sim
echo "波形: sync_2ff.vcd / bus_skew.vcd"
