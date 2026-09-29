# =============================================================================
# 第 6 步：签核 STA（OpenSTA）：布线后网表 + 抽取的 SPEF + 多个 PVT/RC 组合
#   setup 看慢 corner：ss 100°C 1.60V + RC max
#   hold  看快 corner：ff -40°C 1.95V + RC min（其它 corner 的 hold 也要看，这里一起报）
#   tt 25°C 1.80V + RC nom 作为典型值
# PrimeTime 的签核脚本结构相同，见 ../../../07_STA/README.md 第 13 节
# =============================================================================
set HD /root/micromamba/envs/orfs/share/pdk/sky130A/libs.ref/sky130_fd_sc_hd/lib
set BUILD [expr {[info exists ::env(BUILD)] ? $::env(BUILD) : "build"}]

define_corners ss tt ff
read_liberty -corner ss $HD/sky130_fd_sc_hd__ss_100C_1v60.lib
read_liberty -corner tt $HD/sky130_fd_sc_hd__tt_025C_1v80.lib
read_liberty -corner ff $HD/sky130_fd_sc_hd__ff_n40C_1v95.lib

read_verilog $BUILD/alu_route.v
link_design  alu
set ::POST_CTS 1
read_sdc alu.sdc

read_spef -corner ss $BUILD/alu.max.spef
read_spef -corner tt $BUILD/alu.nom.spef
read_spef -corner ff $BUILD/alu.min.spef

puts "\n==================== 约束完整性 ===================="
check_setup -verbose

puts "\n==================== 每个 corner 的 WNS / 最差 hold ===================="
foreach c {ss tt ff} {
    set ws [sta::worst_slack_corner [sta::find_corner $c] max]
    set wh [sta::worst_slack_corner [sta::find_corner $c] min]
    puts [format "CORNER %-3s setup_ws %8.3f   hold_ws %8.3f" $c \
              [sta::time_sta_ui $ws] [sta::time_sta_ui $wh]]
}

puts "\n==================== Setup 最差路径（tt）===================="
report_checks -path_delay max -corner tt -format full_clock_expanded \
    -fields {slew cap fanout} -digits 3

puts "\n==================== Setup 最差路径（ss）===================="
report_checks -path_delay max -corner ss -format end -group_count 5 -digits 3

puts "\n==================== Hold 最差路径（ff）===================="
report_checks -path_delay min -corner ff -format full_clock_expanded \
    -fields {slew cap} -digits 3

# hold 并不只在快 corner 出问题：慢 corner 下 removal/hold 时间本身也变大
puts "\n==================== Hold 最差路径（ss）===================="
report_checks -path_delay min -corner ss -format full_clock_expanded \
    -fields {slew cap} -digits 3

puts "\n==================== 时钟 skew（tt）===================="
report_clock_skew -corner tt

puts "\n==================== DRV ===================="
report_check_types -max_slew -max_capacitance -max_fanout -violators

puts "\n==================== 功耗（tt，默认翻转率）===================="
report_power -corner tt
