#!/usr/bin/env bash
# 变异测试：两个转换器的 in_ready 都改成"只在空的时候收"，看满速吞吐掉多少。bash mutation.sh
#   M1 width_up   in_ready = ~out_valid              （宽字被取走那一拍不能收新窄字）
#   M2 width_down in_ready = ~out_valid              （最后一个窄字送完之后才收下一个宽字）
# 变异文件写到 build_mut/，不改原 RTL
set -uo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment

mkdir -p build_mut

echo "===== M1: width_up in_ready = ~out_valid ====="
sed "s/assign in_ready = ~out_valid | out_ready;/assign in_ready = ~out_valid;/" width_up.v > build_mut/up_m1.v
iverilog -g2012 -o build_mut/m1 build_mut/up_m1.v width_down.v width_gearbox.v \
    ../Pipeline_Skid/skid_buffer.v tb_width_conv.v
vvp -n build_mut/m1 | grep -E 'config|packets|PASS|FAIL|ERROR'

echo "===== M2: width_down in_ready = ~out_valid ====="
sed "s/assign in_ready  = ~out_valid | (out_ready & ~more);/assign in_ready  = ~out_valid;/" width_down.v > build_mut/dn_m2.v
iverilog -g2012 -o build_mut/m2 width_up.v build_mut/dn_m2.v width_gearbox.v \
    ../Pipeline_Skid/skid_buffer.v tb_width_conv.v
vvp -n build_mut/m2 | grep -E 'config|packets|PASS|FAIL|ERROR'
