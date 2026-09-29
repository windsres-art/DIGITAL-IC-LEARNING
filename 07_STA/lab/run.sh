#!/usr/bin/env bash
# 在 WSL（root，工具装在 /root 下）里运行：bash run.sh
# 可选环境变量：
#   CLK_W_PERIOD / CLK_R_PERIOD  覆盖时钟周期（ns），例如收紧到 1.0 看违例
#   NO_CLOCK_GROUPS=1            不声明异步时钟组，观察跨域路径被误分析
set -euo pipefail
cd "$(dirname "$0")"

LIB=${LIB:-/root/micromamba/envs/orfs/share/pdk/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib}
STA=${STA:-/root/micromamba/envs/orfs/bin/sta}

source /root/oss-cad-suite/environment
mkdir -p build reports
cp "$LIB" build/lib.lib

yosys -q -l reports/synth.log synth.ys
"$STA" -no_init -exit sta.tcl | tee reports/sta.rpt
