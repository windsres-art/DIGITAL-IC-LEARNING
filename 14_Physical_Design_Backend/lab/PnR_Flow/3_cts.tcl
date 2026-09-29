# =============================================================================
# 第 3 步：时钟树综合（CTS）+ CTS 后时序优化
# =============================================================================
source config.tcl
load_stage 2_place.odb

# ---------------------------------------------------------------- 没有时钟树会怎样
# 把时钟设成 propagated 但还没建树：clk 端口的一个驱动直接带全部触发器
set clk_net [get_nets clk]
puts "CTS_BEFORE clk 网直接驱动的 sink 数: [llength [get_pins -of_objects $clk_net -filter {direction == input}]]"
set_propagated_clock [all_clocks]
estimate_parasitics -placement
report_clock_skew
report_check_types -max_slew -max_capacitance -violators

# ---------------------------------------------------------------- CTS
# 目标：把时钟以可控的延时（latency）和很小的偏差（skew）送到每个触发器
#   root_buf：树根的大驱动 buffer；buf_list：树里可用的 buffer（时钟专用 clkbuf，上升下降对称）
#   sink_clustering：先把位置相近的触发器聚成簇，每簇一个 buffer，再往上建树
clock_tree_synthesis -root_buf sky130_fd_sc_hd__clkbuf_8 \
    -buf_list {sky130_fd_sc_hd__clkbuf_2 sky130_fd_sc_hd__clkbuf_4 sky130_fd_sc_hd__clkbuf_8} \
    -sink_clustering_enable -sink_clustering_size 20 -sink_clustering_max_diameter 60
# 时钟树中长线的线长补偿 buffer
repair_clock_nets
detailed_placement

# ---------------------------------------------------------------- 真实时钟下看时序
# CTS 后换成 post-CTS 的 SDC：propagated clock + 更小的 uncertainty
set ::POST_CTS 1
read_sdc alu.sdc
estimate_parasitics -placement
puts "---- 时钟树 ----"
report_clock_skew
report_clock_skew -hold
puts "CTS clock buffers: [llength [get_cells clkbuf_*]]"
report_checks -path_delay max -format full_clock_expanded -fields {slew cap fanout} -digits 3
report_checks -path_delay min -format full_clock_expanded -fields {slew cap fanout} -digits 3
timing_summary "after CTS"

# ---------------------------------------------------------------- CTS 后优化
# 真实 skew 出来后才能修 hold：同一时钟沿上，capture 时钟晚到就可能 hold 违例
# repair_timing -hold 在数据路径插 delay buffer；-slack_margin 多留一点余量给布线后的变化
if {$DO_REPAIR} {
    repair_timing -setup
    repair_timing -hold -slack_margin 0.05
    detailed_placement
    check_placement -verbose
    estimate_parasitics -placement
    timing_summary "after CTS repair"
}
report_design_area

connect_pg_pins
write_db $BUILD/3_cts.odb
exit
