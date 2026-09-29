# =============================================================================
# Yosys 的 Tcl 模式：yosys -c synth.tcl
# 每条 Yosys 命令前加 "yosys"，其余是普通 Tcl（变量、if、循环都能用）
# 设计复用第 08 章的 16 bit ALU，只做最简单的一次性综合，逐步综合见第 08 章
# =============================================================================
set LIB build/lib.lib
# 源文件用相对路径：run.sh 已 cd 到本目录，避免 "DIGITAL IC LEARNING" 里的空格
set SRC ../../../08_Logic_Synthesis/lab/Yosys_Flow/alu.v
set W   [expr {[info exists ::env(W)] ? $::env(W) : 16}]

yosys read_liberty -lib $LIB
yosys read_verilog $SRC
yosys chparam -set W $W alu
yosys synth -flatten -top alu
yosys dfflibmap -liberty $LIB -dont_use *lpflow*
yosys abc -liberty $LIB -dont_use *lpflow*
yosys hilomap -singleton -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO
yosys opt_clean
yosys check -assert
yosys tee -q -o reports/synth.stat stat -liberty $LIB
yosys write_verilog -noattr build/alu_netlist.v
