# 通过 Yosys 内置 Tcl 执行。只检查 Tcl 解析，不实现 UPF 命令语义！
set calls {}
foreach command {
    upf_version create_power_domain create_supply_port create_supply_net
    connect_supply_net set_domain_supply_net create_power_switch
    set_isolation set_isolation_control set_retention set_retention_control
    add_port_state create_pst add_pst_state
} {
    proc $command {args} [format {
        lappend ::calls [list %s {*}$args]
    } $command]
}
source [file join [file dirname [info script]] intent_example.upf]
if {[llength $calls] != 23} {error "unexpected example command count"}
puts "PASS Tcl parse only: 23 commands; UPF semantics NOT checked"
