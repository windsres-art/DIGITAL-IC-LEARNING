#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
verilator --lint-only -Wall --top-module power_seq power_seq.v > build/lint.log 2>&1
yosys -Q -T -p 'read_verilog power_seq.v; hierarchy -check -top power_seq; proc; opt; check -assert; select -assert-none t:$dlatch' > build/synth.log 2>&1
iverilog -g2012 -gstrict-expr-width -s tb_power_seq -o build/sim power_seq.v tb_power_seq.sv
(cd build; vvp -n sim) | tee build/sim.log
