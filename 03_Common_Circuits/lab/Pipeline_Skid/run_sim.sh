#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run_sim.sh
set -euo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

verilator --lint-only -Wall skid_buffer.v
verilator --lint-only -Wall -GMODE=0 pipe_mac.v
verilator --lint-only -Wall -GMODE=1 pipe_mac.v

echo "===== tb_pipeline_skid ====="
iverilog -g2012 -o pipeline_skid_sim skid_buffer.v pipe_mac.v tb_pipeline_skid.v
vvp -n pipeline_skid_sim
echo "波形: pipeline_skid.vcd"

# ready 路径长度：N 级串联后综合成通用门，ltp -noff 报告最长组合路径（门级数）
echo "===== Yosys: longest combinational path (ltp -noff) ====="
for kind in 0 1; do
    name=$([ "$kind" = 0 ] && echo "hs_stage_pipe" || echo "skid_buffer  ")
    for n in 2 4 8 16; do
        len=$(yosys -q -p "read_verilog ../Handshake/hs_stage_pipe.v skid_buffer.v ready_chain.v; \
                          chparam -set KIND $kind -set N $n ready_chain; \
                          synth -flatten -top ready_chain; abc -g AND,OR,XOR,MUX; opt_clean; \
                          tee -o /dev/stdout ltp -noff" \
              | grep -o 'length=[0-9]*' | head -1)
        echo "$name N=$n  $len"
    done
done
