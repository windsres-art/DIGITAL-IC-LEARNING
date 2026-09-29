# 通用 STA：NETLIST / TOP / PERIOD 由环境变量给出
# 有 clk 端口就在它上面建时钟；纯组合电路用虚拟时钟，input/output delay 都为 0，
# 这样 "Actual" 列就是端口到端口的组合延时
read_liberty build/lib.lib
read_verilog $::env(NETLIST)
link_design  $::env(TOP)

set period $::env(PERIOD)
if {[llength [get_ports -quiet clk]]} {
    create_clock -name clk -period $period [get_ports clk]
    set inputs [lsearch -all -inline -not -exact [all_inputs] [get_ports clk]]
} else {
    create_clock -name vclk -period $period
    set inputs [all_inputs]
}
set_input_delay  0 -clock [all_clocks] $inputs
set_output_delay 0 -clock [all_clocks] [all_outputs]

report_checks -path_delay max -format end -endpoint_count 1
report_worst_slack -max
