# =============================================================================
# 第 8d 步（Netgen）：LVS = 版图提取网表 vs 布线后的门级网表
#   原理图一侧：布线后 Verilog（含 VPWR/VGND 连接）+ 标准单元的 SPICE 子电路
#   版图一侧：Magic 提取出的 SPICE
# 用法：netgen -batch source 8_lvs.tcl
# =============================================================================
set PDK $::env(PDK_ROOT)/sky130A

# Magic 把二极管写成子电路调用 “X.. a c sky130_fd_pr__diode_pw2nd_05v5 perim= area=”，
# 标准单元 SPICE 库里是二极管器件 “D.. a c sky130_fd_pr__diode_pw2nd_05v5 pj= area=”；
# 两种写法 Netgen 会当成端口不同的两类单元。这里只改写法（X→D、perim→pj），不改连接
set fi [open build/alu_extracted.spice r]
set fo [open build/alu_extracted_lvs.spice w]
while {[gets $fi line] >= 0} {
    regsub {^X(\S+)(\s+\S+\s+\S+\s+sky130_fd_pr__diode_\S+\s+)perim=} $line {D\1\2pj=} line
    puts $fo $line
}
close $fi
close $fo

set layout [readnet spice build/alu_extracted_lvs.spice]
set source [readnet spice $PDK/libs.ref/sky130_fd_sc_hd/spice/sky130_fd_sc_hd.spice]
readnet verilog build/alu_route_pg.v $source

# sky130A_setup.tcl：器件属性比较规则、可忽略的物理单元（fill / tap 等）
lvs "$layout alu" "$source alu" $PDK/libs.tech/netgen/sky130A_setup.tcl reports/8_lvs.rpt
quit
