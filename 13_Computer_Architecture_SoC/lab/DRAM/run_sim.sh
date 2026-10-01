#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
#   1 verilator lint：4 种地址映射 × 开 / 关页 × 前瞻开 / 关
#   2 延迟探针：7 个间隔足够大的读，延迟必须正好等于公式
#   3 实验矩阵：4 种映射 × 2 种页策略 × 3 种负载，每次都由 dram_model 检查全部时序、
#     比对读数据，并用 dram_sim.py 独立复算 行命中 / 行空 / 行冲突 计数
#   4 前瞻（lookahead）开关对比
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

lint() { local o; o=$(verilator --lint-only -Wall "$@" dram_ctrl.v 2>&1) || { echo "$o"; exit 1; }; }
for m in 0 1 2 3; do for o in 0 1; do for l in 0 1; do
  lint -GMAP=$m -GOPEN_PAGE=$o -GLOOKAHEAD=$l
done; done; done
for q in 2 8 16; do lint -GQD=$q; done
echo "lint: 19 种参数组合 0 warning"

mkdir -p build
N=${N:-4000}
names=(RBC BRC XOR LINE)
pols=(close open)

build() {   # MAP OPEN LA [QD]
  iverilog -g2012 -P tb_dram.MAP=$1 -P tb_dram.OPEN_PAGE=$2 -P tb_dram.LOOKAHEAD=$3 -P tb_dram.QD=${4:-4} \
           -o build/m$1_o$2_l$3${4:+_q$4} tb_dram.v dram_ctrl.v dram_model.v
}

run() {     # MAP OPEN LA WL [QD]
  local exe=build/m$1_o$2_l$3${5:+_q$5} tr=build/m$1_o$2_l$3_$4.txt out s
  [ -n "${5:-}" ] && printf "QD=%-3s" $5
  out=$(vvp -n $exe +wl=$4 +n=$N +trace=$tr | grep -av -e 'VCD info' -e 'finish called')
  if ! echo "$out" | grep -q '^PASS'; then echo "$out"; exit 1; fi
  s=($(echo "$out" | sed -n 's/^SUMMARY //p'))
  py=$(python3 dram_sim.py $tr --map $1 --open $2 --expect "${s[0]},${s[1]},${s[2]}" | tail -1)
  printf "%-5s %-5s LA=%d %-8s hit=%5.1f%%  hit/empty/conf=%4d/%4d/%4d  ACT=%4d  BW=%5.2f GB/s  lat=%6.1f  PASS %s\n" \
    ${names[$1]} ${pols[$2]} $3 $4 ${s[3]} ${s[0]} ${s[1]} ${s[2]} ${s[6]} ${s[4]} ${s[5]} "$py"
  [ "$py" = "MATCH" ]
}

echo "===== 延迟探针（MAP=RBC，开页 / 关页）====="
build 0 1 1; vvp -n build/m0_o1_l1 +wl=lat | grep -av -e 'VCD info' -e 'finish called'
build 0 0 1; vvp -n build/m0_o0_l1 +wl=lat | grep -av -e 'VCD info' -e 'finish called' | tail -2

echo "===== 实验矩阵（每次 $N 个请求，峰值 6.40 GB/s，lat 为平均读延迟/拍）====="
for wl in seq rand streams; do
  for m in 0 1 2 3; do for o in 1 0; do
    [ -x build/m${m}_o${o}_l1 ] || build $m $o 1
    run $m $o 1 $wl
  done; done
done

echo "===== 前瞻：younger 请求能否提前 PRE/ACT ====="
for cfg in "0 1 rand" "3 0 seq" "2 1 streams"; do
  set -- $cfg
  build $1 $2 0
  run $1 $2 0 $3
  run $1 $2 1 $3
done

echo "===== 队列深度：按序分类时，加深队列只加延迟、不加带宽 ====="
for q in 2 4 16; do
  build 0 1 1 $q
  run 0 1 1 rand $q
done
echo "波形: dram.vcd（最后一次运行）"
