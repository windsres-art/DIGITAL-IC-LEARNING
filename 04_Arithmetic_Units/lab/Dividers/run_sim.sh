#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
for width in 1 3 4 8 12; do
    mkdir -p "build/w$width"
    for mode in 0 1; do
        verilator --lint-only -Wall --top-module div_iter -GW="$width" -GNONRESTORE="$mode" div_iter.v > "build/w$width/lint_$mode.log" 2>&1
        yosys -Q -T -p "read_verilog div_iter.v; chparam -set W $width -set NONRESTORE $mode div_iter; hierarchy -check -top div_iter; proc; opt; check -assert; select -assert-none t:\$dlatch t:\$div t:\$mod" > "build/w$width/synth_$mode.log" 2>&1
    done
    iverilog -g2012 -gstrict-expr-width -s tb_div_iter -Ptb_div_iter.W="$width" -o "build/w$width/sim" div_iter.v tb_div_iter.sv
    (cd "build/w$width"; vvp -n sim) | tee "build/w$width/sim.log"
done
