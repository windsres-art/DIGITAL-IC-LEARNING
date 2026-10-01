#!/usr/bin/env bash
# 变异测试：注入八个 DRAM 控制器典型 bug，确认 dram_model 的检查器 / 数据比对能抓到。bash mutation.sh
#   M1 tRCD 少算一拍                        —— ACT 后过早发 RD/WR
#   M2 不刷新                               —— 数据全对，只有刷新间隔检查能抓
#   M3 判断行命中时不比较行号               —— 读写到错误的行（时序全合法，只有数据比对能抓）
#   M4 写数据晚一拍上总线                   —— 违反 tCWL
#   M5 不检查 tFAW                          —— 只有 ACT 密集的负载（关页 + 行交织顺序流）才会触发
#   M6 读后写不等总线换向                   —— 读写数据在 DQ 上冲突
#   M7 刷新前不预充电所有 bank
#   M8 带自动预充电的写只按 tRTP 算         —— 忽略 tWR：写数据还没写进阵列就关行
# 每个变异跑三种配置：开页 RBC 随机读写 / 关页 LINE 顺序读 / 关页 RBC 随机读写，
# 任何一种 FAIL 即判为"抓到"。变异文件写到 build_mut/，不改原 RTL
set -uo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment
mkdir -p build_mut

run() {  # $1 名称  $2 变异后的 dram_ctrl.v
  if cmp -s "$2" dram_ctrl.v; then echo "sed 没有匹配"; return; fi
  local cfg res killed=0
  for cfg in "0 1 rand" "3 0 seq" "0 0 rand"; do
    set -- "$1" "$2" $cfg
    iverilog -g2012 -P tb_dram.MAP=$3 -P tb_dram.OPEN_PAGE=$4 -o "build_mut/$1" "$2" tb_dram.v dram_model.v
    res=$(timeout 600 vvp -n "build_mut/$1" +wl=$5 +n=4000 | awk '/ERROR/ && n < 1 {print; n++} /^PASS|^FAIL/ {print}')
    printf "  MAP=%s OPEN=%s %-5s %s\n" $3 $4 $5 "$(echo "$res" | tr '\n' ' ')"
    echo "$res" | grep -q '^PASS' || killed=1
  done
  [ $killed = 1 ] && echo "  => 抓到" || echo "  => 没抓到"
}

echo "===== M1: tRCD 少一拍 ====="
sed 's/K_RCD = tRCD - 1/K_RCD = tRCD - 2/' dram_ctrl.v > build_mut/m1.v
run m1 build_mut/m1.v

echo "===== M2: 不刷新 ====="
sed "s/ref_timer <= K_REFI; ref_pending <= 1'b1;/ref_timer <= K_REFI;/" dram_ctrl.v > build_mut/m2.v
run m2 build_mut/m2.v

echo "===== M3: 行命中不比较行号 ====="
sed 's/if (b_open\[sb\] \&\& b_row\[sb\] == e_row\[sk\]) begin/if (b_open[sb]) begin/' dram_ctrl.v > build_mut/m3.v
run m3 build_mut/m3.v

echo "===== M4: 写数据晚一拍 ====="
sed -e 's/reg \[tCWL-1:0\] wr_sr;/reg [tCWL:0] wr_sr;/' -e 's/wr_sr\[tCWL-2:0\]/wr_sr[tCWL-1:0]/' \
    -e 's/wstart = wr_sr\[tCWL-1\]/wstart = wr_sr[tCWL]/' -e "s/wr_sr <= {tCWL{1'b0}}/wr_sr <= {(tCWL+1){1'b0}}/" \
    dram_ctrl.v > build_mut/m4.v
run m4 build_mut/m4.v

echo "===== M5: 不检查 tFAW ====="
sed 's/ \&\& faw_free) begin/) begin/' dram_ctrl.v > build_mut/m5.v
run m5 build_mut/m5.v

echo "===== M6: 读后写不等换向 ====="
sed 's/n_wr = mx(n_wr, K_RD2WR);/n_wr = mx(n_wr, K_CCD);/' dram_ctrl.v > build_mut/m6.v
run m6 build_mut/m6.v

echo "===== M7: 刷新前不预充电 ====="
sed 's/if (!picked \&\& all_closed \&\& all_act_ok) begin/if (!picked \&\& all_act_ok) begin/' dram_ctrl.v > build_mut/m7.v
run m7 build_mut/m7.v

echo "===== M8: 自动预充电的写忽略 tWR ====="
sed 's/mx(t_pre\[nb\], T_WRPRE)/mx(t_pre[nb], T_RTP)/' dram_ctrl.v > build_mut/m8.v
run m8 build_mut/m8.v
