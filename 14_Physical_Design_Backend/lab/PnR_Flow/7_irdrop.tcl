# =============================================================================
# 第 7 步：静态 IR drop 与电迁移（PDNSim）
#   1. STA 按翻转率算出每个单元的平均功耗 → 平均电流
#   2. 把电源网络（rail + strap + ring + via）建成电阻网络，在顶层金属上放理想电压源（模拟 bump）
#   3. 解线性方程 G·V = I，得到每个节点的电压 → 最差压降；按电流密度检查 EM
# 环境变量 DB = 读哪个阶段的数据库（默认 ECO 后的最终版），ACTIVITY = 输入翻转率
# =============================================================================
source config.tcl
set DB       [env_or DB 9_eco.odb]
set ACTIVITY [env_or ACTIVITY 0.2]

load_stage $DB 1
# 布线后用抽取的 SPEF；只做到布局 / CTS 的实验数据库用估算寄生
if {$DB eq "9_eco.odb" || $DB eq "4_route.odb"} {
    read_spef $BUILD/alu.nom.spef
} else {
    estimate_parasitics -placement
}

# 翻转率：每个时钟周期输入翻转的概率；时钟本身每周期翻两次（activity 由时钟定义给出）
set_power_activity -input -activity $ACTIVITY
report_power

# 电源网络连通性：有没有悬空的条带、没接上的单元电源脚
check_power_grid -net VDD

set_pdnsim_net_voltage -net VDD -voltage 1.8
set_pdnsim_net_voltage -net VSS -voltage 0.0
# 没给电压源位置文件时，PDNSim 在顶层金属上按棋盘格放电压源（模拟 bump）：
#   x 方向每 6 个 bump 放一个 VDD，y 方向每 2 个放一个；-dx/-dy 是 bump 间距，单位是 DBU（1 DBU = 1 nm）
set BUMP_PITCH [env_or BUMP_PITCH 20]   ;# um
set dxy [expr {int($BUMP_PITCH * [[ord::get_db_block] getDefUnits])}]
foreach net {VDD VSS} {
    puts "---- IR drop: $net ----"
    analyze_power_grid -net $net -dx $dxy -dy $dxy \
        -outfile $REPORTS/7_ir_$net.rpt -enable_em -em_outfile $REPORTS/7_em_$net.rpt
}
exit
