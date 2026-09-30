#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

verilator --lint-only -Wall axi_fifo.v
verilator --lint-only -Wall axi_ram.v axi_fifo.v

for n in 1 4; do
  echo "===== tb_axi：主机 outstanding 上限 MAX_OUT=$n ====="
  iverilog -g2012 -P tb_axi.MAX_OUT=$n -o axi_sim axi_fifo.v axi_ram.v tb_axi.v
  vvp -n axi_sim | grep -v 'VCD info'
done
echo "波形: axi.vcd（最后一次运行，MAX_OUT=4）"
