# =============================================================================
# 第 4 步：布线（routing）
#   填充单元 → 全局布线（分配走线通道，查拥塞）→ 天线修复 → 详细布线（真实几何，查 DRC）
# =============================================================================
source config.tcl
load_stage 3_cts.odb 1

# 信号线用 met1–met4，时钟线只用 met3–met4（上层金属更厚、电阻小）
# met5 很厚、最小线宽 1.6 um，留给电源网络；li1 是局部互连层，只留给单元内部和进出引脚
# 本机全局布线器存进数据库的 guide 会给个别网往上多扩一层到 met5（给过孔接入留余地），
# 详细布线若直接用它，要么报 DRT-0155，要么真的在 met5 上走出不满足 1.6 um 线宽的短线；
# 所以详细布线改读 -guide_file 写出的文件版 guide（只含 met1–met4）
set_routing_layers -signal met1-met4 -clock met3-met4

# ---------------------------------------------------------------- 天线效应（预防）
# 制造时一段金属在上层还没连上之前只接到栅极，刻蚀时积累的电荷会击穿栅氧。
# 修法：插反偏二极管（diode）给电荷泄放通路，或让布线跳到上层金属（layer hopping）
# 正常流程是全局布线后 repair_antennas 按违例插 diode；本机 OpenROAD（2022 版）这条命令会崩溃，
# 所以在布线前给输入端口网预先插 diode（OpenLane 也有这种策略），ANTENNA_DIODES=0 可关掉做对比
if {[env_or ANTENNA_DIODES 1]} {
    insert_input_diodes
    detailed_placement
}

# ---------------------------------------------------------------- 填充单元
# 行里的空隙必须填满：保证 N 阱、电源轨连续，满足密度规则；不带逻辑
filler_placement {sky130_fd_sc_hd__fill_1 sky130_fd_sc_hd__fill_2 \
                  sky130_fd_sc_hd__fill_4 sky130_fd_sc_hd__fill_8}
check_placement

# ---------------------------------------------------------------- 全局布线
# 把芯片切成 GCell 网格，每个 GCell 每层有若干条 track 的容量（capacity）；
# 给每条网在网格上找路径，统计每层的需求（usage）与溢出（overflow = 需求 > 容量）
global_route -guide_file $BUILD/route.guide -congestion_iterations 50 -verbose
estimate_parasitics -global_routing
timing_summary "after global_route"

# ---------------------------------------------------------------- 详细布线
detailed_route -guide $BUILD/route.guide -output_drc $REPORTS/4_route_drc.rpt \
               -bottom_routing_layer met1 -top_routing_layer met4 \
               -droute_end_iter 20 -verbose 1

puts "---- 天线检查（详细布线后）----"
check_antennas -report_file $REPORTS/4_antenna.rpt

connect_pg_pins
write_db $BUILD/4_route.odb
exit
