# OpenSTA：读映射后的网表，报告最差 setup 路径与 WNS
# 环境变量 NETLIST 指定网表（默认 build/alu_netlist.v）
set NETLIST [expr {[info exists ::env(NETLIST)] ? $::env(NETLIST) : "build/alu_netlist.v"}]

read_liberty build/lib.lib
read_verilog $NETLIST
link_design  alu
read_sdc     alu.sdc

report_checks -path_delay max -format full -digits 3
report_wns
report_tns
report_worst_slack -max
report_worst_slack -min

# 功耗：没有仿真波形时，给所有输入一个假定翻转率（每周期翻转概率 0.2），
# 工具沿网表传播出内部节点的翻转率再算功耗。有 VCD/SAIF 时结果更可信
set_power_activity -input -activity 0.2
report_power
