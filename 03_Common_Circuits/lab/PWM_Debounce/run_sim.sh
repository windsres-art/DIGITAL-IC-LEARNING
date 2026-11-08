#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
# 学习版保留直接的整数常量写法；仅略过已审查的扩展/截断提示。
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

verilator --lint-only -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC pwm.v
verilator --lint-only -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -GN=64 debounce.v
verilator --lint-only -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC debounce.v

echo "===== tb_pwm_debounce ====="
iverilog -g2012 -o pwm_debounce_sim pwm.v debounce.v tb_pwm_debounce.v
vvp -n pwm_debounce_sim
echo "波形: pwm_debounce.vcd"
