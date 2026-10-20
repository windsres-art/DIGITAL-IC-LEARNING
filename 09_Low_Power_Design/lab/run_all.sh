#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
{
    iverilog -V 2>&1 | head -n 1 || true
    verilator --version
    yosys -V
} > build/versions.log
for lab in Activity Power_Sequence DVFS; do
    echo "RUN $lab"
    bash "$lab/run_sim.sh"
done
python3 Activity/power_budget.py | tee build/power_budget.log
yosys -Q -T -c Power_Sequence/check_upf_tcl.tcl | tee build/upf_tcl.log
python3 check_mutations.py | tee build/mutations.log
echo "PASS Chapter 09 digital labs; UPF checked for Tcl parsing only"
