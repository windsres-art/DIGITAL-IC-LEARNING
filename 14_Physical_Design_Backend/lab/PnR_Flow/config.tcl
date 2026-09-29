# =============================================================================
# 各阶段脚本共用的设置：工艺文件、可调参数、RC、dont_use、读入上一阶段
# 可调参数都能用环境变量覆盖，run_experiments.sh 就是靠它做扫描
# =============================================================================
proc env_or {name default} {
    if {[info exists ::env($name)]} { return $::env($name) }
    return $default
}

set PDK  /root/micromamba/envs/orfs/share/pdk/sky130A
set HD   $PDK/libs.ref/sky130_fd_sc_hd
set TLEF $HD/techlef/sky130_fd_sc_hd__nom.tlef
set LEF  $HD/lef/sky130_fd_sc_hd.lef
set LIB  $HD/lib/sky130_fd_sc_hd__tt_025C_1v80.lib

set DESIGN        alu
set BUILD         [env_or BUILD build]        ;# 实验时指向别的目录，互不覆盖
set REPORTS       [env_or REPORTS reports]
set UTIL          [env_or UTIL 40]            ;# 布图：核心区利用率（%）
set PLACE_DENSITY [env_or PLACE_DENSITY 0.60] ;# 全局布局：每个 bin 的目标密度
set STRAP_PITCH   [env_or STRAP_PITCH 27.2]   ;# 电源网络：met4/met5 条带间距（um）
set DO_REPAIR     [env_or DO_REPAIR 1]        ;# 0 = 关掉 repair_design / repair_timing 做对比

file mkdir $BUILD $REPORTS

# -----------------------------------------------------------------------------
# 单位长度 RC（来自 OpenROAD-flow-scripts 的 sky130hd setRC.tcl）
# 布线前用它估算线延时；布线后由 OpenRCX 按真实几何抽取，精度更高
# -----------------------------------------------------------------------------
proc set_rc {} {
    set_layer_rc -layer li1  -capacitance 1.499e-04   -resistance 7.176e-02
    set_layer_rc -layer met1 -capacitance 1.72375E-04 -resistance 1.20565E-03
    set_layer_rc -layer met2 -capacitance 1.36233E-04 -resistance 1.22132E-03
    set_layer_rc -layer met3 -capacitance 2.14962E-04 -resistance 1.66281E-04
    set_layer_rc -layer met4 -capacitance 1.48128E-04 -resistance 1.68093E-04
    set_layer_rc -layer met5 -capacitance 1.54087E-04 -resistance 1.83558E-05
    set_layer_rc -via mcon -resistance 9.249146E-3
    set_layer_rc -via via  -resistance 4.5E-3
    set_layer_rc -via via2 -resistance 3.368786E-3
    set_layer_rc -via via3 -resistance 0.376635E-3
    set_layer_rc -via via4 -resistance 0.00580E-3
    # 估算时假设信号线走 met2、时钟线走 met3
    set_wire_rc -signal -layer met2
    set_wire_rc -clock  -layer met3
}

# 优化命令插 buffer / 换单元时不许用的单元：
#   probe、lpflow（低功耗专用）不是普通逻辑单元；decap、diode 是物理单元
#   （fill、tap 在 liberty 里本来就没有，不用列）
proc set_dont_use_cells {} {
    foreach pat {sky130_fd_sc_hd__probe* sky130_fd_sc_hd__lpflow_* sky130_fd_sc_hd__decap_*
                 sky130_fd_sc_hd__diode_*} {
        set_dont_use [get_lib_cells */$pat]
    }
}

# 读入上一阶段的数据库。OpenDB 保存了 LEF 和物理信息，但不保存 liberty 与 SDC，要重新读
proc load_stage {db {post_cts 0}} {
    global LIB BUILD
    read_liberty $LIB
    read_db $BUILD/$db
    set ::POST_CTS $post_cts
    read_sdc alu.sdc
    set_rc
    set_dont_use_cells
}

# fill / tap 在 liberty 里没有，write_verilog -remove_cells 删不掉；它们在网表里都是 "cell inst ();"
# 这种没有端口的单行实例，给 STA / 门级仿真用的网表直接按行过滤掉
proc strip_physical_cells {src dst} {
    set fi [open $src r]
    set fo [open $dst w]
    while {[gets $fi line] >= 0} {
        if {[regexp {^\s*sky130_fd_sc_hd__(fill|tapvpwrvgnd|decap)_\d+\s+\S+\s+\(\);} $line]} continue
        puts $fo $line
    }
    close $fi
    close $fo
}

proc iterm_connect {iterm net} {
    if {[catch {$iterm connect $net}]} { odb::dbITerm_connect $iterm $net }
}

# 全局电源连接（add_global_connection）只在 pdngen 执行时套用一次；
# 之后 repair_design / CTS / hold 修复 / ECO 新插的单元，电源脚在数据库里是悬空的。
# 物理上它们贴着 met1 电源轨，版图是通的，但网表里没有 → LVS 对不上、IR 分析漏算这些单元的电流
# 所以每个阶段写库前都补连一次
proc connect_pg_pins {} {
    set block [ord::get_db_block]
    set vdd [$block findNet VDD]
    set vss [$block findNet VSS]
    set n 0
    foreach inst [$block getInsts] {
        foreach it [$inst getITerms] {
            if {[$it getNet] ne "NULL" && [$it getNet] ne ""} continue
            switch [[$it getMTerm] getName] {
                VPWR - VPB { iterm_connect $it $vdd; incr n }
                VGND - VNB { iterm_connect $it $vss; incr n }
            }
        }
    }
    puts "PG connected $n floating power/ground pins"
}

# 天线二极管：每个数据输入端口网在它的第一个负载旁边放一个 diode_2
# 输入端口到内部单元往往是一根长线，是天线违例的高发区（本 lab 的违例全在这里）
proc insert_input_diodes {} {
    set block  [ord::get_db_block]
    set master [[ord::get_db] findMaster sky130_fd_sc_hd__diode_2]
    set vdd [$block findNet VDD]
    set vss [$block findNet VSS]
    set n 0
    foreach bterm [$block getBTerms] {
        set name [$bterm getName]
        if {[$bterm getIoType] ne "INPUT" || $name eq "clk" || $name eq "rst_n"} continue
        set net  [$bterm getNet]
        set sink ""
        foreach it [$net getITerms] {
            if {[$it isInputSignal]} { set sink $it; break }
        }
        if {$sink eq ""} continue
        set inst [odb::dbInst_create $block $master "ANTENNA_$n"]
        iterm_connect [$inst findITerm DIODE] $net
        iterm_connect [$inst findITerm VPWR] $vdd
        iterm_connect [$inst findITerm VPB]  $vdd
        iterm_connect [$inst findITerm VGND] $vss
        iterm_connect [$inst findITerm VNB]  $vss
        set loc [[$sink getInst] getLocation]
        $inst setLocation [lindex $loc 0] [lindex $loc 1]
        $inst setPlacementStatus PLACED
        incr n
    }
    puts "ANTENNA inserted $n diodes on input nets"
}

# ECO 前要把 filler 拿掉，给换大/新插的单元腾位置
proc remove_fillers {} {
    set block [ord::get_db_block]
    set n 0
    foreach inst [$block getInsts] {
        if {[string match sky130_fd_sc_hd__fill_* [[$inst getMaster] getName]]} {
            odb::dbInst_destroy $inst
            incr n
        }
    }
    puts "removed $n fillers"
}

# 删掉所有信号网的布线（电源网是 special wire，不受影响）；单元挪动后旧线会变成非法几何
proc clear_signal_routes {} {
    set n 0
    foreach net [[ord::get_db_block] getNets] {
        if {[$net isSpecial]} continue
        set wire [$net getWire]
        if {$wire ne "NULL" && $wire ne ""} {
            odb::dbWire_destroy $wire
            incr n
        }
    }
    puts "cleared routing of $n nets"
}

# 简短的时序汇总：一行 setup、一行 hold
proc timing_summary {tag} {
    set ws [sta::worst_slack_cmd max]
    set wh [sta::worst_slack_cmd min]
    set tns [sta::total_negative_slack_cmd max]
    puts [format "TIMING %-22s setup_ws %8.3f  tns %8.3f  hold_ws %8.3f" \
              $tag [sta::time_sta_ui $ws] [sta::time_sta_ui $tns] [sta::time_sta_ui $wh]]
}
