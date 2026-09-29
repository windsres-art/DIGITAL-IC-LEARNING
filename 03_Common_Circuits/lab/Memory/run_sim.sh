#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

RTL="spram.v sdpram.v regfile.v rom_sine.v sram_model.v sram_wrap.v"
for f in spram.v sdpram.v regfile.v rom_sine.v sram_model.v; do
  verilator --lint-only -Wall "$f"
done
verilator --lint-only -Wall sram_wrap.v sram_model.v --top-module sram_wrap

echo "===== tb_memory ====="
iverilog -g2012 -o memory_sim $RTL tb_memory.v
vvp -n memory_sim
echo "波形: memory.vcd"
