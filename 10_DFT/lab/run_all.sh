#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
{ verilator --version; yosys -V; } > build/versions.log
for lab in Scan_ATPG MBIST JTAG; do
    echo "RUN $lab"
    bash "$lab/run_sim.sh"
done
python3 check_mutations.py | tee build/mutations.log
echo "PASS Chapter 10: Scan_ATPG + MBIST + JTAG"
