#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
python3 generate_walk.py | tee build/walk.log
verilator --lint-only -Wall tap_demo.v > build/lint.log 2>&1
yosys -Q -T -p 'read_verilog tap_demo.v; hierarchy -check -top tap_demo; proc; opt; check -assert; select -assert-none t:$dlatch' > build/synth.log 2>&1
iverilog -g2012 -s tb_tap -o build/sim tap_demo.v tb_tap.sv
(cd build; vvp -n sim) | tee build/sim.log
