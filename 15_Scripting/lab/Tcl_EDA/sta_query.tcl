# =============================================================================
# EDA 工具里的 Tcl：用集合（collection）查询网表和时序
# 用法：sta -no_init -exit sta_query.tcl（由 run.sh 调用）
# OpenSTA 的命令名与 PrimeTime 基本一致；差别见 README 第 1.4 节
# =============================================================================
read_liberty build/lib.lib
read_verilog build/alu_netlist.v
link_design  alu
read_sdc     alu.sdc

set ::fails 0
proc check {name got expect} {
    if {$got eq $expect} {
        puts [format "  ok    %-24s = %s" $name $got]
    } else {
        puts [format "  FAIL  %-24s = %s（期望 %s）" $name $got $expect]
        incr ::fails
    }
}

# -----------------------------------------------------------------------------
puts "== 1. 集合里装的是对象句柄，不是名字 =="
set regs [all_registers]
set r0   [lindex $regs 0]
puts "  all_registers 返回 [llength $regs] 个对象"
puts "  直接打印第一个：$r0"
puts "  get_full_name ：[get_full_name $r0]   ref_name：[get_property $r0 ref_name]"
# ALU：输入寄存器 op(3)+a(16)+b(16)+valid(1)，输出寄存器 y(16)+zero+out_valid → 54
check "寄存器个数" [llength $regs] 54

# -----------------------------------------------------------------------------
puts "== 2. 按单元类型统计数量和面积（dict）=="
set cnt [dict create]
foreach c [get_cells *] { dict incr cnt [get_property $c ref_name] }
set total_area 0.0
dict for {ref n} $cnt {
    set a [get_property [get_lib_cells */$ref] area]
    set total_area [expr {$total_area + $n * $a}]
}
# -stride 2 把 dict 当 {键 值} 对排序，-index 1 按值（个数）降序；取前 5 对 = 10 个元素
set top [lrange [lsort -stride 2 -index 1 -integer -decreasing $cnt] 0 9]
foreach {ref n} $top { puts [format "    %-28s %4d" $ref $n] }
puts [format "  单元总数 %d，总面积 %.3f um^2" [llength [get_cells *]] $total_area]

# 与 Yosys 的 stat 报告交叉核对：两个工具独立数出来的结果应一致
set fh [open reports/synth.stat r]; set stat [read $fh]; close $fh
regexp {\n\s+(\d+)\s+\S+\s+cells\n} $stat -> ys_cells
regexp {Chip area for module '\\alu': ([\d.]+)} $stat -> ys_area
check "单元数 = Yosys stat" [llength [get_cells *]] $ys_cells
check "面积 = Yosys stat"   [format %.3f $total_area] [format %.3f $ys_area]

# -----------------------------------------------------------------------------
puts "== 3. 过滤与关系查询：-filter、-of_objects =="
set rst_pins [get_pins -of_objects $regs -filter "direction == input"]
set rst_pins [lsearch -all -inline -glob [lmap p $rst_pins {get_full_name $p}] */RESET_B]
check "RESET_B 引脚数" [llength $rst_pins] 54

# 找高扇出线网：每条 net 数它连接的输入引脚（负载）
set fo {}
foreach n [get_nets *] {
    set loads [get_pins -of_objects $n -filter "direction == input"]
    lappend fo [list [get_full_name $n] [llength $loads]]
}
set fo [lsort -index 1 -integer -decreasing $fo]
puts "  扇出最大的 5 条线网："
foreach item [lrange $fo 0 4] { puts [format "    %-12s %3d" {*}$item] }
set fo_dict [dict create {*}[join $fo]]
check "rst_n 扇出" [dict get $fo_dict rst_n] 54
check "clk 扇出"   [dict get $fo_dict clk]   54

# -----------------------------------------------------------------------------
puts "== 4. 时序路径：find_timing_paths 取出每个端点的最差 slack =="
set paths [find_timing_paths -path_delay max -group_count 10000 -endpoint_count 1 -sort_by_slack]
set rows {}
foreach p $paths {
    set ep [get_full_name [get_property $p endpoint]]
    lappend rows [list $ep [format %.3f [get_property $p slack]]]
}
# 综合后寄存器实例名是 _1003_ 这类自动名，看不出是哪个信号；
# 顺着 实例 → Q 引脚 → 线网 反查，线网名保留了 RTL 里的寄存器名
proc reg_signal {ep} {
    set inst [lindex [split $ep /] 0]
    if {[catch {get_nets -of_objects [get_pins $inst/Q]} n] || $n eq ""} { return "-" }
    return [get_full_name $n]
}
puts "  有约束的端点 [llength $rows] 个，最差 5 个："
foreach r [lrange $rows 0 4] {
    puts [format "    %-12s %8s   Q 端线网 %s" {*}$r [reg_signal [lindex $r 0]]]
}

# slack 直方图：proc 里用 upvar 修改调用者的数组
proc bin_slack {rows arrname step} {
    upvar 1 $arrname h
    foreach r $rows {
        set b [expr {int(floor([lindex $r 1] / $step))}]
        incr h($b)
    }
}
array set hist {}
bin_slack $rows hist 0.5
puts "  slack 分布（每 0.5 ns 一档）："
foreach b [lsort -integer [array names hist]] {
    puts [format "    \[%5.1f, %5.1f)  %3d  %s" [expr {$b*0.5}] [expr {($b+1)*0.5}] \
            $hist($b) [string repeat # [expr {($hist($b)+1)/2}]]]
}
set nviol 0
foreach r $rows { if {[lindex $r 1] < 0} { incr nviol } }
puts "  违例端点 $nviol 个"

# 导出 CSV 给 Python 用
set fh [open reports/endpoint_slack.csv w]
puts $fh "endpoint,slack_ns"
foreach r $rows { puts $fh [join $r ,] }
close $fh

# 同时写一份标准文本报告，给 Python 解析（OpenSTA 支持 > 重定向到文件）
report_checks -path_delay max -group_count 20 -endpoint_count 1 -digits 3 > reports/sta_paths.rpt
report_wns
report_tns

# -----------------------------------------------------------------------------
puts ""
if {$::fails == 0} { puts "PASS sta_query" } else { puts "FAIL sta_query: $::fails 项不符"; exit 1 }
