#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
verilator --lint-only -Wall request_fsm.v
yosys -Q -T -p 'read_verilog request_fsm.v; hierarchy -check -top request_fsm; proc; opt; check -assert; select -assert-none t:$dlatch; stat' > build/synth.log
iverilog -g2012 -gstrict-expr-width -s tb_request_fsm -o build/sim request_fsm.v tb_request_fsm.sv
(cd build; vvp -n sim) | tee build/result.log
echo "PASS FSM_Style: lint + no latch + simulation"
