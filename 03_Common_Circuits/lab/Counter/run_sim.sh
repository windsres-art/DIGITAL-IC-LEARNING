#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

for f in counter_load.v counter_bcd.v counter_ring.v counter_johnson.v; do
  verilator --lint-only -Wall "$f"
done

echo "===== tb_counter ====="
iverilog -g2012 -o counter_sim counter_load.v counter_bcd.v counter_ring.v counter_johnson.v tb_counter.v
vvp -n counter_sim
echo "波形: counter.vcd"
