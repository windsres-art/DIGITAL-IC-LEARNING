// =============================================================================
// PWM 发生器（边沿对齐）
//   - 周期 = period + 1 个时钟；每周期开头输出高电平，持续 duty 个时钟
//     duty = 0 恒低，duty >= period + 1 恒高（duty 多 1 位，才能表示 100%）
//   - SHADOW = 1：period / duty 先进影子寄存器，只在一个周期结束（cnt 回绕）时更新，
//     周期中途改占空比不会产生半截脉冲或一个周期两个脉冲
//     SHADOW = 0：直接和输入比较，仅用于对比实验
//   - 输出用寄存器：比较器的组合输出有毛刺，PWM 常直接驱动功率管 / LED，不能带毛刺
// =============================================================================
module pwm #(
    parameter CW     = 8,
    parameter SHADOW = 1
)(
    input               clk,
    input               rst_n,
    input      [CW-1:0] period,
    input      [CW:0]   duty,
    output     [CW-1:0] cnt_o,          // 当前周期内的位置，便于上层对齐（如 ADC 触发）
    output reg          pwm_out
);
    reg  [CW-1:0] cnt, period_q;
    reg  [CW:0]   duty_q;

    wire [CW-1:0] per_use  = SHADOW ? period_q : period;
    wire [CW:0]   duty_use = SHADOW ? duty_q   : duty;
    wire          wrap     = (cnt >= per_use);  // 用 >=：周期被改小时也能立即回绕
    wire [CW-1:0] cnt_nxt  = wrap ? {CW{1'b0}} : cnt + 1'b1;
    // 新周期从第 0 拍开始就用新的 duty
    wire [CW:0]   duty_nxt = (SHADOW && wrap) ? duty : duty_use;

    assign cnt_o = cnt;

    // 复位后 period_q = 0，第一拍就回绕并装入外部的 period / duty
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt      <= {CW{1'b0}};
            period_q <= {CW{1'b0}};
            duty_q   <= {(CW+1){1'b0}};
            pwm_out  <= 1'b0;
        end else begin
            cnt     <= cnt_nxt;
            pwm_out <= ({1'b0, cnt_nxt} < duty_nxt);
            if (wrap) begin
                period_q <= period;
                duty_q   <= duty;
            end
        end
    end

endmodule
