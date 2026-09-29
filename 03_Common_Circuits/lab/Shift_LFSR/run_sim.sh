#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

for f in shift_reg.v s2p.v p2s.v lfsr.v; do
  verilator --lint-only -Wall "$f"
done

echo "===== tb_shift_lfsr ====="
iverilog -g2012 -o shift_lfsr_sim shift_reg.v s2p.v p2s.v lfsr.v tb_shift_lfsr.v
vvp -n shift_lfsr_sim
echo "波形: shift_lfsr.vcd"
