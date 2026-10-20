#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
python3 generate_vectors.py | tee build/reference.log
for config in "1 1 0 0" "4 3 2 1" "8 4 4 2" "8 4 4 0" "8 4 2 2" "8 12 0 4" "8 4 0 3" "16 8 12 4"; do
    read -r iw ow inf outf <<< "$config"
    dir="build/${iw}_${ow}_${inf}_${outf}"
    verilator --lint-only -Wall --top-module fixed_quantize -GIW="$iw" -GOW="$ow" -GIF="$inf" -GOF="$outf" fixed_quantize.v > "$dir/lint.log" 2>&1
    yosys -Q -T -p "read_verilog fixed_quantize.v; chparam -set IW $iw -set OW $ow -set IF $inf -set OF $outf fixed_quantize; hierarchy -check -top fixed_quantize; proc; opt; check -assert; select -assert-none t:\$dlatch" > "$dir/synth.log" 2>&1
    iverilog -g2012 -gstrict-expr-width -s tb_fixed -Ptb_fixed.IW="$iw" -Ptb_fixed.OW="$ow" -Ptb_fixed.IF="$inf" -Ptb_fixed.OF="$outf" -o "$dir/sim" fixed_quantize.v tb_fixed.sv
    (cd "$dir"; vvp -n sim) | tee "$dir/sim.log"
done
verilator --lint-only -Wall --top-module fp32_classify fp32_classify.v > build/fp32_lint.log 2>&1
yosys -Q -T -p 'read_verilog fp32_classify.v; hierarchy -check -top fp32_classify; proc; opt; check -assert; select -assert-none t:$dlatch' > build/fp32_synth.log 2>&1
iverilog -g2012 -gstrict-expr-width -s tb_fp32 -o build/fp32 fp32_classify.v tb_fp32.sv
(cd build; vvp -n fp32) | tee build/fp32.log
