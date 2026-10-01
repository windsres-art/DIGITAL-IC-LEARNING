#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
#   五种配置的 RTL 仿真（每种 20000 个随机请求 + 全范围读回），
#   每种配置再用 cache_sim.py 重放同一请求序列，独立复算命中 / 缺失 / 写回次数；
#   最后跑第 3 节的几组模拟实验。
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

for cfg in "16 2 4 1" "1 8 4 1" "32 1 4 1" "8 4 4 0"; do
  set -- $cfg
  verilator --lint-only -Wall -GSETS=$1 -GWAYS=$2 -GLINE_WORDS=$3 -GWRITE_BACK=$4 cache.v
done

mkdir -p build
# SETS WAYS LINE_WORDS WRITE_BACK —— 容量都是 512 B
for cfg in "32 1 4 1" "16 2 4 1" "8 4 4 1" "1 32 4 1" "8 4 4 0"; do
  set -- $cfg
  name="s$1_w$2_l$3_wb$4"
  echo "===== SETS=$1 WAYS=$2 LINE_WORDS=$3 WRITE_BACK=$4 ====="
  iverilog -g2012 -P tb_cache.SETS=$1 -P tb_cache.WAYS=$2 -P tb_cache.LINE_WORDS=$3 \
           -P tb_cache.WRITE_BACK=$4 -o build/$name cache.v tb_cache.v
  out=$(vvp -n build/$name +trace=build/$name.trace.txt | grep -av -e 'VCD info' -e 'finish called')
  echo "$out"
  h=$(echo "$out" | sed -n 's/.*hits=\([0-9]*\).*/\1/p')
  m=$(echo "$out" | sed -n 's/.*misses=\([0-9]*\).*/\1/p')
  wb=$(echo "$out" | sed -n 's/.*writebacks=\([0-9]*\).*/\1/p')
  python3 cache_sim.py replay build/$name.trace.txt --sets $1 --ways $2 --line $((4 * $3)) \
          --wb $4 --expect "$h,$m,$wb"
done

echo "===== cache_sim.py 实验 ====="
python3 cache_sim.py experiments
echo "波形: cache.vcd（最后一种配置）"
