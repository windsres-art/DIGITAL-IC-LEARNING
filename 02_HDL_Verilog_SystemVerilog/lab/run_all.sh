#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
for experiment in Expressions Scheduling FSM_Style Generate SV_Design Pitfalls; do
    echo "RUN $experiment"
    bash "$experiment/run_sim.sh"
done
echo "PASS Chapter 02: all 6 experiments"
