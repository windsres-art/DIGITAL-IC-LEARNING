# =============================================================================
# 第 8a 步（Magic）：DEF → GDS，并修补布线器漏掉的 met3 最小面积违例
#   DEF 里只有单元的名字和位置，单元内部的真实版图在标准单元库的 GDS 里；
#   写 GDS 就是把两者合并成一份可以交给代工厂的版图（stream out）
# 用法：magic -noconsole -dnull -rcfile <sky130A.magicrc> 8_magic_gds.tcl
# 环境变量 DRC_PATCH=0 可关掉修补，看原始违例
# =============================================================================
set HD $::env(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd
source magic_patch.tcl

drc off
# 标准单元只读引用，不要按 Magic 内部格点重新缩放
gds readonly true
gds rescale false
gds read $HD/gds/sky130_fd_sc_hd.gds

# tech LEF 提供 DEF 里用到的 via 定义
lef read $HD/techlef/sky130_fd_sc_hd__nom.tlef
def read build/alu.def
load alu
select top cell

maybe_patch

gds write build/alu.gds
puts "==== GDS DONE ===="
quit -noprompt
