#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
# 学习版保留直接的整数常量写法；仅略过已审查的扩展/截断提示。
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

for f in arb_fixed.v arb_rr.v arb_rr_mask.v arb_wrr.v; do
  verilator --lint-only -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC "$f"
done

echo "===== tb_arbiter ====="
iverilog -g2012 -o arbiter_sim arb_fixed.v arb_rr.v arb_rr_mask.v arb_wrr.v tb_arbiter.v
vvp -n arbiter_sim
echo "波形: arbiter.vcd"
