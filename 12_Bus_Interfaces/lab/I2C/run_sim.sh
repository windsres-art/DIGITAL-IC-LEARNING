#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

verilator --lint-only -Wall i2c_master.v
verilator --lint-only -Wall i2c_slave.v

echo "===== tb_i2c ====="
iverilog -g2012 -o i2c_sim i2c_master.v i2c_slave.v tb_i2c.v
vvp -n i2c_sim | grep -v 'VCD info'
echo "波形: i2c.vcd（只录 P1 前 20 笔事务）"
