#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
#   程序、汇编器、ISS 与共用 RTL 部件都在 ../RV32I。
#   每个程序 × 4 种配置：(FWD,BP) = (1,0) (0,0) (1,1) (1,2)
#   前三种配置还要求实测周期数等于 ISS 时序模型（rv32_iss.py --pipe）的预测。
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

R=../RV32I
PROGS="isa_test sort fib hazards branchy"
RTL="$R/rv32i_decode.v $R/rv32i_alu.v $R/rv32i_branch.v $R/rv32i_lsu.v $R/rv32i_regfile.v rv32i_pipe.v"

for bp in 0 1 2; do
  for fwd in 1 0; do
    verilator --lint-only -Wall --top-module rv32i_pipe -GFWD=$fwd -GBP=$bp $RTL
  done
done

mkdir -p build $R/build
for cfg in "1 0" "0 0" "1 1" "1 2"; do
  set -- $cfg
  iverilog -g2012 -P tb_rv32i_pipe.FWD=$1 -P tb_rv32i_pipe.BP=$2 -o build/pipe_f$1_b$2 $RTL tb_rv32i_pipe.v
done

for p in $PROGS; do
  python3 $R/rv32_asm.py $R/programs/$p.s -o $R/build/$p > /dev/null
  model=$(python3 $R/rv32_iss.py $R/build/$p --trace $R/build/$p.trace.hex --pipe --quiet)
  echo "===== $p ====="
  for cfg in "1 0" "0 0" "1 1" "1 2"; do
    set -- $cfg
    exp=$(echo "$model" | awk -v f=$1 -v b=$2 '$2=="FWD="f && $3=="BP="b":" {sub("cycles=","",$4); print $4}')
    arg=""; [[ -n "$exp" ]] && arg="+exp_cycles=$exp"
    vvp -n build/pipe_f$1_b$2 +prog=$R/build/$p $arg | grep -a -E 'ERROR|PASS|FAIL|FWD='
  done
done
echo "波形: rv32i_pipe.vcd（最后一次运行）"
