#!/usr/bin/env bash
# 变异测试：注入两个典型错误，确认 testbench 能抓到。bash mutation.sh
#   M1 每位只采一次（去掉三取二多数表决）→ 毛刺直接变成错位
#   M2 在位的开头（第 1~3 个 tick）而不是中心采样 → 波特率容限和假起始过滤都变差
# 变异文件写到 build_mut/，不改原 RTL；每个变异都应该打印 FAIL
set -uo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment
mkdir -p build_mut

run() {  # $1 名称  $2 变异后的 uart_rx
  if cmp -s "$2" uart_rx.v; then echo "sed 没有匹配"; return; fi
  iverilog -g2012 -o "build_mut/$1" uart_baud.v uart_tx.v "$2" tb_uart.v
  vvp -n "build_mut/$1" | awk '/ERROR/ && n < 2 {print; n++} /offset|P3|P4|PASS|FAIL/ {print}'
}

echo "===== M1: 单点采样 ====="
sed 's/wire maj = (smp\[1\] & smp\[0\]) | (smp\[1\] & rx_s) | (smp\[0\] & rx_s);/wire maj = smp[0];/' uart_rx.v > build_mut/rx_m1.v
run m1 build_mut/rx_m1.v

echo "===== M2: 在位开头采样 ====="
sed -e "s/ovs == 4'd7 || ovs == 4'd8/ovs == 4'd1 || ovs == 4'd2/" -e "s/if (ovs == 4'd9) begin/if (ovs == 4'd3) begin/" uart_rx.v > build_mut/rx_m2.v
run m2 build_mut/rx_m2.v
