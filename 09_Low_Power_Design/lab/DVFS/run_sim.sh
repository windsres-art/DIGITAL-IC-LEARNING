#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
verilator --lint-only -Wall --top-module dvfs_seq dvfs_seq.v > build/lint.log 2>&1
yosys -Q -T -p 'read_verilog dvfs_seq.v; hierarchy -check -top dvfs_seq; proc; opt; check -assert; select -assert-none t:$dlatch' > build/synth.log 2>&1
iverilog -g2012 -gstrict-expr-width -s tb_dvfs -o build/sim dvfs_seq.v tb_dvfs.sv
(cd build; vvp -n sim) | tee build/sim.log
