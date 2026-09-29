# =============================================================================
# 第 1 步：布图规划（floorplan）+ 电源规划（power planning）
#   网表 → 定芯片/核心尺寸 → 放 row 和 track → 放 IO pin → tap/endcap → 电源网络
# =============================================================================
source config.tcl

read_lef     $TLEF
read_lef     $LEF
read_liberty $LIB
read_verilog $BUILD/alu_synth.v
link_design  $DESIGN
read_sdc     alu.sdc

# ---------------------------------------------------------------- 尺寸
# 按目标利用率反推核心面积；core_space = 核心区到芯片边的距离，给电源环和 IO 留地方
initialize_floorplan -utilization $UTIL -aspect_ratio 1 -core_space 8 -site unithd

# 布线轨道（track）：每层金属的走线格点，数值来自 PDK 的 tracks.info
make_tracks li1  -x_offset 0.23 -x_pitch 0.46 -y_offset 0.17 -y_pitch 0.34
make_tracks met1 -x_offset 0.17 -x_pitch 0.34 -y_offset 0.17 -y_pitch 0.34
make_tracks met2 -x_offset 0.23 -x_pitch 0.46 -y_offset 0.23 -y_pitch 0.46
make_tracks met3 -x_offset 0.34 -x_pitch 0.68 -y_offset 0.34 -y_pitch 0.68
make_tracks met4 -x_offset 0.46 -x_pitch 0.92 -y_offset 0.46 -y_pitch 0.92
make_tracks met5 -x_offset 1.70 -x_pitch 3.40 -y_offset 1.70 -y_pitch 3.40

# ---------------------------------------------------------------- IO
# 水平边上的 pin 用 met3，垂直边上的 pin 用 met2（与这两层的优选方向一致）
place_pins -hor_layers met3 -ver_layers met2

# ---------------------------------------------------------------- tap / endcap
# tap：把 N 阱接 VDD、P 衬底接 VSS，防闩锁（latch-up），sky130 要求间距 ≤ 15 um 左右
# endcap：每行两端的边界单元，保证阱在行尾闭合、满足边界 DRC
tapcell -distance 14 \
    -tapcell_master sky130_fd_sc_hd__tapvpwrvgnd_1 \
    -endcap_master  sky130_fd_sc_hd__decap_4

# ---------------------------------------------------------------- 电源网络（PDN）
# 标准单元的 VPWR/VPB 接 VDD，VGND/VNB 接 VSS（VPB/VNB 是阱/衬底偏置脚）
add_global_connection -net VDD -pin_pattern {^VPWR$} -power
add_global_connection -net VDD -pin_pattern {^VPB$}
add_global_connection -net VSS -pin_pattern {^VGND$} -ground
add_global_connection -net VSS -pin_pattern {^VNB$}

set_voltage_domain -name CORE -power VDD -ground VSS
define_pdn_grid -name core_grid -voltage_domains CORE -starts_with POWER
# 电源环：核心区四周一圈 met4（竖）/ met5（横）
add_pdn_ring   -grid core_grid -layers {met4 met5} -widths {1.6 1.6} \
               -spacings {1.6 1.6} -core_offsets {1.6 1.6}
# followpin：沿每一行上下边的 met1 电源轨，单元的 VPWR/VGND 直接接在上面
add_pdn_stripe -grid core_grid -layer met1 -width 0.48 -followpins
# 条带（strap）：met4 竖向、met5 横向，把电流从环送到核心内部
add_pdn_stripe -grid core_grid -layer met4 -width 1.6 -pitch $STRAP_PITCH \
               -offset [expr {$STRAP_PITCH / 2}] -extend_to_core_ring
add_pdn_stripe -grid core_grid -layer met5 -width 1.6 -pitch $STRAP_PITCH \
               -offset [expr {$STRAP_PITCH / 2}] -extend_to_core_ring
add_pdn_connect -grid core_grid -layers {met1 met4}
add_pdn_connect -grid core_grid -layers {met4 met5}
pdngen

# ---------------------------------------------------------------- 报告
set block [ord::get_db_block]
set die   [$block getDieArea]
set core  [$block getCoreArea]
set dbu   [$block getDefUnits]
proc um {v} { return [expr {double($v) / $::dbu}] }
puts [format "FLOORPLAN die  %.2f x %.2f um" [um [$die dx]]  [um [$die dy]]]
puts [format "FLOORPLAN core %.2f x %.2f um  rows %d" [um [$core dx]] [um [$core dy]] [llength [$block getRows]]]
report_design_area

write_db $BUILD/1_floorplan.odb
exit
