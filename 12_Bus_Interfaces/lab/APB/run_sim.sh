#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

verilator --lint-only -Wall apb_master.v
verilator --lint-only -Wall -GWAIT=0 apb_regs.v
verilator --lint-only -Wall -GWAIT=2 apb_regs.v

for w in 0 2; do
  echo "===== tb_apb：WAIT=$w ====="
  iverilog -g2012 -P tb_apb.WAIT=$w -o apb_sim apb_master.v apb_regs.v tb_apb.v
  vvp -n apb_sim | grep -v 'VCD info'
done
echo "波形: apb.vcd（最后一次运行，WAIT=2）"
