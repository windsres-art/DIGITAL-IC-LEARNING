# SDC 本身就是 Tcl：可以用变量、expr、循环
# 周期可用环境变量 PERIOD 覆盖（ns）
set PERIOD [expr {[info exists ::env(PERIOD)] ? $::env(PERIOD) : 3.0}]

create_clock -name clk -period $PERIOD [get_ports clk]
set_clock_uncertainty 0.20 [get_clocks clk]

# 数据输入 = 全部输入去掉 clk、rst_n。
# PrimeTime/DC 里写 remove_from_collection [all_inputs] [get_ports {clk rst_n}]；
# 这里用 Tcl 循环按名字过滤，演示集合里的对象要用 get_full_name 取名字
set data_in {}
foreach p [all_inputs] {
    if {[get_full_name $p] ni {clk rst_n}} { lappend data_in $p }
}
set_input_delay  -clock clk [expr {$PERIOD * 0.4}] $data_in
set_input_delay  -clock clk 0.5 [get_ports rst_n]
set_output_delay -clock clk [expr {$PERIOD * 0.4}] [all_outputs]

set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 -pin X [all_inputs]
set_load 0.01 [all_outputs]
