# =============================================================================
# 第 2 步：布局（placement）
#   全局布局（允许重叠，优化线长 + 密度）→ 修 DRV → 详细布局（合法化到 row/site）
# =============================================================================
source config.tcl
load_stage 1_floorplan.odb

# ---------------------------------------------------------------- 全局布局
# -timing_driven：按关键路径给网加权重，把关键路径上的单元拉近
# -density：每个 bin 的目标填充率；越低越“松”，给布线和后续插 buffer 留空间
global_placement -timing_driven -density $PLACE_DENSITY
estimate_parasitics -placement
timing_summary "after global_place"

# ---------------------------------------------------------------- 修 DRV
# 布局后才知道线长，线长决定负载电容：此时检查 max slew / cap / fanout
# repair_design 用插 buffer、拆扇出、换大驱动来修这些违例（相当于 DC/ICC 的 DRC fixing）
puts "---- DRV before repair_design ----"
report_check_types -max_slew -max_capacitance -max_fanout -violators
if {$DO_REPAIR} {
    repair_design
    puts "---- DRV after repair_design ----"
    report_check_types -max_slew -max_capacitance -max_fanout -violators
}

# ---------------------------------------------------------------- 详细布局
# 把每个单元挪到合法的 site 上、消除重叠，尽量不增加线长
detailed_placement
optimize_mirroring
check_placement -verbose
estimate_parasitics -placement
timing_summary "after detailed_place"
report_design_area

connect_pg_pins
write_db $BUILD/2_place.odb
exit
