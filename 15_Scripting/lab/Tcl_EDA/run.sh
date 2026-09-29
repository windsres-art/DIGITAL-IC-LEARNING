#!/usr/bin/env bash
# 在 WSL（root，工具装在 /root 下）里运行：bash run.sh
#   1. tclsh 跑纯 Tcl 语法自检
#   2. Yosys Tcl 模式综合 ALU → build/alu_netlist.v、reports/synth.stat
#   3. OpenSTA 用集合查询网表与时序 → reports/sta_query.log、endpoint_slack.csv、sta_paths.rpt
# 可选环境变量：PERIOD（时钟周期 ns，默认 3.0）
set -euo pipefail
cd "$(dirname "$0")"

ORFS=/root/micromamba/envs/orfs
LIB=${LIB:-$ORFS/share/pdk/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib}

source /root/oss-cad-suite/environment
mkdir -p build reports
cp "$LIB" build/lib.lib

echo "==== 1. Tcl 语法自检 ===="
"$ORFS/bin/tclsh" tcl_basics.tcl

echo "==== 2. Yosys（Tcl 模式）综合 ALU ===="
yosys -q -l reports/synth.log -c synth.tcl
grep -E ' cells$|Chip area' reports/synth.stat

echo "==== 3. OpenSTA 集合查询 ===="
"$ORFS/bin/sta" -no_init -no_splash -exit sta_query.tcl | tee reports/sta_query.log
