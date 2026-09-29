#!/usr/bin/env bash
# =============================================================================
# 后端全流程（WSL，root）：bash run.sh
#   0 综合 → 1 布图/电源 → 2 布局 → 3 CTS → 4 布线 → 5 RC 抽取 → 6 签核 STA
#   → 9 时序 ECO → 5/6 再抽取、再签核 → 7 IR drop/EM → 8 GDS/DRC/LVS → 布线后门级仿真
# 每一步的完整日志在 reports/，这里只打印关键行
# 可选环境变量：CLK_PERIOD UTIL PLACE_DENSITY STRAP_PITCH ANTENNA_DIODES（见 config.tcl）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
trap 'echo "!! 第 $LINENO 行的步骤失败，看 reports/ 下最新的 .log"' ERR

export PDK_ROOT=/root/micromamba/envs/orfs/share/pdk
HD=$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd
BIN=/root/micromamba/envs/orfs/bin
MAGICRC=$PDK_ROOT/sky130A/libs.tech/magic/sky130A.magicrc
TB=../../../08_Logic_Synthesis/lab/Yosys_Flow/tb_alu.v

source /root/oss-cad-suite/environment
mkdir -p build reports
cp "$HD/lib/sky130_fd_sc_hd__tt_025C_1v80.lib" build/lib_tt.lib

# 运行一步：日志去掉读 LEF 的刷屏信息后存到 reports/<名字>.log
run_or()    { "$BIN/openroad" -no_init -exit "$2" 2>&1 | grep -v -E 'ODB-022[2-6]|LEFPARS|NOWIREEXT|^$' > "reports/$1.log"; }
run_magic() { "$BIN/magic" -noconsole -dnull -rcfile "$MAGICRC" "$2" > "reports/$1.log" 2>&1; }
show()      { grep -h -E "$2" "reports/$1.log" || true; }

echo "==== 0. 综合 ===="
yosys -q -l reports/0_synth.log synth.ys
grep -E 'Chip area|cells$' reports/0_synth.stat

echo "==== 1. 布图 + 电源网络 ===="
run_or 1_floorplan 1_floorplan.tcl
show 1_floorplan 'FLOORPLAN|TAP-000[45]|Design area'

echo "==== 2. 布局 ===="
run_or 2_place 2_place.tcl
show 2_place 'TIMING|RSZ-00(34|35|38|39)|legalized HPWL|HPWL after|Design area'

echo "==== 3. CTS ===="
run_or 3_cts 3_cts.tcl
show 3_cts 'CTS_BEFORE|CTS-00(10|12|13|18)|CTS clock|TIMING|RSZ-00(32|41|46)|Design area'

echo "==== 4. 布线 ===="
run_or 4_route 4_route.tcl
show 4_route '^Total +[0-9]|TIMING|Number of violations|ANT-000'
show 4_route '^Total wire length =' | tail -1

extract_and_signoff() {   # $1 = 数据库  $2 = 报告名
  for c in min nom max; do
    DB=$1 RC_CORNER=$c run_or "5_extract_$c" 5_extract.tcl
  done
  "$BIN/sta" -no_init -exit 6_signoff_sta.tcl > "reports/$2.rpt" 2>&1
  grep -E '^CORNER|^Total ' "reports/$2.rpt"
}

echo "==== 5/6. RC 抽取 + 签核 STA（ECO 前）===="
extract_and_signoff 4_route.odb 6_signoff_sta_pre_eco

echo "==== 9. 时序 ECO ===="
run_or 9_eco 9_eco.tcl
show 9_eco 'TIMING|ECO cells|RSZ-00(3|4)[0-9]|removed|DRT-0199|ANT-000' | tail -12

echo "==== 5/6. RC 抽取 + 签核 STA（ECO 后，最终）===="
extract_and_signoff 9_eco.odb 6_signoff_sta

echo "==== 7. IR drop / EM ===="
run_or 7_irdrop 7_irdrop.tcl
show 7_irdrop '^Total  |IR drop:|PSM-0064|PSM-0040|Worstcase IR|Average IR|Maximum current'

echo "==== 8. GDS → DRC → LVS ===="
run_magic 8_gds 8_magic_gds.tcl
show 8_gds 'DRC_PATCH|GDS DONE'
run_magic 8_drc 8_magic_drc.tcl
show 8_drc 'DRC TOTAL'
run_magic 8_extract 8_magic_extract.tcl
show 8_extract 'EXTRACT DONE'
"$BIN/netgen" -batch source 8_lvs.tcl > reports/8_lvs.log 2>&1 || true
grep -E 'Circuit 1 contains [0-9]+ (devices|nets).*[0-9]{3}|Circuits match|do not match' reports/8_lvs.log | tail -3

echo "==== 布线后门级仿真（第 08 章同一个自检查 TB）===="
iverilog -g2012 -DGLS -DFUNCTIONAL -DUNIT_DELAY=#1 -o build/gls_route \
  "$HD/verilog/primitives.v" "$HD/verilog/sky130_fd_sc_hd.v" build/alu_route.v "$TB"
(cd build && vvp -n gls_route) > reports/10_gls_route.log
grep -E 'PASS|FAIL|ERROR' reports/10_gls_route.log
