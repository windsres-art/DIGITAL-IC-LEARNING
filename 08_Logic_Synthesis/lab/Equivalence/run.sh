#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run.sh
#   1. 等价性检查：RTL vs 面积优先网表、RTL vs 时序驱动网表（结构差很多，功能应相同）
#   2. 往网表里注入一个 bug（把一个 nand2 换成 nor2），看形式验证和仿真谁能抓到
#   3. check_design：用 Yosys check 和 Verilator lint 检查 bad_design.v
# 前置：../Yosys_Flow/run.sh 生成的网表（没有就自动先跑）
set -euo pipefail
cd "$(dirname "$0")"

PDK=/root/micromamba/envs/orfs/share/pdk/sky130A/libs.ref/sky130_fd_sc_hd
LIB=${LIB:-$PDK/lib/sky130_fd_sc_hd__tt_025C_1v80.lib}
FLOW=../Yosys_Flow

source /root/oss-cad-suite/environment
mkdir -p build reports
cp "$LIB" build/lib.lib
[[ -f $FLOW/build/alu_netlist.v && -f $FLOW/build/alu_netlist_D2000.v ]] || bash $FLOW/run.sh > /dev/null

lec() {   # lec <名称> <网表>
  GATE=$2 yosys -q -l reports/lec_$1.log -c equiv.tcl > /dev/null 2>&1 || true
  echo "-- $1: $(grep -E 'Found [0-9]+ \$equiv cells' reports/lec_$1.log | tail -1 | xargs)"
  grep -E 'Of those cells|Equivalence successfully|Trying to prove|unproven:' reports/lec_$1.log \
    | grep -vE 'Trying' | tail -3 | sed 's/^/     /'
}

echo "==== 1. 等价性检查 ===="
lec area  $FLOW/build/alu_netlist.v
lec D2000 $FLOW/build/alu_netlist_D2000.v
echo "   两份网表的单元数：$(grep -c 'sky130_fd_sc_hd__' $FLOW/build/alu_netlist.v) vs $(grep -c 'sky130_fd_sc_hd__' $FLOW/build/alu_netlist_D2000.v)"

echo "==== 2. 注入 bug：第一个 nand2_1 换成 nor2_1 ===="
sed '0,/sky130_fd_sc_hd__nand2_1 /s//sky130_fd_sc_hd__nor2_1 /' $FLOW/build/alu_netlist.v > build/alu_bug.v
ln=$(grep -n -m1 'sky130_fd_sc_hd__nand2_1 ' $FLOW/build/alu_netlist.v | cut -d: -f1)
echo "   第 $ln 行 原：$(sed -n "${ln}p" $FLOW/build/alu_netlist.v | xargs)"
echo "   第 $ln 行 改：$(sed -n "${ln}p" build/alu_bug.v | xargs)"
lec bug build/alu_bug.v
echo "   equiv_status 列出的未证明比较点："
awk '/EQUIV_STATUS/{f=1} f && /Unproven/' reports/lec_bug.log | head -5 | sed 's/^/     /'

echo "   同一个 bug 网表跑门级仿真（2000 个随机向量）："
iverilog -g2012 -DGLS -DFUNCTIONAL -DUNIT_DELAY=#1 -o build/gls_bug \
  "$PDK/verilog/primitives.v" "$PDK/verilog/sky130_fd_sc_hd.v" build/alu_bug.v $FLOW/tb_alu.v
(cd build && vvp -n gls_bug | grep -E 'PASS|FAIL' | sed 's/^/     /')

echo "==== 3. check_design ===="
echo "-- Yosys check："
yosys -q -l reports/check.log -p "read_verilog bad_design.v; hierarchy -top bad_design; proc; check" \
  > /dev/null 2>&1 || true
grep -E 'Warning|Latch|latch|problems' reports/check.log | sed 's/^/     /'
echo "-- Verilator lint："
verilator --lint-only -Wall bad_design.v 2>&1 | grep -E '^%(Warning|Error)-' | sed 's/^/     /' || true
