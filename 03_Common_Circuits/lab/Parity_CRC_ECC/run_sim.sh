#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

for f in parity.v crc_serial.v crc_parallel.v; do
  verilator --lint-only -Wall "$f"
done
for dw in 8 32 64; do
  verilator --lint-only -Wall -GDW=$dw ecc_secded_enc.v
  verilator --lint-only -Wall -GDW=$dw ecc_secded_dec.v
done

echo "===== tb_crc：奇偶校验 + CRC ====="
iverilog -g2012 -o crc_sim parity.v crc_serial.v crc_parallel.v tb_crc.v
vvp -n crc_sim

echo "===== tb_ecc：SECDED 汉明码 ====="
iverilog -g2012 -o ecc_sim ecc_secded_enc.v ecc_secded_dec.v tb_ecc.v
vvp -n ecc_sim
echo "波形: crc.vcd / ecc.vcd"
