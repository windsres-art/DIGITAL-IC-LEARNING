# =============================================================================
# 第 9 步：时序 ECO（Engineering Change Order）
#   签核 STA 发现违例 → 在已布线的设计上做小改动（换单元尺寸 / 插 buffer）→ 重新合法化、布线
#   工业流程：PrimeTime 的 fix_eco_timing 生成改动脚本 → Innovus/ICC2 执行 + ECO route（只重布改到的网）
#   本机 OpenROAD 没有增量 ECO 布线，这里改完后整体重新布线（设计很小，约 2 分钟）
# =============================================================================
source config.tcl
set ECO_MARGIN [env_or ECO_MARGIN 0.10]
load_stage 4_route.odb 1
set_routing_layers -signal met1-met4 -clock met3-met4

# 用签核同款寄生（OpenRCX 抽出的 SPEF）看时序，保证 ECO 修的是真违例
read_spef $BUILD/alu.nom.spef
timing_summary "ECO before"
report_checks -path_delay max -format end -group_count 5 -digits 3

set before [llength [get_cells *]]
# -slack_margin：修到 slack ≥ margin 为止，给重新布线带来的变化留余量
repair_timing -setup -slack_margin $ECO_MARGIN
puts "ECO cells before [set before]  after [llength [get_cells *]]"
timing_summary "ECO after sizing (old routes)"

# ---------------------------------------------------------------- 物理实施
remove_fillers
clear_signal_routes
detailed_placement
check_placement -verbose
filler_placement {sky130_fd_sc_hd__fill_1 sky130_fd_sc_hd__fill_2 \
                  sky130_fd_sc_hd__fill_4 sky130_fd_sc_hd__fill_8}
global_route -guide_file $BUILD/route_eco.guide -congestion_iterations 50
detailed_route -guide $BUILD/route_eco.guide -output_drc $REPORTS/9_eco_drc.rpt \
               -bottom_routing_layer met1 -top_routing_layer met4 \
               -droute_end_iter 20 -verbose 0
check_antennas -report_file $REPORTS/9_eco_antenna.rpt

connect_pg_pins
write_db $BUILD/9_eco.odb
exit
