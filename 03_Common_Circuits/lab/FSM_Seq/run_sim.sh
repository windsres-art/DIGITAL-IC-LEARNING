#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
# 学习版保留直接的整数常量写法；仅略过已审查的扩展/截断提示。
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

for m in 0 1; do for o in 0 1; do
  verilator --lint-only -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -GMEALY=$m -GOVERLAP=$o seq_fsm_1101.v
done; done
verilator --lint-only -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC seq_detect_shift.v
verilator --lint-only -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC vending.v

echo "===== tb_fsm ====="
iverilog -g2012 -o fsm_sim seq_fsm_1101.v seq_detect_shift.v vending.v tb_fsm.v
vvp -n fsm_sim
echo "波形: fsm.vcd"
