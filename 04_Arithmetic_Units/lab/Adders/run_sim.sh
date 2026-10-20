#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
sources=(adder_rca.v adder_cla.v adder_cselect.v adder_prefix.v csa3.v adder_three.v)
for config in 1:4 3:4 5:4 8:4 17:4 32:4 17:1 17:7; do
    width=${config%:*}; block=${config#*:}; tag="w${width}_b${block}"
    mkdir -p "build/$tag"
    for top in adder_rca adder_cla adder_cselect adder_prefix csa3 adder_three; do
        params=(-GW="$width")
        if [[ $top == adder_cla || $top == adder_cselect ]]; then params+=(-GB="$block"); fi
        verilator --lint-only -Wall --top-module "$top" "${params[@]}" "${sources[@]}" > "build/$tag/lint_$top.log" 2>&1
    done
    iverilog -g2012 -gstrict-expr-width -s tb_adders \
        -Ptb_adders.W="$width" -Ptb_adders.B="$block" \
        -o "build/$tag/sim" "${sources[@]}" tb_adders.sv
    (cd "build/$tag"; vvp -n sim) | tee "build/$tag/result.log"
    yosys -Q -T -p "read_verilog ${sources[*]} adder_miter.v; chparam -set W $width -set B $block adder_miter; hierarchy -check -top adder_miter; proc; flatten; opt; check -assert; select -assert-none t:\$dlatch; sat -verify -timeout 60 -set-def-inputs -prove ok 1 -show-inputs" > "build/$tag/formal.log" 2>&1
    grep -q 'SUCCESS' "build/$tag/formal.log"
    echo "PASS formal W=$width B=$block all binary inputs"
done
echo "PASS Adders: 8 configurations, RTL lint + simulation + combinational proof"
