# =============================================================================
# 异步 FIFO 的 SDC 约束（Synopsys Design Constraints）
# 单位跟随 liberty：时间 ns，电容 pF
# 周期可用环境变量覆盖，方便做「收紧时钟看违例」实验
# =============================================================================

proc env_or {name default} {
    if {[info exists ::env($name)]} { return $::env($name) }
    return $default
}

set CLK_W_PERIOD [env_or CLK_W_PERIOD 5.0]
set CLK_R_PERIOD [env_or CLK_R_PERIOD 7.0]

# ---------------------------------------------------------------- 时钟
create_clock -name clk_w -period $CLK_W_PERIOD [get_ports clk_w]
create_clock -name clk_r -period $CLK_R_PERIOD [get_ports clk_r]

# 综合阶段时钟树还不存在：用 uncertainty 预留 jitter + 估计 skew
set_clock_uncertainty -setup 0.20 [all_clocks]
set_clock_uncertainty -hold  0.05 [all_clocks]
set_clock_transition 0.10 [all_clocks]

# ---------------------------------------------------------------- 两个时钟互为异步
# 跨域路径靠 Gray + 两级同步器保证功能，STA 不去分析这些路径
if {[env_or NO_CLOCK_GROUPS 0] == 0} {
    set_clock_groups -asynchronous -group {clk_w} -group {clk_r}
}

# ---------------------------------------------------------------- 端口环境
# 输入：外部器件在时钟沿后 1.0 ns 才把数据送到端口
set_input_delay  -clock clk_w 1.0 [get_ports {w_en data_in[*]}]
set_input_delay  -clock clk_r 1.0 [get_ports {r_en}]
# 异步复位也给 input delay，这样工具会做 recovery/removal 检查
set_input_delay  -clock clk_w 1.0 [get_ports {rst_w}]
set_input_delay  -clock clk_r 1.0 [get_ports {rst_r}]

# 输出：外部器件需要端口数据在下个沿前 1.0 ns 就稳定
set_output_delay -clock clk_r 1.0 [get_ports {data_out[*] empty}]
set_output_delay -clock clk_w 1.0 [get_ports {full}]

# 输入由一个 buf_2 驱动；输出挂 10 fF 负载
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 -pin X \
    [get_ports {w_en data_in[*] r_en rst_w rst_r}]
set_load 0.01 [all_outputs]

# ---------------------------------------------------------------- 设计规则（DRV）
set_max_transition 1.0 [current_design]
set_max_fanout     16  [current_design]
