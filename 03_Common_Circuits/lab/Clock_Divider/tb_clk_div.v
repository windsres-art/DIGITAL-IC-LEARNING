// =============================================================================
// 时钟分频 testbench（自检查），输入时钟 10 ns
//   偶数 N=2/4/6、奇数 N=3/5/7：测输出每个周期的周期和高电平时间（取最小/最大），
//     检查周期 = N×10 ns、高电平 = N×5 ns（50%）；奇数分频另外报告只用上升沿的 clk_p
//   小数分频 K=8.7、2.5：统计 tick 间隔的分布、长期平均、相对理想位置的最大相位误差
// =============================================================================
`timescale 1ns / 1ps

// 测量一个信号的周期与高电平时间（跳过前 2 个周期）
module wave_meas (
    input   sig,
    input   en
);
    real per_min, per_max, hi_min, hi_max;
    real t_rise;
    integer n;
    initial begin
        per_min = 1.0e9; per_max = 0.0; hi_min = 1.0e9; hi_max = 0.0; n = 0;
        t_rise = -1.0;
    end
    always @(posedge sig) if (en) begin
        if (n >= 2) begin
            if ($realtime - t_rise < per_min) per_min = $realtime - t_rise;
            if ($realtime - t_rise > per_max) per_max = $realtime - t_rise;
        end
        t_rise = $realtime;
        n = n + 1;
    end
    always @(negedge sig) if (en && n >= 2) begin
        if ($realtime - t_rise < hi_min) hi_min = $realtime - t_rise;
        if ($realtime - t_rise > hi_max) hi_max = $realtime - t_rise;
    end
endmodule


module tb_clk_div;
    reg clk = 0, rst_n = 0, meas = 0;
    always #5 clk = ~clk;
    integer errors = 0, i;

    // ---------------- 整数分频 ----------------
    wire [5:0] dout;                    // e2 e4 e6 o3 o5 o7
    wire [2:0] pout;                    // o3/o5/o7 的 clk_p
    clk_div_even #(.N(2)) e2 (.clk(clk), .rst_n(rst_n), .clk_out(dout[0]));
    clk_div_even #(.N(4)) e4 (.clk(clk), .rst_n(rst_n), .clk_out(dout[1]));
    clk_div_even #(.N(6)) e6 (.clk(clk), .rst_n(rst_n), .clk_out(dout[2]));
    clk_div_odd  #(.N(3)) o3 (.clk(clk), .rst_n(rst_n), .clk_out(dout[3]), .clk_p_out(pout[0]));
    clk_div_odd  #(.N(5)) o5 (.clk(clk), .rst_n(rst_n), .clk_out(dout[4]), .clk_p_out(pout[1]));
    clk_div_odd  #(.N(7)) o7 (.clk(clk), .rst_n(rst_n), .clk_out(dout[5]), .clk_p_out(pout[2]));

    wave_meas m0 (.sig(dout[0]), .en(meas));
    wave_meas m1 (.sig(dout[1]), .en(meas));
    wave_meas m2 (.sig(dout[2]), .en(meas));
    wave_meas m3 (.sig(dout[3]), .en(meas));
    wave_meas m4 (.sig(dout[4]), .en(meas));
    wave_meas m5 (.sig(dout[5]), .en(meas));
    wave_meas m6 (.sig(pout[0]), .en(meas));
    wave_meas m7 (.sig(pout[1]), .en(meas));
    wave_meas m8 (.sig(pout[2]), .en(meas));

    // ---------------- 小数分频 ----------------
    wire tk87, tk25;
    clk_div_frac #(.M(87), .D(10)) f87 (.clk(clk), .rst_n(rst_n), .tick(tk87));
    clk_div_frac #(.M(5),  .D(2))  f25 (.clk(clk), .rst_n(rst_n), .tick(tk25));

    // 在 clk 上升沿统计：cyc 为第几个周期，记录 tick 间隔
    integer cyc = 0;
    integer n87 = 0, last87 = 0, h87 [0:15];
    integer n25 = 0, last25 = 0, h25 [0:15];
    real    err87 = 0.0, err25 = 0.0, e;
    integer first87 = -1, first25 = -1;
    initial for (i = 0; i < 16; i = i + 1) begin h87[i] = 0; h25[i] = 0; end
    always @(posedge clk) if (rst_n) begin
        cyc = cyc + 1;
        if (tk87) begin
            if (first87 < 0) first87 = cyc;
            else h87[cyc - last87] = h87[cyc - last87] + 1;
            // 第 n 个 tick 的理想位置 = 第 1 个 tick + n × 8.7
            e = (cyc - first87) - n87 * 8.7;
            if (e < 0) e = -e;
            if (e > err87) err87 = e;
            last87 = cyc; n87 = n87 + 1;
        end
        if (tk25) begin
            if (first25 < 0) first25 = cyc;
            else h25[cyc - last25] = h25[cyc - last25] + 1;
            e = (cyc - first25) - n25 * 2.5;
            if (e < 0) e = -e;
            if (e > err25) err25 = e;
            last25 = cyc; n25 = n25 + 1;
        end
    end

    // ---------------- 结果 ----------------
    task report(input integer idx, input [8*16-1:0] name, input integer n, input integer need50);
        real p0, p1, h0, h1;
        begin
            case (idx)
                0: begin p0 = m0.per_min; p1 = m0.per_max; h0 = m0.hi_min; h1 = m0.hi_max; end
                1: begin p0 = m1.per_min; p1 = m1.per_max; h0 = m1.hi_min; h1 = m1.hi_max; end
                2: begin p0 = m2.per_min; p1 = m2.per_max; h0 = m2.hi_min; h1 = m2.hi_max; end
                3: begin p0 = m3.per_min; p1 = m3.per_max; h0 = m3.hi_min; h1 = m3.hi_max; end
                4: begin p0 = m4.per_min; p1 = m4.per_max; h0 = m4.hi_min; h1 = m4.hi_max; end
                5: begin p0 = m5.per_min; p1 = m5.per_max; h0 = m5.hi_min; h1 = m5.hi_max; end
                6: begin p0 = m6.per_min; p1 = m6.per_max; h0 = m6.hi_min; h1 = m6.hi_max; end
                7: begin p0 = m7.per_min; p1 = m7.per_max; h0 = m7.hi_min; h1 = m7.hi_max; end
                default: begin p0 = m8.per_min; p1 = m8.per_max; h0 = m8.hi_min; h1 = m8.hi_max; end
            endcase
            $display("%s  N=%0d  period %5.1f~%5.1f ns  high %5.1f~%5.1f ns  duty %4.1f%%",
                     name, n, p0, p1, h0, h1, 100.0 * h0 / p0);
            if (p0 != n * 10.0 || p1 != n * 10.0) begin
                $display("ERROR: 周期不对"); errors = errors + 1;
            end
            if (need50 && (h0 != n * 5.0 || h1 != n * 5.0)) begin
                $display("ERROR: 占空比不是 50%%"); errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("clk_div.vcd");
        $dumpvars(0, tb_clk_div);
        #22 rst_n = 1;
        #100 meas = 1;
        #87000;                          // 8700 个输入周期
        $display("----------------------------------------------------------");
        report(0, "even  clk_out ", 2, 1);
        report(1, "even  clk_out ", 4, 1);
        report(2, "even  clk_out ", 6, 1);
        report(3, "odd   clk_out ", 3, 1);
        report(4, "odd   clk_out ", 5, 1);
        report(5, "odd   clk_out ", 7, 1);
        report(6, "odd   clk_p   ", 3, 0);
        report(7, "odd   clk_p   ", 5, 0);
        report(8, "odd   clk_p   ", 7, 0);
        $display("frac K=8.7: %0d ticks in %0d cycles, avg %.4f, intervals 8:%0d 9:%0d others:%0d, max phase err %.2f cycles",
                 n87, cyc, (last87 - first87) * 1.0 / (n87 - 1), h87[8], h87[9],
                 n87 - 1 - h87[8] - h87[9], err87);
        $display("frac K=2.5: %0d ticks in %0d cycles, avg %.4f, intervals 2:%0d 3:%0d others:%0d, max phase err %.2f cycles",
                 n25, cyc, (last25 - first25) * 1.0 / (n25 - 1), h25[2], h25[3],
                 n25 - 1 - h25[2] - h25[3], err25);
        $display("----------------------------------------------------------");
        // 间隔只能是 8 或 9；8 的个数应占 30%（±1 个）；相位误差 < 1 个周期
        if (n87 - 1 != h87[8] + h87[9] || err87 >= 1.0
            || h87[8] * 10 > 3 * (n87 - 1) + 10 || h87[8] * 10 < 3 * (n87 - 1) - 10) begin
            $display("ERROR: K=8.7 间隔不对"); errors = errors + 1;
        end
        if (n25 - 1 != h25[2] + h25[3] || err25 >= 1.0) begin
            $display("ERROR: K=2.5 间隔不对"); errors = errors + 1;
        end
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
