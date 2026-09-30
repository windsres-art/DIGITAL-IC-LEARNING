#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

verilator --lint-only -Wall uart_baud.v
verilator --lint-only -Wall uart_tx.v
for p in 0 1 2; do verilator --lint-only -Wall -GPARITY=$p uart_rx.v; done

# 8N1、8E1、8O2 三种帧格式
for cfg in "0 1" "2 1" "1 2"; do
  set -- $cfg
  echo "===== tb_uart：PARITY=$1 STOP=$2 ====="
  iverilog -g2012 -P tb_uart.PARITY=$1 -P tb_uart.STOP=$2 -o uart_sim uart_baud.v uart_tx.v uart_rx.v tb_uart.v
  vvp -n uart_sim | grep -v 'VCD info'
done
echo "波形: uart.vcd（最后一次运行，8O2）"
