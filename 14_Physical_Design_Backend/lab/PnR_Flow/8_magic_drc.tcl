# =============================================================================
# 第 8b 步（Magic）：对最终 GDS 做全规则 DRC
#   OpenROAD 的 detailed_route 只检查它知道的布线规则（间距、最小面积、via 覆盖……），
#   签核 DRC 要在合并后的 GDS 上用代工厂规则再跑一遍（工业上是 Calibre / ICV / Pegasus）
# =============================================================================
drc off
gds readonly true
gds rescale false
gds read build/alu.gds
load alu
select top cell

drc euclidean on
drc style drc(full)
drc check
drc catchup

set f [open reports/8_drc.rpt w]
set total 0
# 坐标单位：Magic 内部 lambda，sky130 下 1 lambda = 0.005 um（这里换算成 um）
foreach {why boxes} [drc listall why] {
    set n [llength $boxes]
    incr total $n
    puts $f "$n  $why"
    foreach b [lrange $boxes 0 4] {
        set um {}
        foreach v $b { lappend um [format %.3f [expr {$v * 0.005}]] }
        puts $f "      at $um"
    }
}
puts $f "TOTAL DRC errors: $total"
close $f
puts "DRC TOTAL errors: $total  (details: reports/8_drc.rpt)"
quit -noprompt
