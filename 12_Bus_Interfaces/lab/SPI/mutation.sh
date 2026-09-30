#!/usr/bin/env bash
# 变异测试：注入两个典型错误，确认 testbench 能抓到。bash mutation.sh
#   M1 从机在 CPHA=1 的第一个前沿也移位（第一位被提前移走，MISO 错一位）
#   M2 主机把采样沿和移位沿弄反
# 变异文件写到 build_mut/，不改原 RTL；每个变异都应该打印 FAIL
set -uo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment
mkdir -p build_mut

run() {  # $1 名称  $2 master  $3 slave
  iverilog -g2012 -o "build_mut/$1" "$2" "$3" tb_spi.v
  vvp -n "build_mut/$1" | awk '/ERROR/ && n < 2 {print; n++} /^P1 mode|PASS|FAIL/ {print}'
}

echo "===== M1: 从机 CPHA=1 第一个前沿也移位 ====="
sed 's/if (shift_e \&\& nsamp != 4'"'"'d0 \&\& nsamp != 4'"'"'d8)/if (shift_e \&\& nsamp != 4'"'"'d8)/' spi_slave.v > build_mut/slave_m1.v
cmp -s build_mut/slave_m1.v spi_slave.v && echo "sed 没有匹配"
run m1 spi_master.v build_mut/slave_m1.v

echo "===== M2: 主机采样沿/移位沿对调 ====="
sed 's/wire samp_e  = cpha ? ~leading :  leading;/wire samp_e  = cpha ?  leading : ~leading;/' spi_master.v > build_mut/master_m2.v
cmp -s build_mut/master_m2.v spi_master.v && echo "sed 没有匹配"
run m2 build_mut/master_m2.v spi_slave.v
