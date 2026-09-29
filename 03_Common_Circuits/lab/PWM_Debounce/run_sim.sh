#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

verilator --lint-only -Wall pwm.v
verilator --lint-only -Wall -GN=64 debounce.v
verilator --lint-only -Wall debounce.v

echo "===== tb_pwm_debounce ====="
iverilog -g2012 -o pwm_debounce_sim pwm.v debounce.v tb_pwm_debounce.v
vvp -n pwm_debounce_sim
echo "波形: pwm_debounce.vcd"
