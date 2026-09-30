#!/usr/bin/env bash
# 变异测试：往 RTL 里注入三个典型错误，确认 testbench 能抓到。bash mutation.sh
#   M1 W1C 冲突时清零优先（同拍硬件置位被软件清掉，丢中断）
#   M2 主机在 SETUP/等待期间就把下一条命令的地址数据放上总线
#   M3 从机在 SETUP 阶段就执行写（没看 PENABLE；零等待时 SETUP 拍 pready 也是 1）
# 变异文件写到 build_mut/，不改原 RTL；每个变异都应该打印 FAIL
set -uo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment
mkdir -p build_mut

run() {  # $1 名称  $2 master  $3 slave  $4 WAIT
  iverilog -g2012 -P tb_apb.WAIT="$4" -o "build_mut/$1" "$2" "$3" tb_apb.v
  vvp -n "build_mut/$1" | awk '/ERROR/ && n < 2 {print; n++} /PASS|FAIL/ {print}'
}

echo "===== M1: W1C 清零优先于硬件置位 ====="
sed 's/(int_stat & ~w1c) | irq_set_i/(int_stat | irq_set_i) \& ~w1c/' apb_regs.v > build_mut/regs_m1.v
run m1 apb_master.v build_mut/regs_m1.v 2

echo "===== M2: 主机提前改地址 ====="
sed 's/^        if (cmd_fire) begin/        if (cmd_valid) begin/' apb_master.v > build_mut/mst_m2.v
run m2 build_mut/mst_m2.v apb_regs.v 2

echo "===== M3: 从机在 SETUP 阶段写 ====="
sed 's/wire xfer   = access & pready;/wire xfer   = psel \& pready;/' apb_regs.v > build_mut/regs_m3.v
run m3 apb_master.v build_mut/regs_m3.v 0
