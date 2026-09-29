# =============================================================================
# 把 Yosys 的 synth 命令拆开逐步执行，每一步后记录单元统计
# 用法：yosys -c synth.tcl（由 run.sh 调用）
# 环境变量：
#   ABC_D    ABC 的延时目标（ps）。不设 = 面积优先；设了 = 时序驱动映射
#   TAG      报告/网表文件名后缀，方便同时保留多次结果
# 对照 DC：read_verilog/elaborate ≈ 第 1 步；compile 内部 ≈ 第 2–4 步
# =============================================================================
yosys -import

set LIB  build/lib.lib
set TAG  [expr {[info exists ::env(TAG)]   ? $::env(TAG)   : ""}]
set ABCD [expr {[info exists ::env(ABC_D)] ? $::env(ABC_D) : ""}]

# proc 与 Tcl 自带的 proc 同名，这里一律用 "yosys <命令>" 调用，避免冲突
# 单元库作为黑盒读入：映射后 check 才知道 dfrtp 的 Q 是输出，否则误报 "no driver"
yosys read_liberty -lib $LIB
yosys read_verilog alu.v
yosys hierarchy -check -top alu

# ---- 第 1 步：翻译（elaborate）--------------------------------------------
# always 块 → 字级单元：$add/$sub/$mux/$pmux/$adff ...
yosys proc
yosys opt_clean
yosys tee -q -o reports/step1_rtl$TAG.stat stat

# ---- 第 2 步：字级（coarse）优化 --------------------------------------------
# 常量传播、去冗余、FSM 提取、位宽缩减、把 +/-/比较合并成 $alu、资源共享
yosys opt_expr
yosys opt_clean
yosys opt -nodffe -nosdff
yosys fsm
yosys opt
yosys wreduce
yosys peepopt
yosys opt_clean
yosys alumacc
yosys share
yosys opt
yosys memory -nomap
yosys opt_clean
yosys tee -q -o reports/step2_coarse$TAG.stat stat

# ---- 第 3 步：拆成通用门（与工艺无关的 GTECH 类似物）-----------------------
yosys opt -fast -full
yosys memory_map
yosys opt -full
yosys techmap
yosys opt -fast
yosys tee -q -o reports/step3_generic$TAG.stat stat

# ---- 第 4 步：工艺映射 ------------------------------------------------------
# 时序单元：按 liberty 里 ff 的功能匹配（dfrtp = 异步低复位 DFF）
yosys dfflibmap -liberty $LIB -dont_use *lpflow*
# 组合逻辑：ABC 做逻辑优化 + 单元匹配
if {$ABCD eq ""} {
    # 默认脚本（&nf 映射器，偏面积）
    yosys abc -liberty $LIB -dont_use *lpflow*
} else {
    # 时序驱动：经典 map 映射器按延时目标选单元，再插 buffer、调尺寸
    # 注意 D 只是组合逻辑的目标，ABC 看不到 Tcq、setup、uncertainty
    # abc.constr 告诉 ABC 输入驱动单元和输出负载，upsize/dnsize 才有依据
    # ABC 在临时目录里运行，文件要给绝对路径；它的 source 命令不支持路径里有空格，放到 /tmp
    set script /tmp/alu_abc_delay$TAG.script
    set f [open $script w]
    puts $f "strash; dch -f; map -D $ABCD; buffer; upsize -D $ABCD; dnsize -D $ABCD; stime -p"
    close $f
    yosys abc -liberty $LIB -dont_use *lpflow* -constr [file normalize abc.constr] -script $script
}
# 常量 0/1 映射到 tie 单元（后端不接受直接连电源的信号线）
yosys hilomap -singleton -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO
yosys opt_clean
yosys check -assert
yosys tee -q -o reports/step4_mapped$TAG.stat stat -liberty $LIB

yosys write_verilog -noattr build/alu_netlist$TAG.v
