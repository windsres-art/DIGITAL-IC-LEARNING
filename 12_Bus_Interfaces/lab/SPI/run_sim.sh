#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

verilator --lint-only -Wall spi_master.v
verilator --lint-only -Wall spi_slave.v

echo "===== tb_spi ====="
iverilog -g2012 -o spi_sim spi_master.v spi_slave.v tb_spi.v
vvp -n spi_sim | grep -v 'VCD info'
echo "波形: spi.vcd（只录 P1）"
