#!/usr/bin/env bash
set -euo pipefail
source /root/oss-cad-suite/environment
cd "$(dirname "$0")"
mkdir -p build
sby -f -d build/prove channel.sby prove > build/prove.log 2>&1
sby -f -d build/cover channel.sby cover > build/cover.log 2>&1
grep 'DONE' build/prove.log
grep 'DONE' build/cover.log
# 同一个 RTL 经综合优化后的逐状态等价；初始未复位状态也不随意置零。
yosys -Q -T -p 'read_verilog ../Handshake/elastic_alu.v; prep -top elastic_alu; rename elastic_alu gold; design -stash reference; read_verilog ../Handshake/elastic_alu.v; synth -top elastic_alu; rename elastic_alu gate; design -copy-from reference gold; equiv_make gold gate equiv; hierarchy -top equiv; async2sync; equiv_simple; equiv_induct -seq 4; equiv_status -assert' > build/equivalence.log
echo "PASS formal W=4 safety induction + 2 covers; RTL/netlist equivalence W=8"
