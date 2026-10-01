#!/usr/bin/env bash
# 变异测试：注入五个典型错误，确认 lockstep 比对 + 程序自检查能抓到。先跑过 run_sim.sh。
#   M1 sra 写成 a >>> b（a 是无符号的，>>> 退化成逻辑右移）
#   M2 lb / lh 忘记符号扩展
#   M3 jalr 目标不清最低位
#   M4 sltu 用了有符号比较
#   M5 I 型 ALU 指令都用 instr[30] 选 ALU 操作（只有 srai 才该看），addi 负立即数会变成 sub
# 变异文件写到 build_mut/，不改原 RTL；每个变异都应该至少有一个程序 FAIL
set -uo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment
mkdir -p build_mut
PROGS="isa_test sort fib hazards branchy"

run() {  # $1 名称  $2 被替换的原文件  $3 变异后的文件
  if cmp -s "$2" "$3"; then echo "sed 没有匹配"; return; fi
  local files=""
  for f in rv32i_decode.v rv32i_alu.v rv32i_branch.v rv32i_lsu.v rv32i_regfile.v rv32i_single.v; do
    if [[ $f == "$2" ]]; then files="$files $3"; else files="$files $f"; fi
  done
  iverilog -g2012 -o "build_mut/$1" $files tb_rv32i_single.v
  local summary=""
  for p in $PROGS; do
    out=$(vvp -n "build_mut/$1" +prog=build/$p | grep -a -E 'ERROR|PASS|FAIL')
    res=$(echo "$out" | grep -a -E '^(PASS|FAIL)' | head -1)
    summary="$summary $p:${res%% *}"
    [[ -z "${first:-}" && $res == FAIL* ]] && first=$(echo "$out" | grep -a ERROR | head -1)
  done
  echo "$summary"
  echo "  首个错误: ${first:-无}"
  unset first
}

echo "===== M1: sra 变成逻辑右移 ====="
sed 's/y = $unsigned($signed(a) >>> b\[4:0\]);/y = a >>> b[4:0];/' rv32i_alu.v > build_mut/alu_m1.v
run m1 rv32i_alu.v build_mut/alu_m1.v

echo "===== M2: lb / lh 不做符号扩展 ====="
sed -e 's/{{24{ld_b\[7\]}}, ld_b}/{24'"'"'b0, ld_b}/' -e 's/{{16{ld_h\[15\]}}, ld_h}/{16'"'"'b0, ld_h}/' rv32i_lsu.v > build_mut/lsu_m2.v
run m2 rv32i_lsu.v build_mut/lsu_m2.v

echo "===== M3: jalr 不清最低位 ====="
sed 's/is_jalr                 ? {alu_y\[31:1\], 1'"'"'b0}/is_jalr                 ? alu_y/' rv32i_single.v > build_mut/single_m3.v
run m3 rv32i_single.v build_mut/single_m3.v

echo "===== M4: sltu 用有符号比较 ====="
sed 's/y = {31'"'"'b0, a < b};/y = {31'"'"'b0, $signed(a) < $signed(b)};/' rv32i_alu.v > build_mut/alu_m4.v
run m4 rv32i_alu.v build_mut/alu_m4.v

echo "===== M5: I 型指令误用 instr[30] ====="
sed 's/alu_op = {(funct3 == 3'"'"'b101) \& instr\[30\], funct3};/alu_op = {instr[30], funct3};/' rv32i_decode.v > build_mut/dec_m5.v
run m5 rv32i_decode.v build_mut/dec_m5.v
