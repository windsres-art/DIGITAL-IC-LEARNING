#!/usr/bin/env bash
# 回归第 04 章五个小节的全部实验。
set -euo pipefail
cd "$(dirname "$0")"
for experiment in Adders Multipliers Dividers Fixed_Float CORDIC; do
    echo "RUN $experiment"
    bash "$experiment/run_sim.sh"
    bash "$experiment/run_experiments.sh"
done
echo "PASS Chapter 04: Adders + Multipliers + Dividers + Fixed_Float + CORDIC"
