#!/usr/bin/env bash
# 对比实验（先跑过 run.sh 生成网表）：bash run_experiments.sh
set -euo pipefail
cd "$(dirname "$0")"
STA=${STA:-/root/micromamba/envs/orfs/bin/sta}

echo "#### 实验1：把 clk_r 收紧到 3.0 ns，观察 setup 违例"
CLK_R_PERIOD=3.0 "$STA" -no_init -exit sta_summary.tcl | tee reports/exp1_tight_clock.rpt

echo "#### 实验2：不声明异步时钟组，观察跨时钟域路径被当成同步路径分析"
NO_CLOCK_GROUPS=1 "$STA" -no_init -exit sta_summary.tcl | tee reports/exp2_no_clock_groups.rpt
