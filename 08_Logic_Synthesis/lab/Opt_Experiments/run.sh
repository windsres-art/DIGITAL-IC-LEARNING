#!/usr/bin/env bash
# 在 WSL（root）里运行：bash run.sh
# 同一份 RTL 用不同综合选项跑，比较面积 / 触发器数 / 时序：
#   A. 边界优化：打平 vs 保留层次
#   B. 寄存器复制：默认合并 vs (* keep *)
#   C. 资源共享：share 开/关，与手写共享版对比
#   D. FSM 编码：auto / binary / one-hot
#   E. retiming：原始 / ABC -dff 自动 / 手工
set -euo pipefail
cd "$(dirname "$0")"

PDK=/root/micromamba/envs/orfs/share/pdk/sky130A/libs.ref/sky130_fd_sc_hd
LIB=${LIB:-$PDK/lib/sky130_fd_sc_hd__tt_025C_1v80.lib}
STA=${STA:-/root/micromamba/envs/orfs/bin/sta}
L=build/lib.lib

source /root/oss-cad-suite/environment
mkdir -p build reports
cp "$LIB" $L

MAP="dfflibmap -liberty $L -dont_use *lpflow*; abc -liberty $L -dont_use *lpflow*; opt_clean"

# syn <tag> <top> <yosys 命令串>：综合，统计写 reports/<tag>.stat，网表写 build/<tag>.v
syn() {
  yosys -q -l "reports/$1.log" -p "read_liberty -lib $L; $3; \
    tee -q -o reports/$1.stat stat -top $2 -liberty $L; write_verilog -noattr build/$1.v"
}
# row <tag> <说明>：打印面积、单元数、FF 数
row() {
  local area cells ff
  area=$(awk '/Chip area for (top )?module/{a=$NF} END{print a}' "reports/$1.stat")
  cells=$(awk '/ cells$/{c=$1} END{print c}' "reports/$1.stat")
  # 有层次时 stat 末尾还有一段“design hierarchy”汇总，只数那一段，避免重复计数
  ff=$(awk '/design hierarchy/{n=0} /sky130_fd_sc_hd__(df|edf)/{n+=$1} END{print n+0}' "reports/$1.stat")
  printf "  %-24s area=%9.1f  cells=%5s  FF=%3s  %s\n" "$1" "$area" "$cells" "$ff" "${2:-}"
}
# timing <tag> <top> <period>：最差路径的到达时间和 slack
# report_checks -format end 每行：端点 (单元类型) required actual slack (MET|VIOLATED)
timing() {
  NETLIST=build/$1.v TOP=$2 PERIOD=$3 "$STA" -no_init -exit sta_generic.tcl > "reports/$1.sta"
  awk '/\((MET|VIOLATED)\)/{printf "    最差路径终点 %-8s arrival=%s  slack=%s\n", $1, $(NF-2), $(NF-1); exit}' \
    "reports/$1.sta"
}

echo "==== 0. RTL 自检查 ===="
verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-MULTITOP -Wno-UNUSEDSIGNAL \
  boundary.v share.v fsm.v retime.v
iverilog -g2012 -o build/opt_sim boundary.v share.v fsm.v tb_opt.v
vvp -n build/opt_sim | grep -E 'PASS|FAIL|不一致'
for dut in retime_mac retime_mac_manual; do
  iverilog -g2012 -DDUT=$dut -o build/rt_sim retime.v tb_retime.v
  echo "  $dut: $(vvp -n build/rt_sim | grep -E 'PASS|FAIL')"
done

echo "==== A. 边界优化：mode 接常量 0 ===="
syn A_flatten boundary_top "read_verilog boundary.v; synth -top boundary_top -flatten; $MAP"
syn A_hier    boundary_top "read_verilog boundary.v; synth -top boundary_top; $MAP"
row A_flatten "打平：常量穿过边界，乘法器被删"
row A_hier    "保留层次：子模块看不到常量"
grep -E '^=== |Chip area for module' reports/A_hier.stat | sed 's/^/    /'

echo "==== B. 寄存器复制 ===="
# 选中驱动 en_a / en_b 的寄存器单元，设 keep（≈ set_dont_touch）
KEEP_CELLS='w:en_a %ci1 w:en_b %ci1 %u t:$adff %i'
syn B_nokeep    dup_nokeep "read_verilog boundary.v; synth -top dup_nokeep; $MAP"
syn B_keep_wire dup_keep   "read_verilog boundary.v; synth -top dup_keep; $MAP"
syn B_keep_cell dup_nokeep "read_verilog boundary.v; hierarchy -top dup_nokeep; proc; \
  setattr -set keep 1 $KEEP_CELLS; synth -top dup_nokeep; $MAP"
row B_nokeep    "默认：en_a/en_b 被合并成一个"
row B_keep_wire "(* keep *) 写在 reg 上：仍被合并"
row B_keep_cell "keep 设在寄存器单元上：两份都保住"

echo "==== C. 资源共享（组合电路，端口到端口延时）===="
syn C_mul2_default  share_mul_2 "read_verilog share.v; synth -top share_mul_2; $MAP"
syn C_mul2_share    share_mul_2 "read_verilog share.v; synth -top share_mul_2 -noalumacc; $MAP"
syn C_mul2_noshare  share_mul_2 "read_verilog share.v; synth -top share_mul_2 -noalumacc -noshare; $MAP"
syn C_mul1          share_mul_1 "read_verilog share.v; synth -top share_mul_1; $MAP"
row C_mul2_default "默认：alumacc 先把 \$mul 变成 \$macc，share 不处理"
timing C_mul2_default share_mul_2 10
row C_mul2_share   "-noalumacc：share 把两个乘法器合成一个"
timing C_mul2_share share_mul_2 10
row C_mul2_noshare "-noalumacc -noshare：两个乘法器"
timing C_mul2_noshare share_mul_2 10
row C_mul1         "手写：先选操作数再乘"
timing C_mul1 share_mul_1 10
grep -E 'Activation pattern|merging' reports/C_mul2_share.log | head -3 | sed 's/^/    log: /' || true

echo "==== D. FSM 编码 ===="
for enc in auto binary one-hot; do
  set_enc=""; [[ $enc != auto ]] && set_enc="setattr -set fsm_encoding \"$enc\" w:st;"
  syn D_fsm_$enc seq_det "read_verilog fsm.v; hierarchy -top seq_det; proc; $set_enc synth -top seq_det; $MAP"
  row D_fsm_$enc
  grep -E 'mapping auto encoding|using .* encoding' reports/D_fsm_$enc.log | head -2 | sed 's/^/    log: /'
done

echo "==== E. retiming（时钟 3 ns）===="
syn E_orig   retime_mac        "read_verilog retime.v; synth -top retime_mac; $MAP"
syn E_abcdff retime_mac        "read_verilog retime.v; synth -top retime_mac; \
  abc -liberty $L -dont_use *lpflow* -dff; dfflibmap -liberty $L -dont_use *lpflow*; opt_clean"
syn E_manual retime_mac_manual "read_verilog retime.v; synth -top retime_mac_manual; $MAP"
for t in E_orig:retime_mac E_abcdff:retime_mac E_manual:retime_mac_manual; do
  row "${t%%:*}"; timing "${t%%:*}" "${t##*:}" 3
done
# ABC 搬过寄存器的网表必须重新验证功能
iverilog -g2012 -DGLS -DFUNCTIONAL -DUNIT_DELAY=#1 -o build/rt_gls \
  "$PDK/verilog/primitives.v" "$PDK/verilog/sky130_fd_sc_hd.v" build/E_abcdff.v tb_retime.v
echo "    E_abcdff 门级仿真: $(vvp -n build/rt_gls | grep -E 'PASS|FAIL')"
