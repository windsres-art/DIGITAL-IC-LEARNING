#!/usr/bin/env bash
# 变异测试：注入七个流水线典型 bug，确认 testbench 能抓到。先跑过 run_sim.sh（需要 ../RV32I/build 里的轨迹）。
#   M1 前递优先级反了：MEM/WB 盖过 EX/MEM（双重冒险取到旧值）
#   M2 前递不排除 x0（写 x0 的结果被前递出去）
#   M3 没有 load-use 停顿
#   M4 寄存器堆没有写穿透（WB 写、ID 读同一拍时读到旧值）
#   M5 预测错时只冲 ID/EX，忘了冲 IF/ID（错误路径上的一条指令溜过去）
#   M6 store 数据没用前递后的值
#   M7 ecall 不杀更年轻的指令（停机不精确：后面的 store 在 ecall 退休那拍写了内存）
# 每个变异在 FWD=1 BP=0 下跑全部程序，应该至少有一个 FAIL
set -uo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment
mkdir -p build_mut
R=../RV32I
PROGS="isa_test sort fib hazards branchy"
COMMON="$R/rv32i_decode.v $R/rv32i_alu.v $R/rv32i_branch.v $R/rv32i_lsu.v"

run() {  # $1 名称  $2 变异后的 rv32i_pipe.v  [$3 变异后的 regfile]
  local pipe="$2" rf="${3:-$R/rv32i_regfile.v}"
  if cmp -s "$pipe" rv32i_pipe.v && cmp -s "$rf" $R/rv32i_regfile.v; then echo "sed 没有匹配"; return; fi
  iverilog -g2012 -P tb_rv32i_pipe.FWD=1 -P tb_rv32i_pipe.BP=0 -o "build_mut/$1" $COMMON "$rf" "$pipe" tb_rv32i_pipe.v
  local summary="" first=""
  for p in $PROGS; do
    out=$(vvp -n "build_mut/$1" +prog=$R/build/$p | grep -a -E 'ERROR|^PASS|^FAIL')
    res=$(echo "$out" | grep -a -E '^(PASS|FAIL)' | head -1)
    summary="$summary $p:${res%% *}"
    [[ -z "$first" && $res == FAIL* ]] && first=$(echo "$out" | grep -a ERROR | head -1)
  done
  echo "$summary"
  echo "  首个错误: ${first:-无}"
}

echo "===== M1: 前递优先级反了 ====="
# 把 rs1 的 MEM/WB 那一行挪到 EX/MEM 那一行之后：后赋值者赢，于是 MEM/WB 优先
sed -e '/if (w_valid \&\& w_reg_we \&\& w_rd != 5.d0 \&\& w_rd == x_rs1) ex_a_fwd = w_wdata;/{h;d}' \
    -e '/if (m_valid \&\& m_reg_we \&\& m_rd != 5.d0 \&\& m_rd == x_rs1) ex_a_fwd = m_result;/G' \
    rv32i_pipe.v > build_mut/pipe_m1.v
run m1 build_mut/pipe_m1.v

echo "===== M2: 前递不排除 x0 ====="
sed 's/m_valid \&\& m_reg_we \&\& m_rd != 5.d0 \&\& m_rd == x_rs1/m_valid \&\& m_reg_we \&\& m_rd == x_rs1/' \
    rv32i_pipe.v > build_mut/pipe_m2.v
run m2 build_mut/pipe_m2.v

echo "===== M3: 没有 load-use 停顿 ====="
sed 's/wire load_use  = dep_x \& x_mem_re;/wire load_use  = 1'"'"'b0;/' rv32i_pipe.v > build_mut/pipe_m3.v
run m3 build_mut/pipe_m3.v

echo "===== M4: 寄存器堆没有写穿透 ====="
sed 's/rv32i_regfile #(.BYPASS(1)) u_rf/rv32i_regfile #(.BYPASS(0)) u_rf/' rv32i_pipe.v > build_mut/pipe_m4.v
run m4 build_mut/pipe_m4.v

echo "===== M5: 预测错只冲 ID/EX，不冲 IF/ID ====="
sed 's/end else if (flush_young | fetch_stop) begin/end else if (ex_kill | fetch_stop) begin/' rv32i_pipe.v > build_mut/pipe_m5.v
run m5 build_mut/pipe_m5.v

echo "===== M6: store 数据不用前递值 ====="
sed 's/m_rs2_val   <= ex_b_fwd;/m_rs2_val   <= x_rs2_val;/' rv32i_pipe.v > build_mut/pipe_m6.v
run m6 build_mut/pipe_m6.v

echo "===== M7: ecall 不杀更年轻的指令 ====="
sed 's/wire ex_kill = x_valid \& (x_is_system | ex_exc);/wire ex_kill = x_valid \& ex_exc;/' rv32i_pipe.v > build_mut/pipe_m7.v
run m7 build_mut/pipe_m7.v
