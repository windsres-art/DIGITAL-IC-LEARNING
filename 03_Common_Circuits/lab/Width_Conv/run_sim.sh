#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
# 学习版保留直接的整数常量写法；仅略过已审查的扩展/截断提示。
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

verilator --lint-only -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC width_up.v
verilator --lint-only -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC width_down.v
verilator --lint-only -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -GIN_W=24 -GOUT_W=32 width_gearbox.v
verilator --lint-only -Wall -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -GIN_W=32 -GOUT_W=24 width_gearbox.v

echo "===== tb_width_conv ====="
# 环回实验中间的缓冲复用第 13 节的 skid_buffer
iverilog -g2012 -o width_conv_sim width_up.v width_down.v width_gearbox.v \
    ../Pipeline_Skid/skid_buffer.v tb_width_conv.v
vvp -n width_conv_sim
echo "波形: width_conv.vcd"
