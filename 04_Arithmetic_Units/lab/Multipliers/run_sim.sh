#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
sources=(mul_shift.v mul_booth.v csa_reduce.v mul_wallace.v)
for width in 1 3 4 8 12; do
    mkdir -p "build/w$width"
    for top in mul_shift mul_booth mul_wallace; do
        verilator --lint-only -Wall --top-module "$top" -GW="$width" "${sources[@]}" > "build/w$width/lint_$top.log" 2>&1
        yosys -Q -T -p "read_verilog ${sources[*]}; chparam -set W $width $top; hierarchy -check -top $top; proc; flatten; opt; check -assert; select -assert-none t:\$dlatch t:\$mul" > "build/w$width/synth_$top.log" 2>&1
    done
    for test in comb shift; do
        iverilog -g2012 -gstrict-expr-width -s "tb_mul_$test" \
            "-Ptb_mul_$test.W=$width" -o "build/w$width/$test" "${sources[@]}" "tb_mul_$test.sv"
        (cd "build/w$width"; vvp -n "$test") | tee "build/w$width/$test.log"
    done
    if [[ $width -le 4 ]]; then
        yosys -Q -T -p "read_verilog ${sources[*]} mul_miter.v; chparam -set W $width mul_miter; hierarchy -check -top mul_miter; proc; flatten; opt; sat -verify -timeout 60 -set-def-inputs -prove ok 1" > "build/w$width/formal.log" 2>&1
        grep -q SUCCESS "build/w$width/formal.log"
        echo "PASS formal combinational multipliers W=$width"
    fi
done
echo "PASS Multipliers: 5 widths; combinational + iterative; 3 small-width proofs"
