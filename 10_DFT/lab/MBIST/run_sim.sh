#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
for depth in 1 4 7; do
    mkdir -p "build/d$depth"
    verilator --lint-only -Wall -GDEPTH="$depth" march_c_minus.v > "build/d$depth/lint.log" 2>&1
    yosys -Q -T -p "read_verilog march_c_minus.v; chparam -set DEPTH $depth march_c_minus; hierarchy -check -top march_c_minus; proc; opt; check -assert; select -assert-none t:\$dlatch" > "build/d$depth/synth.log" 2>&1
    iverilog -g2012 -s tb_march -Ptb_march.DEPTH="$depth" -o "build/d$depth/sim" march_c_minus.v tb_march.sv
    (cd "build/d$depth"; vvp -n sim) | tee "build/d$depth/sim.log"
done
