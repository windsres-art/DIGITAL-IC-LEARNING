#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
for width in 4 8 16; do
    verilator --lint-only -Wall --top-module operand_isolation -GW="$width" operand_isolation.v > "build/lint_w$width.log" 2>&1
    yosys -Q -T -p "read_verilog operand_isolation.v; chparam -set W $width operand_isolation; hierarchy -check -top operand_isolation; proc; opt; check -assert; select -assert-none t:\$dlatch" > "build/synth_w$width.log" 2>&1
    iverilog -g2012 -gstrict-expr-width -s tb_activity -Ptb_activity.W="$width" -o build/activity operand_isolation.v tb_activity.sv
    (cd build; vvp -n activity) | tee "build/activity_w$width.log"
done
verilator --lint-only -Wall enable_bank.v > build/lint_bank.log 2>&1
verilator --lint-only -Wall icg_model.v > build/lint_icg.log 2>&1
yosys -Q -T -p 'read_verilog enable_bank.v; hierarchy -top enable_bank; proc; opt; clockgate -pos icg_model EN:CLK:GCLK -min_net_size 1; select -assert-count 1 t:icg_model; rename enable_bank enable_bank_gated; write_verilog -noattr build/enable_bank_gated.v' > build/clockgate.log 2>&1
iverilog -g2012 -s tb_clockgate -o build/clockgate enable_bank.v icg_model.v build/enable_bank_gated.v tb_clockgate.sv
(cd build; vvp -n clockgate) | tee build/clockgate_sim.log
