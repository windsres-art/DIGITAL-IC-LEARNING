# =============================================================================
# 第 8c 步（Magic）：提取晶体管级网表，给 LVS 用
#   只关心连接关系和器件，不抽电容电阻（那是给时序用的 RC 抽取，见 5_extract.tcl）
#   标准单元用 PDK 的 .mag 视图（带完整端口信息）而不是 GDS：
#   sky130 的 diode_2 在 GDS 里缺 VPWR/VGND/VPB 端口标签，从 GDS 提取会让 LVS 对不上端口
#   顶层走线与 8_magic_gds.tcl 相同（同一份 DEF + 同样的 met3 修补）
# =============================================================================
set HD $::env(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd
source magic_patch.tcl

drc off
addpath $HD/mag
lef read $HD/techlef/sky130_fd_sc_hd__nom.tlef
def read build/alu.def
load alu
select top cell
maybe_patch

# 每个单元会生成一个 .ext 中间文件，放到 build/ext 里
file mkdir build/ext
cd build/ext
extract do local
extract no capacitance
extract no coupling
extract no resistance
extract no adjust
extract all

ext2spice lvs
ext2spice -o ../alu_extracted.spice
cd ../..
puts "==== EXTRACT DONE ===="
quit -noprompt
