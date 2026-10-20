#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source /root/oss-cad-suite/environment
mkdir -p build
# 此实验的 PASS 表示检测到指定错误，绝不是“坏 RTL 检查通过”。
yosys -Q -T -p 'read_verilog bad_examples.v; hierarchy -top bad_latch; proc; opt; select -assert-count 1 t:$dlatch' > build/latch.log
echo 'PASS detected latch: exactly one $dlatch'
if yosys -Q -T -p 'read_verilog bad_examples.v; hierarchy -top bad_multidriver; proc; check -assert' > build/multidriver.log 2>&1; then
    echo "FAIL multiple drivers escaped"; exit 1
fi
grep -q 'multiple conflicting drivers' build/multidriver.log
echo "PASS rejected multiple conflicting drivers"
if verilator --lint-only -Wall -Wno-DECLFILENAME --top-module bad_loop bad_examples.v > build/loop.log 2>&1; then
    echo "FAIL loop escaped"; exit 1
fi
grep -q 'UNOPTFLAT' build/loop.log
echo "PASS detected combinational loop (UNOPTFLAT)"
yosys -Q -T -p 'read_verilog bad_examples.v; hierarchy -top bad_sensitivity; proc; opt; rename bad_sensitivity synthesized_sensitivity; write_verilog -noattr build/sensitivity_netlist.v' > build/sensitivity.log
iverilog -g2012 -gstrict-expr-width -s tb_pitfalls -o build/sim \
    bad_examples.v build/sensitivity_netlist.v tb_pitfalls.sv
(cd build; vvp -n sim) | tee build/result.log
echo "PASS Pitfalls: structural diagnostics + RTL/netlist mismatch + four-state cases"
