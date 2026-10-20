#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
python3 atpg.py | tee build/atpg.log
verilator --lint-only -Wall fault_cone.v > build/lint_fault.log 2>&1
iverilog -g2012 -s tb_fault -o build/fault fault_cone.v tb_fault.sv
(cd build; vvp -n fault) | tee build/fault.log
for w in 1 4 9; do
    verilator --lint-only -Wall -GW="$w" scan_bank.v > "build/lint_w$w.log" 2>&1
    yosys -Q -T -p "read_verilog scan_bank.v; chparam -set W $w scan_bank; hierarchy -check -top scan_bank; proc; opt; check -assert; select -assert-none t:\$dlatch" > "build/synth_w$w.log" 2>&1
    iverilog -g2012 -s tb_scan -Ptb_scan.W="$w" -o build/scan scan_bank.v tb_scan.sv
    (cd build; vvp -n scan) | tee "build/scan_w$w.log"
done
