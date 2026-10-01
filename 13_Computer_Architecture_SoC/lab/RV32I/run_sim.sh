#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
#   1 汇编器与 GNU as 逐字比对（没装 binutils-riscv64-unknown-elf 时跳过）
#   2 每个程序：汇编 → ISS 生成参考轨迹 → 单周期核 lockstep 仿真
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

PROGS="isa_test sort fib hazards branchy"
RTL="rv32i_decode.v rv32i_alu.v rv32i_branch.v rv32i_lsu.v rv32i_regfile.v rv32i_single.v"

verilator --lint-only -Wall --top-module rv32i_single $RTL

echo "===== 汇编器交叉检查 ====="
python3 asm_crosscheck.py programs/*.s

mkdir -p build
iverilog -g2012 -o build/single_sim $RTL tb_rv32i_single.v
for p in $PROGS; do
  echo "===== $p ====="
  python3 rv32_asm.py programs/$p.s -o build/$p
  python3 rv32_iss.py build/$p --trace build/$p.trace.hex
  vvp -n build/single_sim +prog=build/$p | grep -av -e 'VCD info' -e 'finish called'
done
echo "波形: rv32i_single.vcd（最后一个程序）；反汇编对照: build/<程序>.lst"
