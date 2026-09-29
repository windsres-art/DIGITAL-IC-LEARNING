# =============================================================================
# 形式等价性检查：RTL（gold / reference）vs 综合网表（gate / implementation）
# 用法：GATE=<网表> yosys -c equiv.tcl
# 流程与 Formality / Conformal LEC 对应：
#   读 reference → 读 implementation（单元库给出每个单元的功能）
#   → 匹配比较点（按名字配对寄存器和端口）→ 逐点证明组合逻辑等价
# =============================================================================
yosys -import
set LIB  build/lib.lib
set GATE $::env(GATE)

# ---- reference：RTL ----
yosys read_verilog ../Yosys_Flow/alu.v
yosys prep -top alu
yosys rename alu gold
yosys design -stash gold

# ---- implementation：门级网表 ----
# 不加 -lib：把 liberty 里每个单元的 function / ff 描述读成可分析的模型
# -ignore_miss_func：ICG 等用 statetable 描述的单元没有 function，跳过
yosys read_liberty -ignore_miss_func $LIB
yosys read_verilog $GATE
yosys hierarchy -top alu
yosys flatten
yosys rename alu gate
yosys design -stash gate

yosys design -copy-from gold -as gold gold
yosys design -copy-from gate -as gate gate

# ---- 匹配比较点：同名的信号（端口、a_q/b_q/y 等寄存器输出）配成一对 ----
yosys equiv_make gold gate equiv
yosys hierarchy -top equiv
# 异步复位转成同步形式，便于 SAT 求解（两边做同样变换，不影响结论）
yosys async2sync
# ---- 证明：先按比较点做有限步 SAT，剩下的用归纳法 ----
yosys equiv_simple -seq 5
yosys equiv_induct -seq 5
yosys equiv_status
