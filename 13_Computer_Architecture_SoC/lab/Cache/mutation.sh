#!/usr/bin/env bash
# 变异测试：注入六个 cache 典型 bug，确认 testbench 能抓到。bash mutation.sh
#   M1 命中时不更新 LRU（只在填充时更新 → 实际变成 FIFO 替换）     —— 数据全对，只有命中模型能抓
#   M2 写命中不置脏位                                                —— 被换出时修改丢失
#   M3 填充时不清脏位                                                —— 多出无用的写回，数据仍对
#   M4 选牺牲路时不优先用无效路                                      —— 等价变异，预期 PASS（见 README）
#   M5 写命中不看字节使能，整字覆盖
#   M6 写回地址用了当前请求的 tag，而不是牺牲行自己的 tag
#   M7 年龄全部复位为 0（不是一个排列），LRU 从一开始就失效
# 配置 SETS=8 WAYS=4 写回；变异文件写到 build_mut/，不改原 RTL
set -uo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment
mkdir -p build_mut

run() {  # $1 名称  $2 变异后的 cache.v
  if cmp -s "$2" cache.v; then echo "sed 没有匹配"; return; fi
  iverilog -g2012 -P tb_cache.SETS=8 -P tb_cache.WAYS=4 -P tb_cache.NREQ=5000 -o "build_mut/$1" "$2" tb_cache.v
  vvp -n "build_mut/$1" | awk '/ERROR/ && n < 2 {print; n++} /^PASS|^FAIL/ {print}'
}

echo "===== M1: 命中不更新 LRU（变成 FIFO）====="
sed 's/            if (access) begin/            if (access \&\& r_retry) begin/' cache.v > build_mut/m1.v
run m1 build_mut/m1.v

echo "===== M2: 写命中不置脏 ====="
sed 's/if (r_we \&\& WRITE_BACK != 0) dirty\[{hit_way, r_idx}\] <= 1.b1;//' cache.v > build_mut/m2.v
run m2 build_mut/m2.v

echo "===== M3: 填充不清脏位 ====="
sed 's/dirty\[{r_victim, r_idx}\] <= 1.b0;//' cache.v > build_mut/m3.v
run m3 build_mut/m3.v

echo "===== M4: 不优先填无效路（等价变异，预期 PASS）====="
sed 's/wire \[AGEW-1:0\] victim = has_inv ? inv_way : lru_way;/wire [AGEW-1:0] victim = lru_way;/' cache.v > build_mut/m4.v
run m4 build_mut/m4.v

echo "===== M5: 写命中不看字节使能 ====="
sed 's/<= merge(hit_word, r_wdata, r_wstrb);/<= r_wdata;/' cache.v > build_mut/m5.v
run m5 build_mut/m5.v

echo "===== M6: 写回地址用错 tag ====="
sed 's/assign vict_addr = {tag\[{r_victim, r_idx}\], r_idx, {OFFW{1.b0}}};/assign vict_addr = {r_tag, r_idx, {OFFW{1'"'"'b0}}};/' cache.v > build_mut/m6.v
run m6 build_mut/m6.v

echo "===== M7: 年龄全部复位为 0 ====="
sed 's/age\[{w2\[AGEW-1:0\], s2\[IDXW-1:0\]}\] <= w2\[AGEW-1:0\];/age[{w2[AGEW-1:0], s2[IDXW-1:0]}] <= {AGEW{1'"'"'b0}};/' cache.v > build_mut/m7.v
run m7 build_mut/m7.v
