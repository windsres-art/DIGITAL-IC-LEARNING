// =============================================================================
// 时钟门控 testbench（自检查）
//   en 由 clk 上升沿的寄存器产生（真实电路里 en 就是这样来的），
//   所以 en 总是在 clk 高电平期间变化 —— 这正是 AND 门控出问题的场景。
//
// 检查项：
//   1. 每个门控时钟的高电平脉宽：< 半周期即为毛刺/截断脉冲
//   2. ICG 输出的时钟上升沿个数 == 上升沿时刻 en 为 1 的周期数（不多不少）
//   3. se=1 时 ICG 必须无条件放行时钟
// 期望：cg_and 出现毛刺（演示问题），icg_latch / icg_negff 零毛刺且计数正确
// =============================================================================
`timescale 1ns / 1ps

// 测一个时钟的高电平宽度，统计比 MIN_W 窄的脉冲个数
module pulse_mon #(
    parameter real MIN_W = 5.0
)(
    input      clk,
    input      check_on,
    output reg [31:0] n_rise,
    output reg [31:0] n_glitch,
    output reg [63:0] min_w_ps   // 观察到的最窄高电平（ps），方便打印
);
    realtime t_rise;
    initial begin
        n_rise   = 0;
        n_glitch = 0;
        min_w_ps = 64'd999999;
    end
    always @(posedge clk) if (check_on) begin
        t_rise = $realtime;
        n_rise = n_rise + 1;
    end
    always @(negedge clk) if (check_on && n_rise > 0) begin
        if (($realtime - t_rise) * 1000 < min_w_ps)
            min_w_ps = ($realtime - t_rise) * 1000;
        if ($realtime - t_rise < MIN_W - 0.001)
            n_glitch = n_glitch + 1;
    end
endmodule


module tb_clk_gate;
    localparam real T      = 10.0;   // 时钟周期 10 ns
    localparam integer NCYC = 400;

    reg clk = 1'b0;
    reg en  = 1'b0;
    reg se  = 1'b0;
    reg check_on = 1'b0;
    integer errors = 0;
    integer ref_pulses = 0;
    integer cyc;

    always #(T/2) clk = ~clk;

    wire gclk_and, gclk_latch, gclk_negff;
    cg_and    u_and   (.clk(clk), .en(en),            .gclk(gclk_and));
    icg_latch u_latch (.clk(clk), .en(en), .se(se),   .gclk(gclk_latch));
    icg_negff u_negff (.clk(clk), .en(en), .se(se),   .gclk(gclk_negff));

    wire [31:0] r_and, g_and, r_lat, g_lat, r_nff, g_nff;
    wire [63:0] w_and, w_lat, w_nff;
    pulse_mon #(.MIN_W(T/2)) m_and (.clk(gclk_and),   .check_on(check_on), .n_rise(r_and), .n_glitch(g_and), .min_w_ps(w_and));
    pulse_mon #(.MIN_W(T/2)) m_lat (.clk(gclk_latch), .check_on(check_on), .n_rise(r_lat), .n_glitch(g_lat), .min_w_ps(w_lat));
    pulse_mon #(.MIN_W(T/2)) m_nff (.clk(gclk_negff), .check_on(check_on), .n_rise(r_nff), .n_glitch(g_nff), .min_w_ps(w_nff));

    // 参考模型：上升沿时刻 en（沿前的值）为 1 → ICG 应该放出这个沿
    always @(posedge clk) if (check_on && (en || se)) ref_pulses = ref_pulses + 1;

    initial begin
        $dumpfile("clk_gate.vcd");
        $dumpvars(0, tb_clk_gate);

        // 前几个周期让 latch / negff 进入确定状态，再开始统计
        repeat (3) @(posedge clk);
        #1 check_on = 1'b1;

        // 随机 en：模拟上升沿寄存器输出，在沿后 1 ns 变化（clk 仍为高）
        for (cyc = 0; cyc < NCYC; cyc = cyc + 1) begin
            @(posedge clk);
            #1 en = ($urandom % 3) != 0;
        end

        // se=1：en=0 也必须出时钟（扫描测试模式）
        @(posedge clk); #1 en = 1'b0; se = 1'b1;
        repeat (20) @(posedge clk);
        #1 se = 1'b0;
        repeat (5) @(posedge clk);
        #1 check_on = 1'b0;

        $display("----------------------------------------------------------");
        $display("gated clock     rises  glitches  narrowest_high(ns)");
        $display("cg_and       %8d  %8d  %8.3f", r_and, g_and, w_and / 1000.0);
        $display("icg_latch    %8d  %8d  %8.3f", r_lat, g_lat, w_lat / 1000.0);
        $display("icg_negff    %8d  %8d  %8.3f", r_nff, g_nff, w_nff / 1000.0);
        $display("reference pulses (en=1 at rising edge): %0d", ref_pulses);
        $display("----------------------------------------------------------");

        if (g_and == 0) begin
            $display("ERROR: cg_and 没有复现毛刺，演示场景不对");
            errors = errors + 1;
        end
        if (g_lat != 0 || g_nff != 0) begin
            $display("ERROR: ICG 输出出现毛刺");
            errors = errors + 1;
        end
        if (r_lat != ref_pulses || r_nff != ref_pulses) begin
            $display("ERROR: ICG 放出的时钟沿个数与参考模型不一致");
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
