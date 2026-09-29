#!/usr/bin/env bash
# =============================================================================
# 对比实验（先跑过 run.sh）：bash run_experiments.sh        约 13 分钟
#   只跑其中几项：ONLY=EF bash run_experiments.sh（结果追加到汇总文件）
#   每个实验用独立的 BUILD / REPORTS 目录，不覆盖主流程结果；汇总写到 reports/exp_summary.txt
#   A. 利用率扫描：拥塞、布线收敛、线长、时序
#   B. 天线：不插二极管会怎样
#   C. 电源条间距 vs IR drop
#   D. 关掉 repair_design / repair_timing：DRV 与 hold 违例留在设计里
#   E. 签核：ss corner 要多长的周期才能满足
#   F. 签核 DRC：不修补 met3 最小面积时 Magic 能查出多少违例
#   G. 供电点（bump）间距 vs IR drop
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

BIN=/root/micromamba/envs/orfs/bin
export PDK_ROOT=/root/micromamba/envs/orfs/share/pdk
MAGICRC=$PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc
run_or()    { "$BIN/openroad" -no_init -exit "$2" 2>&1 | grep -v -E 'ODB-022[2-6]|LEFPARS|NOWIREEXT|^$' > "$REPORTS/$1.log"; }
run_magic() { "$BIN/magic" -noconsole -dnull -rcfile "$MAGICRC" "$2" > "reports/$1.log" 2>&1; }
last()   { grep -h -E "$2" "$REPORTS/$1.log" | tail -1 || true; }
first()  { grep -h -E "$2" "$REPORTS/$1.log" | head -1 || true; }
ONLY=${ONLY:-ABCDEFG}
has()    { [[ $ONLY == *$1* ]]; }
SUM=reports/exp_summary.txt
[ "$ONLY" = ABCDEFG ] && : > "$SUM"
say() { echo "$*" | tee -a "$SUM"; }

# ---------------------------------------------------------------- A. 利用率
if has A; then
say "#### A. 利用率扫描（UTIL = 核心区利用率目标，布局密度取 UTIL+10%）"
say "$(printf '%-5s %-16s %-10s %-26s %-9s %-10s %-10s %-8s %-8s' UTIL die_um HPWL_um 'GR_usage(met1/met2/total)' overflow 'DRT_iter0' 'DRT_final' 'WL_um' 'GR_ws')"
for u in 30 45 60 75; do
  export UTIL=$u PLACE_DENSITY=$(awk -v u=$u 'BEGIN{print u/100+0.10}')
  export BUILD=build/exp_util_$u REPORTS=reports/exp_util_$u
  mkdir -p "$BUILD" "$REPORTS"
  cp build/alu_synth.v "$BUILD/"
  fail=""
  for s in 1_floorplan 2_place 3_cts 4_route; do run_or $s $s.tcl || { fail=$s; break; }; done
  if [ -n "$fail" ]; then
    say "$(printf '%-5s %-16s ' $u $(last 1_floorplan 'FLOORPLAN die' | awk '{print $3"x"$5}'))在 $fail 失败: $(grep -h -E '^\[ERROR' "$REPORTS/$fail.log" | tail -1)"
    say "      利用率变化: $(grep -h 'Design area' "$REPORTS"/*.log | awk '{print $5}' | paste -sd' ')"
    continue
  fi
  die=$(last 1_floorplan 'FLOORPLAN die' | awk '{print $3"x"$5}')
  hpwl=$(last 2_place 'HPWL after' | awk '{print $(NF-1)}')
  m1=$(awk '/Final congestion report/{f=1} f&&/^met1 /{print $4; exit}' "$REPORTS/4_route.log")
  m2=$(awk '/Final congestion report/{f=1} f&&/^met2 /{print $4; exit}' "$REPORTS/4_route.log")
  tot=$(awk '/Final congestion report/{f=1} f&&/^Total /{print $4; exit}' "$REPORTS/4_route.log")
  ovf=$(awk '/Final congestion report/{f=1} f&&/^Total /{print $NF; exit}' "$REPORTS/4_route.log")
  d0=$(first 4_route 'Number of violations' | awk '{gsub(/\./,"",$NF); print $NF}')
  dn=$(last 4_route 'Number of violations' | awk '{gsub(/\./,"",$NF); print $NF}')
  wl=$(last 4_route '^Total wire length =' | awk '{print $5}')
  ws=$(last 4_route 'TIMING after global_route' | awk '{print $5}')
  say "$(printf '%-5s %-16s %-10s %-26s %-9s %-10s %-10s %-8s %-8s' $u $die $hpwl "$m1/$m2/$tot" $ovf $d0 $dn $wl $ws)"
done
unset UTIL PLACE_DENSITY
fi

# ---------------------------------------------------------------- B. 天线
if has B; then
say ""
say "#### B. 天线：不插二极管（其余与主流程相同，从主流程的 CTS 结果开始布线）"
export BUILD=build/exp_no_diode REPORTS=reports/exp_no_diode ANTENNA_DIODES=0
mkdir -p "$BUILD" "$REPORTS"
cp build/3_cts.odb "$BUILD/"
run_or 4_route 4_route.tcl
say "no diodes : $(last 4_route 'ANT-0002')"
say "with diodes (主流程): $(grep -h 'ANT-0002' reports/4_route.log | tail -1)"
awk '/^Net - /{n=$3} /^\[1\]/{l=$2} /\*/{print "   ", n, l, $1, $2, "limit", $4}' "$REPORTS/4_antenna.rpt" | tee -a "$SUM"
unset ANTENNA_DIODES
fi

# ---------------------------------------------------------------- C. 电源条间距
if has C; then
say ""
say "#### C. met4/met5 电源条间距 vs IR drop（布局后分析，电压源每 40 um 一个，翻转率 0.2）"
say "$(printf '%-12s %-10s %-14s %-14s %-14s' strap_um VDD_nodes 'VDD_worst_mV' 'VDD_avg_mV' 'VSS_worst_mV')"
for p in 13.6 27.2 54.4; do
  export STRAP_PITCH=$p BUILD=build/exp_pdn_$p REPORTS=reports/exp_pdn_$p
  mkdir -p "$BUILD" "$REPORTS"
  cp build/alu_synth.v "$BUILD/"
  run_or 1_floorplan 1_floorplan.tcl
  run_or 2_place 2_place.tcl
  DB=2_place.odb BUMP_PITCH=40 run_or 7_irdrop 7_irdrop.tcl
  nodes=$(first 7_irdrop 'PSM-0031' | awk '{gsub(/\./,"",$NF); print $NF}')
  vw=$(grep -h 'Worstcase IR drop' "$REPORTS/7_irdrop.log" | sed -n 1p | awk '{printf "%.3f", $4*1000}')
  va=$(grep -h 'Average IR drop'   "$REPORTS/7_irdrop.log" | sed -n 1p | awk '{printf "%.3f", $5*1000}')
  sw=$(grep -h 'Worstcase IR drop' "$REPORTS/7_irdrop.log" | sed -n 2p | awk '{printf "%.3f", $4*1000}')
  say "$(printf '%-12s %-10s %-14s %-14s %-14s' $p $nodes $vw $va $sw)"
done
unset STRAP_PITCH
fi

# ---------------------------------------------------------------- D. 关掉优化
if has D; then
say ""
say "#### D. DO_REPAIR=0：不做 repair_design / repair_timing（到 CTS 为止）"
export DO_REPAIR=0 BUILD=build/exp_norepair REPORTS=reports/exp_norepair
mkdir -p "$BUILD" "$REPORTS"
cp build/alu_synth.v "$BUILD/"
for s in 1_floorplan 2_place 3_cts; do run_or $s $s.tcl; done
say "no repair : $(last 3_cts 'TIMING after CTS')"
say "            DRV 违例行数（slew/cap/fanout）: $(grep -c 'VIOLATED' "$REPORTS/2_place.log")"
say "主流程    : $(grep -h 'TIMING after CTS repair' reports/3_cts.log)"
unset DO_REPAIR
fi

# ---------------------------------------------------------------- E. ss corner 周期
if has E; then
say ""
say "#### E. 同一份布线后网表，只改约束周期，看各 corner"
export BUILD=build
for p in 5.0 8.0 10.0 11.0; do
  CLK_PERIOD=$p "$BIN/sta" -no_init -exit 6_signoff_sta.tcl > reports/exp_period_$p.rpt 2>&1
  say "CLK_PERIOD=$p"
  grep '^CORNER' reports/exp_period_$p.rpt | sed 's/^/    /' | tee -a "$SUM"
done
fi

# ---------------------------------------------------------------- F. 签核 DRC 不修补
if has F; then
say ""
say "#### F. 签核 DRC：关掉 met3 最小面积修补（DRC_PATCH=0）"
DRC_PATCH=0 run_magic exp_gds_nopatch 8_magic_gds.tcl
run_magic exp_drc_nopatch 8_magic_drc.tcl
cp reports/8_drc.rpt reports/exp_drc_nopatch.rpt
grep -v '^      at' reports/exp_drc_nopatch.rpt | sed 's/^/    /' | tee -a "$SUM"
# 恢复主流程的 GDS 与 DRC 报告
run_magic 8_gds 8_magic_gds.tcl
run_magic 8_drc 8_magic_drc.tcl
say "修补后（主流程）: $(grep -h 'DRC TOTAL' reports/8_drc.log)"
fi
# ---------------------------------------------------------------- G. 供电点间距
if has G; then
say ""
say "#### G. 最终设计（ECO 后、布线后 SPEF）：电压源（bump）间距 vs IR drop"
say "$(printf '%-10s %-12s %-14s %-14s %-14s' bump_um VDD_sources 'VDD_worst_mV' 'VSS_worst_mV' 'VDD_Imax_mA')"
export BUILD=build
for b in 5 10 20 40; do
  export REPORTS=reports/exp_bump_$b
  mkdir -p "$REPORTS"
  BUMP_PITCH=$b run_or 7_irdrop 7_irdrop.tcl
  ns=$(grep -h 'PSM-0064' "$REPORTS/7_irdrop.log" | sed -n 2p | awk '{gsub(/\./,"",$NF); print $NF}')
  vw=$(grep -h 'Worstcase IR drop' "$REPORTS/7_irdrop.log" | sed -n 1p | awk '{printf "%.3f", $4*1000}')
  sw=$(grep -h 'Worstcase IR drop' "$REPORTS/7_irdrop.log" | sed -n 2p | awk '{printf "%.3f", $4*1000}')
  im=$(grep -h 'Maximum current'   "$REPORTS/7_irdrop.log" | sed -n 1p | awk '{printf "%.3f", $3*1000}')
  say "$(printf '%-10s %-12s %-14s %-14s %-14s' $b $ns $vw $sw $im)"
done
fi
echo "汇总: $SUM"
