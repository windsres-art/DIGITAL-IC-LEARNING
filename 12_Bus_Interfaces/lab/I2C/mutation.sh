#!/usr/bin/env bash
# 变异测试：注入两个典型错误，确认 testbench 能抓到。bash mutation.sh
#   M1 主机不做仲裁检测（发 1 看到 0 也继续发）
#   M2 主机数据位不等 SCL 真正变高（忽略时钟拉伸）
# 变异文件写到 build_mut/，不改原 RTL；每个变异都应该打印 FAIL
set -uo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment
mkdir -p build_mut

run() {  # $1 名称  $2 master
  iverilog -g2012 -o "build_mut/$1" "$2" i2c_slave.v tb_i2c.v
  timeout 300 vvp -n "build_mut/$1" | awk '/ERROR/ && n < 2 {print; n++} /^P[12]|PASS|FAIL/ {print}'
}

echo "===== M1: 去掉仲裁检测 ====="
sed 's/else if (sh\[7\] \&\& !sda_s) begin/else if (1'"'"'b0) begin/' i2c_master.v > build_mut/master_m1.v
cmp -s build_mut/master_m1.v i2c_master.v && echo "sed 没有匹配"
run m1 build_mut/master_m1.v

echo "===== M2: 数据位忽略时钟拉伸 ====="
sed 's/B_B: if (!scl_s) tmr <= QM1;/B_B: if (1'"'"'b0) tmr <= QM1;/' i2c_master.v > build_mut/master_m2.v
cmp -s build_mut/master_m2.v i2c_master.v && echo "sed 没有匹配"
run m2 build_mut/master_m2.v
