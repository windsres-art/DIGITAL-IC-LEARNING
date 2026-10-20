#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
verilator --lint-only -Wall pipeline.v
yosys -Q -T -p 'read_verilog pipeline.v; hierarchy -check -top pipeline; proc; opt; check -assert; select -assert-none t:$dlatch; select -assert-count 2 t:$adffe' > build/synth.log
iverilog -g2012 -gstrict-expr-width -s tb_scheduling -o build/sim pipeline.v tb_scheduling.sv
(cd build; vvp -n sim) | tee build/result.log
echo "PASS Scheduling: RTL lint + 2 register banks + simulation"
