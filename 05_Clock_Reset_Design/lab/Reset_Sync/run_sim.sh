#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
#   1. Verilator lint
#   2. Icarus 仿真（自检查，打印 PASS/FAIL）
#   3. Yosys 综合到 Sky130，单元统计写到 reports/*.stat
set -euo pipefail
cd "$(dirname "$0")"

LIB=${LIB:-/root/micromamba/envs/orfs/share/pdk/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib}

source /root/oss-cad-suite/environment
mkdir -p build reports
cp "$LIB" build/lib.lib

verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-MULTITOP reset_sync.v reset_styles.v
iverilog -g2012 -o reset_sim reset_sync.v reset_styles.v tb_reset_sync.v
vvp -n reset_sim
echo "波形: $(pwd)/reset_sync.vcd  →  gtkwave reset_sync.vcd"

yosys -q -l reports/synth.log synth_reset.ys
for f in reg_sync_rst reg_async_rst reset_sync; do
  echo "== $f =="
  grep -E 'sky130_fd_sc_hd__|Chip area' "reports/$f.stat"
done
