#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

RTL="prio_enc.v decoder.v onehot2bin.v mux_bin.v mux_onehot.v mux_latch_fixed.v"
for f in $RTL; do
  verilator --lint-only -Wall "$f"
done

echo "===== Verilator lint: mux_latch_bad.v（预期报 LATCH）====="
verilator --lint-only -Wall mux_latch_bad.v 2>&1 | grep -E '%Warning-LATCH' || true

echo "===== Yosys: latch 统计 ====="
for m in mux_latch_bad mux_latch_fixed; do
  rpt=$(yosys -p "read_verilog $m.v; proc; opt; stat" | sed -n "/=== $m ===/,\$p")
  total=$(echo "$rpt" | awk '/ cells$/{print $1; exit}')
  latch=$(echo "$rpt" | awk '/\$dlatch/{print $1; exit}')
  echo "$m: total cells = $total, \$dlatch = ${latch:-0}"
done

echo "===== tb_enc_dec_mux ====="
iverilog -g2012 -o enc_dec_mux_sim $RTL mux_latch_bad.v tb_enc_dec_mux.v
vvp -n enc_dec_mux_sim
echo "波形: enc_dec_mux.vcd"
