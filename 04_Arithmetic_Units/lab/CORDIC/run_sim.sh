#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
python3 generate_vectors.py | tee build/reference.log
for n in 8 12 16 20; do
    dir="build/n$n"
    verilator --lint-only -Wall --top-module cordic_iter -GITER="$n" cordic_iter.v > "$dir/lint.log" 2>&1
    yosys -Q -T -p "read_verilog cordic_iter.v; chparam -set ITER $n cordic_iter; hierarchy -check -top cordic_iter; proc; opt; check -assert; select -assert-none t:\$dlatch t:\$mul t:\$div" > "$dir/synth.log" 2>&1
    iverilog -g2012 -gstrict-expr-width -s tb_cordic -Ptb_cordic.ITER="$n" -o "$dir/sim" cordic_iter.v tb_cordic.sv
    (cd "$dir"; vvp -n sim) | tee "$dir/sim.log"
done
