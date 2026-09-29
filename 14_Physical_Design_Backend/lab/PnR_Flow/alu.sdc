# ALU 后端约束：布局布线各阶段和签核 STA 共用
# 周期可用环境变量 CLK_PERIOD 覆盖（ns）
# 调用方在 CTS 之后先 set ::POST_CTS 1 再读本文件：
#   CTS 前 uncertainty 要包含“估计的 skew”，CTS 后 skew 由真实时钟树算出，只留 jitter + margin
set CLK_PERIOD [expr {[info exists ::env(CLK_PERIOD)] ? $::env(CLK_PERIOD) : 5.0}]
set POST_CTS   [expr {[info exists ::POST_CTS] ? $::POST_CTS : 0}]

create_clock -name clk -period $CLK_PERIOD [get_ports clk]
set_clock_transition 0.15 [get_clocks clk]

if {$POST_CTS} {
    set_propagated_clock [all_clocks]
    set_clock_uncertainty -setup 0.10 [get_clocks clk]
    set_clock_uncertainty -hold  0.05 [get_clocks clk]
} else {
    set_clock_uncertainty -setup 0.30 [get_clocks clk]
    set_clock_uncertainty -hold  0.10 [get_clocks clk]
}

set data_in [get_ports {in_valid op[*] a[*] b[*]}]
set_input_delay  -clock clk [expr {$CLK_PERIOD * 0.3}] $data_in
set_input_delay  -clock clk 0.5 [get_ports rst_n]
set_output_delay -clock clk [expr {$CLK_PERIOD * 0.3}] [all_outputs]

set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 -pin X [get_ports {in_valid op[*] a[*] b[*] rst_n}]
# 时钟也来自片上某个驱动（PLL 输出 buffer 等），不是理想源；CTS 前后对比时才看得出单根时钟网带不动
set_driving_cell -lib_cell sky130_fd_sc_hd__clkbuf_4 -pin X [get_ports clk]
set_load 0.02 [all_outputs]

set_max_fanout     16  [current_design]
set_max_transition 1.0 [current_design]
