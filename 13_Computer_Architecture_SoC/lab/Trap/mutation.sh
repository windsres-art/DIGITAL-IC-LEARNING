#!/usr/bin/env bash
# 变异测试：bash mutation.sh（先跑过 run_sim.sh，build/ 里要有汇编好的程序）
#   核（每个变异跑 3 个程序 × 无等待 / 随机等待，日志交给 trap_iss.py）：
#     M1 访存等待时不保存前递值（调试中真实遇到的 bug）    M2 中断不看 mstatus.MIE
#     M3 mret 不恢复 MIE                                    M4 中断优先级 MTI 高于 MSI
#     M5 CSR 指令不串行化                                    M6 访问错误不杀更年轻的指令
#     M7 wfi 当 nop                                          M8 进入 trap 不保存 MPIE
#   PLIC（plic_test）：M9 同优先级取大号                     M10 claim 后网关不挡住重复的 pending
#   DMA（tb_dma）：    M11 每段少搬最后一个字                M12 描述符链只走第一个
set -uo pipefail
cd "$(dirname "$0")"

source /root/oss-cad-suite/environment
mkdir -p build_mut
RV="../RV32I/rv32i_decode.v ../RV32I/rv32i_alu.v ../RV32I/rv32i_branch.v ../RV32I/rv32i_lsu.v ../RV32I/rv32i_regfile.v"

core_run() {  # $1 名称  $2 变异后的核  $3 变异后的 plic  $4 程序列表
  local p ws res killed=0
  iverilog -g2012 -o build_mut/$1 tb_trap.v clint.v $3 $2 $RV || return
  for p in $4; do for ws in 0 1; do
    res=$(timeout 120 vvp -n build_mut/$1 +prog=build/$p +log=build_mut/$1.log +ws=$ws | grep -a -E '^PASS|^FAIL|^ERROR' | head -1)
    res="$res / $(python3 trap_iss.py build/$p build_mut/$1.log | tail -1)"
    printf "  %-10s ws=%d  %s\n" $p $ws "$res"
    echo "$res" | grep -q -e FAIL -e ERROR && killed=1
  done; done
  [ $killed = 1 ] && echo "  => 抓到" || echo "  => 没抓到"
}

mut() {  # $1 名称  $2 文件  $3 sed 表达式
  sed "$3" "$2" > build_mut/$1.v
  if cmp -s build_mut/$1.v "$2"; then echo "  sed 没有匹配"; return 1; fi
}

ALL="trap_test irq_test plic_test"
echo "===== M1: 访存等待时不保存前递值 ====="
mut m1 rv32i_trap.v 's/x_rs1_val <= ex_a_fwd;/x_rs1_val <= x_rs1_val;/; s/x_rs2_val <= ex_b_fwd;/x_rs2_val <= x_rs2_val;/' && core_run m1 build_mut/m1.v plic.v "$ALL"
echo "===== M2: 中断不看 MIE ====="
mut m2 rv32i_trap.v 's/irq_any = st_mie \& (|pend);/irq_any = |pend;/' && core_run m2 build_mut/m2.v plic.v "$ALL"
echo "===== M3: mret 不恢复 MIE ====="
mut m3 rv32i_trap.v 's/st_mie  <= st_mpie;/st_mie  <= st_mie;/' && core_run m3 build_mut/m3.v plic.v "$ALL"
echo "===== M4: MTI 优先于 MSI ====="
mut m4 rv32i_trap.v "s/pend\[3\] ? 4'd3 : 4'd7/pend[7] ? 4'd7 : 4'd3/" && core_run m4 build_mut/m4.v plic.v "$ALL"
echo "===== M5: CSR 指令不串行化 ====="
mut m5 rv32i_trap.v 's/wire x_serial = (x_sys != S_NONE)/wire x_serial = (x_sys == S_MRET) | (x_sys == S_WFI)/' && core_run m5 build_mut/m5.v plic.v "$ALL"
echo "===== M6: 访问错误不杀更年轻的指令 ====="
mut m6 rv32i_trap.v 's/m_valid   <= x_valid \& ~m_fault;/m_valid   <= x_valid;/' && core_run m6 build_mut/m6.v plic.v "$ALL"
echo "===== M7: wfi 当 nop ====="
mut m7 rv32i_trap.v 's/wire wfi_wait = .*/wire wfi_wait = 1'"'"'b0;/' && core_run m7 build_mut/m7.v plic.v "$ALL"
echo "===== M8: 进入 trap 不保存 MPIE ====="
mut m8 rv32i_trap.v 's/st_mpie <= st_mie;/st_mpie <= st_mpie;/' && core_run m8 build_mut/m8.v plic.v "$ALL"

echo "===== M9: PLIC 同优先级取大号 ====="
mut m9 plic.v 's/prio\[i\] >= best_p/prio[i] > best_p/' && core_run m9 rv32i_trap.v build_mut/m9.v plic_test
echo "===== M10: claim 后网关不挡住重复 pending ====="
mut m10 plic.v "s/inflight\[best_id\] <= 1'b1;//" && core_run m10 rv32i_trap.v build_mut/m10.v plic_test

dma_run() {
  iverilog -g2012 -o build_mut/$1 tb_dma.v $2 || return
  res=$(timeout 300 vvp -n build_mut/$1 +njob=100 | grep -a -E '^ERROR|^PASS|^FAIL' | head -2 | tr '\n' ' ')
  echo "  $res"
  echo "$res" | grep -q -e FAIL -e ERROR && echo "  => 抓到" || echo "  => 没抓到"
}
echo "===== M11: DMA 每段少搬一个字 ====="
mut m11 dma.v 's/state <= (len == 32.d4) ? S_NEXT : S_RD;/state <= (len == 32'"'"'d8) ? S_NEXT : S_RD;/' && dma_run m11 build_mut/m11.v
echo "===== M12: 描述符链只走第一个 ====="
mut m12 dma.v "s/if (sg \&\& next != 32'd0) begin/if (1'b0) begin/" && dma_run m12 build_mut/m12.v
