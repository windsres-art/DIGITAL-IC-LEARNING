#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

verilator --lint-only -Wall ahb_sram.v
verilator --lint-only -Wall ahb_decoder_mux.v

echo "===== tb_ahb ====="
iverilog -g2012 -o ahb_sim ahb_sram.v ahb_decoder_mux.v tb_ahb.v
vvp -n ahb_sim | grep -v 'VCD info'
echo "波形: ahb.vcd"
