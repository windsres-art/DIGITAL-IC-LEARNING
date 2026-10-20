#!/usr/bin/env bash
set -euo pipefail
source /root/oss-cad-suite/environment
cd "$(dirname "$0")"
mkdir -p build
for w in 1 8 13; do
  verilator --lint-only -Wall --top-module elastic_alu -GW="$w" elastic_alu.v
  yosys -Q -T -p "read_verilog elastic_alu.v; chparam -set W $w elastic_alu; prep -top elastic_alu; check -assert; select -assert-none t:\$dlatch" > "build/yosys_${w}.log"
  iverilog -g2012 -s tb_channel -Ptb_channel.W="$w" -o build/sim elastic_alu.v tb_channel.sv
  for seed in 1 17 2026; do
    (cd build; vvp sim +SEED="$seed") | tee "build/run_${w}_${seed}.log"
  done
done
