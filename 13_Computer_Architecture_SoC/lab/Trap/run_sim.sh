#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
#   1 verilator lint（核、CLINT、PLIC、DMA）
#   2 汇编器与 GNU as 逐字比对（含 Zicsr / mret / wfi）
#   3 每个程序跑两遍：无等待 / 随机等待周期；日志交给 trap_iss.py 逐条复核
#   4 DMA 单独的 testbench
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment
CORE="rv32i_trap.v ../RV32I/rv32i_decode.v ../RV32I/rv32i_alu.v ../RV32I/rv32i_branch.v ../RV32I/rv32i_lsu.v ../RV32I/rv32i_regfile.v"

lint() { local o; o=$(verilator --lint-only -Wall "$@" 2>&1) || { echo "$o"; exit 1; }; }
lint $CORE --top-module rv32i_trap
lint clint.v; lint -GDIV=4 clint.v; lint plic.v
[ -f dma.v ] && lint dma.v
echo "lint: 0 warning"

mkdir -p build
PROGS=${PROGS:-"trap_test irq_test plic_test"}
for p in $PROGS; do python3 ../RV32I/rv32_asm.py programs/$p.s -o build/$p; done
python3 ../RV32I/asm_crosscheck.py $(for p in $PROGS; do echo programs/$p.s; done)

iverilog -g2012 -o build/tb_trap tb_trap.v clint.v plic.v $CORE
for p in $PROGS; do
  for ws in 0 1; do
    echo "===== $p ws=$ws ====="
    vvp -n build/tb_trap +prog=build/$p +log=build/$p.ws$ws.log +ws=$ws | grep -av -e 'VCD info' -e 'finish called'
    python3 trap_iss.py build/$p build/$p.ws$ws.log
  done
done

if [ -f tb_dma.v ]; then
  echo "===== DMA ====="
  iverilog -g2012 -o build/tb_dma tb_dma.v dma.v
  vvp -n build/tb_dma | grep -av -e 'VCD info' -e 'finish called'
fi
