#!/usr/bin/env bash
# 在 WSL 里运行：bash run.sh
# 解析 ../Tcl_EDA 生成的报告；报告不存在时先跑那边的 run.sh
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f ../Tcl_EDA/reports/sta_paths.rpt ]]; then
  echo "没有 ../Tcl_EDA/reports/sta_paths.rpt，先跑 Tcl_EDA/run.sh"
  bash ../Tcl_EDA/run.sh > /dev/null
fi

python3 parse_sta.py "$@"
