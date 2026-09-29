# =============================================================================
# Tcl 语法速通：EDA 脚本里最常用、最容易踩坑的部分
# 用法：tclsh tcl_basics.tcl（由 run.sh 调用；tclsh 在 orfs 环境里）
# 每个知识点都用 check 自检，最后打印 PASS / FAIL
# =============================================================================

set ::fails 0
# 自检工具：比较实际值与期望值
proc check {name got expect} {
    if {$got eq $expect} {
        puts [format "  ok    %-28s = %s" $name $got]
    } else {
        puts [format "  FAIL  %-28s = %s（期望 %s）" $name $got $expect]
        incr ::fails
    }
}

# -----------------------------------------------------------------------------
puts "== 1. 置换：\$ 变量、\[\] 命令、\"\" 与 {} =="
# Tcl 只有一条规则：先置换，再按空白切分成单词，第一个单词是命令
set period 4.0
set half   [expr {$period / 2}]            ;# [] 里是命令，结果替换回来
check "expr 半周期"            $half        2.0
check {"" 内做置换}            "T=$period"  "T=4.0"
check {{} 内不置换}            {T=$period}  "T=\$period"
# 坑：expr 不加花括号，变量先被字符串置换再解析，既慢又可能被注入
set a 3; set b "2+1"
check "expr {\$a*\$b} 报错"    [catch {expr {$a * $b}}] 1   ;# b 只是字符串 "2+1"，不是数
check "expr \$a*\$b 二次解析"   [expr $a*$b]    7            ;# 先拼成 3*2+1 再算
# 坑：整数除法
check "整数除法 7/2"           [expr {7 / 2}]   3
check "浮点除法 7.0/2"         [expr {7.0 / 2}] 3.5

# -----------------------------------------------------------------------------
puts "== 2. 列表 =="
set cells {dfrtp_1 nand2_1 xor2_1 nand2_1 dfrtp_1 a21oi_1}
check "llength"                [llength $cells]            6
check "lindex 末尾"            [lindex $cells end]         a21oi_1
check "lsort -unique"          [lsort -unique $cells]      "a21oi_1 dfrtp_1 nand2_1 xor2_1"
check "lsearch -all -glob"     [llength [lsearch -all -glob $cells nand*]] 2
lappend cells mux2_1                                      ;# lappend 传变量名，不带 $
check "lappend 后长度"         [llength $cells]            7
# 坑：带空格的字符串就是多元素列表。本机路径 "DIGITAL IC LEARNING" 在 Tcl 眼里是 3 个元素，
# 某些工具命令把参数当列表处理时会把路径拆散，所以脚本里先 cd 再用相对路径最稳
set path "/mnt/c/DIGITAL IC LEARNING/07_STA"
check "带空格的路径当列表"     [llength $path]             3
check "split 按 / 切分"        [lindex [split $path /] end] 07_STA
check "join"                   [join {a b c} ,]            a,b,c
# lsort -dictionary 让 reg[2] 排在 reg[10] 前面（按数字而不是按字符）
check "lsort -dictionary"      [join [lsort -dictionary {y[10] y[2] y[1]}]] "y\[1\] y\[2\] y\[10\]"

# -----------------------------------------------------------------------------
puts "== 3. 数组与 dict：做统计 =="
# 数组（array）：关联表，键是字符串
foreach c $cells { incr cnt($c) }                        ;# 8.5 起 incr 不存在的元素自动从 0 开始
check "array nand2_1 个数"     $cnt(nand2_1)               2
check "array 键数"             [array size cnt]            5
# dict：值语义，可以当普通变量传给 proc、嵌套
set lib [dict create nand2_1 3.75 dfrtp_1 25.02 xor2_1 8.76 a21oi_1 5.00 mux2_1 11.26]
set area 0.0
foreach c $cells { set area [expr {$area + [dict get $lib $c]}] }
check "总面积"                 [format %.2f $area]         82.56
check "dict exists"            [dict exists $lib inv_1]    0

# -----------------------------------------------------------------------------
puts "== 4. proc：默认参数、可变参数、upvar =="
# 默认参数 + 返回值
proc clk_freq {period {unit ns}} {
    if {$unit eq "ns"} { return [expr {1000.0 / $period}] }
    return [expr {1.0 / $period}]
}
check "默认参数 250MHz"        [clk_freq 4.0]              250.0
# args：可变参数，收成一个列表
proc sum {args} { set s 0; foreach x $args { set s [expr {$s + $x}] }; return $s }
check "args 可变参数"          [sum 1 2 3 4]               10
# upvar：按引用修改调用者的变量（Tcl 默认是传值）
proc add_margin {varname margin} { upvar 1 $varname v; set v [expr {$v - $margin}] }
set required 3.8
add_margin required 0.2
# 坑：浮点数不能直接用 eq 比较，3.8-0.2 的结果是 3.5999999999999996，先 format 再比
check "浮点直接比较"           [expr {$required == 3.6}]   0
check "upvar 修改外部变量"     [format %.3f $required]     3.600
# 坑：proc 里看不到外面的变量，要 global 或 ::
set ::top_design alu
proc get_top {} { return $::top_design }
check "::全局变量"             [get_top]                   alu

# -----------------------------------------------------------------------------
puts "== 5. 字符串与正则：解析报告行 =="
set line "                              1.790   slack (MET)"
check "regexp 抓 slack"        [regexp {(-?[\d.]+)\s+slack \((\w+)\)} $line -> s st] 1
check "slack 数值"             $s                          1.790
check "slack 状态"             $st                         MET
set pin "_1287_/D (sky130_fd_sc_hd__dfrtp_1)"
regexp {^(\S+)/(\S+)\s+\((\S+)\)} $pin -> inst pinname ref
check "实例/引脚/单元"         "$inst $pinname $ref"       "_1287_ D sky130_fd_sc_hd__dfrtp_1"
check "string map 去前缀"      [string map {sky130_fd_sc_hd__ ""} $ref] dfrtp_1
check "string match 通配"      [string match {*dfr*} $ref] 1
check "format 对齐"            [format {%-8s|%6.2f} wns -0.5] "wns     | -0.50"
# regsub：批量改名，例如把总线下标 a[3] 改成 a_3_
check "regsub 改总线名"        [regsub -all {\[(\d+)\]} {a[3] b[12]} {_\1_}] "a_3_ b_12_"

# -----------------------------------------------------------------------------
puts "== 6. 文件读写与 catch =="
set tmp [file join [pwd] build tcl_demo.rpt]
file mkdir [file dirname $tmp]
set fh [open $tmp w]
puts $fh "Endpoint: y\[3\]\n  -0.120   slack (VIOLATED)\nEndpoint: y\[4\]\n   0.350   slack (MET)"
close $fh
# 逐行读：gets 返回读到的字符数，文件尾返回 -1
set fh [open $tmp r]
set viol {}
while {[gets $fh l] >= 0} {
    if {[regexp {^Endpoint: (\S+)} $l -> ep]} { continue }
    if {[regexp {(-?[\d.]+)\s+slack \(VIOLATED\)} $l -> sl]} { lappend viol [list $ep $sl] }
}
close $fh
check "违例端点个数"           [llength $viol]             1
check "违例端点名与 slack"     [join [lindex $viol 0] " "] "y\[3\] -0.120"
# catch：命令出错不中断脚本，返回 1 并把错误信息放进变量
check "catch 打开不存在文件"   [catch {open /no/such/file r} err] 1
check "错误信息"               [string match {couldn't open*} $err] 1

# -----------------------------------------------------------------------------
puts ""
if {$::fails == 0} {
    puts "PASS tcl_basics (Tcl [info patchlevel])"
} else {
    puts "FAIL tcl_basics: $::fails 项不符"
    exit 1
}
