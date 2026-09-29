# ALU 约束：综合（DC 会读）和 STA 共用一份
# 周期可用环境变量 CLK_PERIOD 覆盖（ns）
set CLK_PERIOD [expr {[info exists ::env(CLK_PERIOD)] ? $::env(CLK_PERIOD) : 4.0}]

create_clock -name clk -period $CLK_PERIOD [get_ports clk]
set_clock_uncertainty 0.20 [get_clocks clk]
set_clock_transition  0.10 [get_clocks clk]

# 输入输出都直接进出寄存器，给外部留一半周期
set_input_delay  -clock clk [expr {$CLK_PERIOD * 0.5}] [get_ports {in_valid op[*] a[*] b[*]}]
set_output_delay -clock clk [expr {$CLK_PERIOD * 0.5}] [all_outputs]
set_input_delay  -clock clk 0.5 [get_ports rst_n]

set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 -pin X [get_ports {in_valid op[*] a[*] b[*] rst_n}]
set_load 0.01 [all_outputs]
