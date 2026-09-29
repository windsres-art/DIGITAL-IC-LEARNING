# =============================================================================
# OpenSTA 分析脚本：读库 → 读网表 → link → 读 SDC → 出报告
# 用法（WSL）：sta -no_init -exit sta.tcl
# PrimeTime 的命令几乎同名（read_db/read_verilog/link_design/read_sdc/report_timing）
# =============================================================================

read_liberty build/lib.lib
read_verilog build/fifo_netlist.v
link_design  FIFO_async
read_sdc     fifo.sdc

puts "\n==================== 约束完整性检查 ===================="
# 没约束的端点、没时钟的寄存器、组合环……签核前必须干净
check_setup -verbose

puts "\n==================== 时钟 ===================="
report_clock_properties

puts "\n==================== Setup（max delay）最差路径 ===================="
report_checks -path_delay max -format full_clock_expanded \
    -fields {slew cap input_pins fanout} -digits 3

puts "\n==================== Hold（min delay）最差路径 ===================="
report_checks -path_delay min -format full_clock_expanded \
    -fields {slew cap input_pins fanout} -digits 3

puts "\n==================== 每个时钟组各取最差 1 条（setup） ===================="
report_checks -path_delay max -group_count 1 -endpoint_count 1 \
    -format end -digits 3

puts "\n==================== 汇总 ===================="
report_wns
report_tns
report_worst_slack -max
report_worst_slack -min

puts "\n==================== DRV：slew / cap / fanout 违例 ===================="
report_check_types -max_slew -max_capacitance -max_fanout -violators
