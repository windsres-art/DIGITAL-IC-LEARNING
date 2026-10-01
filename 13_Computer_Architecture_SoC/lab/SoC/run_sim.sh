#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
#   1 verilator lint（总线、APB 桥、UART、整个 SoC）
#   2 汇编 hello.s，与 GNU as 逐字比对
#   3 SoC 仿真跑 3 个随机种子（RAM / 寄存器堆上电内容不同）；每次的日志交给 trap_iss.py 复核
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment
CORE="../Trap/rv32i_trap.v ../RV32I/rv32i_decode.v ../RV32I/rv32i_alu.v ../RV32I/rv32i_branch.v ../RV32I/rv32i_lsu.v ../RV32I/rv32i_regfile.v"
PERI="../Trap/clint.v ../Trap/plic.v ../Trap/dma.v"
SOC="soc_top.v soc_bus.v apb_bridge.v uart_tx.v"

lint() { local o; o=$(verilator --lint-only -Wall "$@" 2>&1) || { echo "$o"; exit 1; }; }
lint soc_bus.v; lint apb_bridge.v; lint uart_tx.v; lint -GFD=8 uart_tx.v
lint $SOC $PERI $CORE --top-module soc_top
echo "lint: 0 warning"

mkdir -p build
python3 ../RV32I/rv32_asm.py programs/hello.s -o build/hello
python3 ../RV32I/asm_crosscheck.py programs/hello.s

iverilog -g2012 -o build/tb_soc tb_soc.v $SOC $PERI $CORE
for seed in ${SEEDS:-1 2 3}; do
  echo "===== hello seed=$seed ====="
  vvp -n build/tb_soc +prog=build/hello +log=build/hello.s$seed.log +expect=programs/hello.expect \
      +seed=$seed | grep -av -e 'VCD info' -e 'finish called'
  python3 ../Trap/trap_iss.py build/hello build/hello.s$seed.log --map soc
done
