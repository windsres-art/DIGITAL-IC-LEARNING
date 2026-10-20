#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
verilator --lint-only -Wall expr_datapath.v
yosys -Q -T -p 'read_verilog expr_datapath.v; hierarchy -check -top expr_datapath; proc; opt; check -assert; select -assert-none t:$dlatch' > build/synth.log
for width in 2 4 8; do
    mkdir -p "build/w${width}"
    iverilog -g2012 -gstrict-expr-width -s tb_expressions -Ptb_expressions.W="$width" \
        -o "build/w${width}/sim" expr_datapath.v tb_expressions.sv
    (cd "build/w${width}"; vvp -n sim) | tee "build/w${width}/result.log"
done
echo "PASS Expressions: RTL lint + synthesis structure + 3 simulations"
