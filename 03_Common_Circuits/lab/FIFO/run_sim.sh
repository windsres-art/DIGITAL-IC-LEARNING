#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
# 环境说明见 ../../../../ascon-aead128-fast/README.md（OSS CAD Suite）

set -euo pipefail
cd "$(dirname "$0")"

if [[ -f /root/oss-cad-suite/environment ]]; then
  # shellcheck disable=SC1091
  source /root/oss-cad-suite/environment
elif [[ -f "$HOME/oss-cad-suite/environment" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/oss-cad-suite/environment"
else
  echo "找不到 oss-cad-suite，请先按 ascon README 安装并 source environment"
  exit 1
fi

verilator --lint-only -Wall fifo_sync.v
verilator --lint-only -Wall fifo_async.v

echo "===== tb_fifo_sync：同步 FIFO ====="
iverilog -g2012 -o fifo_sync_sim fifo_sync.v tb_fifo_sync.v
vvp -n fifo_sync_sim

echo "===== tb_fifo_async：异步 FIFO 自检查（fifo_async.v 与 FIFO.v）====="
iverilog -g2012 -o fifo_async_sim fifo_async.v FIFO.v tb_fifo_async.v
vvp -n fifo_async_sim

echo "===== FIFO_TB：早期演示 testbench（打印读写过程，不自检查）====="
iverilog -g2012 -o fifo_sim FIFO.v FIFO_TB.v
vvp -n fifo_sim

echo "===== fifo_depth.py：深度计算 ====="
python3 fifo_depth.py

echo "波形: fifo_sync.vcd / fifo_async_check.vcd / fifo_async.vcd"
