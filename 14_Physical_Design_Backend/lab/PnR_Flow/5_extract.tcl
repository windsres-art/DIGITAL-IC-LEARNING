# =============================================================================
# 第 5 步：寄生参数抽取（OpenRCX）→ SPEF；导出 DEF 和布线后网表
# 环境变量 RC_CORNER = min / nom / max，每个 RC corner 各跑一次（run.sh 里循环）
#   min ≈ Cbest（线宽窄、介质厚 → 电容小），给 hold 用
#   max ≈ Cworst（电容大），给 setup 用
# =============================================================================
source config.tcl
set RC_CORNER [env_or RC_CORNER nom]
set DB        [env_or DB 4_route.odb]         ;# ECO 之后改成 9_eco.odb
set RULES $PDK/libs.tech/openlane/rules.openrcx.sky130A.$RC_CORNER.calibre

read_liberty $LIB
read_db $BUILD/$DB
connect_pg_pins

# 按每条网的真实几何（宽度、长度、层、相邻线间距）查规则文件里的 RC 表
# -lef_res：电阻用 LEF 里的方块电阻；耦合电容（相邻线之间）也一起抽出来
define_process_corner -ext_model_index 0 $RC_CORNER
extract_parasitics -ext_model_file $RULES -lef_res
write_spef $BUILD/$DESIGN.$RC_CORNER.spef

if {$RC_CORNER eq "nom"} {
    write_def $BUILD/$DESIGN.def
    # 给 STA / 门级仿真：去掉没有逻辑功能的物理单元（diode 保留：它挂在信号网上，有 liberty 模型）
    write_verilog $BUILD/${DESIGN}_route_all.v
    strip_physical_cells $BUILD/${DESIGN}_route_all.v $BUILD/${DESIGN}_route.v
    file delete $BUILD/${DESIGN}_route_all.v
    # 给 LVS：带电源/地连接，保留全部单元
    write_verilog -include_pwr_gnd $BUILD/${DESIGN}_route_pg.v
    report_design_area
}
exit
