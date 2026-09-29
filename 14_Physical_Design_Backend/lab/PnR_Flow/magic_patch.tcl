# =============================================================================
# DRC 修补（相当于签核 DRC 之后的脚本化 ECO），被 8_magic_gds.tcl 和 8_magic_extract.tcl 共用
#   本机 TritonRoute 在 “met2 →(过孔)→ met3 走极短一段或不走 →(过孔)→ met4” 的地方，
#   两个过孔的 met3 着陆块拼起来只有 0.11–0.19 um²，小于 met3.6 要求的 0.24 um²。
#   做法：找出这些 met3 小块，沿长边方向加长到 0.26 um²（同一条线自己加长）；
#   修补后必须重新跑 DRC 和 LVS：加长的金属若盖到别的网上，DRC 看不出来（只是一块更大的金属），
#   只有 LVS 能发现短路
# 坐标：Magic 内部单位，sky130 下 1 单位 = 0.005 um → 0.26 um² = 10400 单位²
# =============================================================================
proc patch_met3_min_area {} {
    drc euclidean on
    drc style drc(full)
    drc check
    drc catchup
    set boxes {}
    foreach {why bl} [drc listall why] {
        if {[string match "*met3.6*" $why]} { foreach b $bl { lappend boxes $b } }
    }
    # DRC 报的是这块 met3 去掉过孔（Magic 里过孔是单独的 contact 图块）后剩下的碎片，
    # 碎片之间隔着一个过孔着陆块（约 0.33 um = 66 单位），用 70 单位的容差反复合并成整块外框
    set shapes $boxes
    set changed 1
    while {$changed} {
        set changed 0
        set out {}
        foreach b $shapes {
            lassign $b x1 y1 x2 y2
            set hit -1
            for {set i 0} {$i < [llength $out]} {incr i} {
                lassign [lindex $out $i] a1 b1 a2 b2
                if {$x1 <= $a2 + 70 && $x2 >= $a1 - 70 && $y1 <= $b2 + 70 && $y2 >= $b1 - 70} {
                    lset out $i [list [expr {min($x1,$a1)}] [expr {min($y1,$b1)}] \
                                      [expr {max($x2,$a2)}] [expr {max($y2,$b2)}]]
                    set hit $i
                    set changed 1
                    break
                }
            }
            if {$hit < 0} { lappend out $b }
        }
        set shapes $out
    }
    set fixed 0
    foreach s $shapes {
        lassign $s x1 y1 x2 y2
        set w [expr {$x2 - $x1}]
        set h [expr {$y2 - $y1}]
        if {$w >= $h} {
            set ext [expr {int(ceil((10400.0 / $h - $w) / 2.0))}]
            set x1 [expr {$x1 - $ext}]; set x2 [expr {$x2 + $ext}]
        } else {
            set ext [expr {int(ceil((10400.0 / $w - $h) / 2.0))}]
            set y1 [expr {$y1 - $ext}]; set y2 [expr {$y2 + $ext}]
        }
        # 每侧最多加长 0.25 um（单独一个 0.33x0.33 叠孔着陆块需要 0.23 um）；
        # 超过说明外框没合并对，宁可不修，留给 DRC 报出来
        if {$ext > 50} {
            puts "DRC_PATCH skip [expr {$x1*0.005}] [expr {$y1*0.005}] (ext $ext)"
            continue
        }
        # 后缀 i = 内部单位
        box values ${x1}i ${y1}i ${x2}i ${y2}i
        paint m3
        incr fixed
    }
    puts "DRC_PATCH met3.6: [llength $boxes] error edges -> [llength $shapes] shapes, $fixed extended"
    drc off
    select top cell
}

proc maybe_patch {} {
    if {![info exists ::env(DRC_PATCH)] || $::env(DRC_PATCH) != 0} {
        patch_met3_min_area
    }
}
