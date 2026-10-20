#!/usr/bin/env bash
set -euo pipefail
source /root/oss-cad-suite/environment
cd "$(dirname "$0")"
mkdir -p build
verilator --version
yosys -V
for lab in Handshake SV_Objects SVA Formal GLS; do
  bash "$lab/run_sim.sh"
done
python3 check_mutations.py
echo "PASS Chapter 11: Handshake + SV_Objects + SVA + Formal + GLS"
