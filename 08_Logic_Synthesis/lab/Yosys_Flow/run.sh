#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run.sh
#   1. Verilator lint
#   2. RTL 仿真（自检查）
#   3. 逐步综合（面积优先）→ reports/step*.stat，网表 build/alu_netlist.v
#   4. 门级仿真：同一个 TB 跑网表 + Sky130 单元模型
#   5. OpenSTA 看时序
#   6. 时序驱动映射（ABC -D）对比面积与 WNS
set -euo pipefail
cd "$(dirname "$0")"

PDK=/root/micromamba/envs/orfs/share/pdk/sky130A/libs.ref/sky130_fd_sc_hd
LIB=${LIB:-$PDK/lib/sky130_fd_sc_hd__tt_025C_1v80.lib}
STA=${STA:-/root/micromamba/envs/orfs/bin/sta}

source /root/oss-cad-suite/environment
mkdir -p build reports
cp "$LIB" build/lib.lib

echo "==== 1. lint ===="
verilator --lint-only -Wall alu.v
echo "lint clean"

echo "==== 2. RTL 仿真 ===="
iverilog -g2012 -o build/rtl_sim alu.v tb_alu.v
vvp -n build/rtl_sim | tee reports/rtl_sim.log

echo "==== 3. 逐步综合（面积优先）===="
yosys -q -l reports/synth.log -c synth.tcl
for s in step1_rtl step2_coarse step3_generic step4_mapped; do
  echo "-- $s: $(awk '/ cells$/{print $1; exit}' reports/$s.stat) cells"
done
grep -E 'Chip area|sequential' reports/step4_mapped.stat

echo "==== 4. 门级仿真（网表 + Sky130 功能模型）===="
# FUNCTIONAL：单元模型不带 specify 延时；UNIT_DELAY：每个单元 #1，便于看出网表是真的门
iverilog -g2012 -DGLS -DFUNCTIONAL -DUNIT_DELAY=#1 -o build/gls_sim \
  "$PDK/verilog/primitives.v" "$PDK/verilog/sky130_fd_sc_hd.v" \
  build/alu_netlist.v tb_alu.v
vvp -n build/gls_sim | tee reports/gls_sim.log

echo "==== 5. STA（面积优先网表，4 ns）===="
"$STA" -no_init -exit sta.tcl > reports/sta_area.rpt
grep -E 'slack \(|^wns|^tns|^worst' reports/sta_area.rpt

echo "==== 6. 时序驱动映射：扫 ABC 延时目标 ===="
printf "%-10s %10s %8s %10s\n" mapping area_um2 cells setup_ws
summary() {   # $1 名称  $2 stat 文件  $3 STA 报告
  local area cells ws
  area=$(awk '/Chip area/{print $NF}' "$2")
  cells=$(awk '/ cells$/{print $1; exit}' "$2")
  ws=$(awk '/^worst slack/{print $3; exit}' "$3")
  printf "%-10s %10.1f %8s %10s\n" "$1" "$area" "$cells" "$ws"
}
summary area reports/step4_mapped.stat reports/sta_area.rpt
for d in 4000 3000 2500 2000; do
  ABC_D=$d TAG=_D$d yosys -q -l reports/synth_D$d.log -c synth.tcl
  NETLIST=build/alu_netlist_D$d.v "$STA" -no_init -exit sta.tcl > reports/sta_D$d.rpt
  summary "D=$d" reports/step4_mapped_D$d.stat reports/sta_D$d.rpt
done

echo "波形: $(pwd)/alu.vcd  →  gtkwave alu.vcd"
