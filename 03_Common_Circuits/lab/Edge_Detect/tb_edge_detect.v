// =============================================================================
// 边沿检测 testbench（自检查）
//   A 同步输入：din 在时钟沿随机变化（保持 1~5 拍，含单拍脉冲），
//     每拍与模型比对 REG_OUT=0/1 两个实例的 rise/fall/both
//   B 复位值：din 空闲为高，INIT=0 与 INIT=1 各一个实例，数复位释放后的上升沿
//   C 异步输入：din_async 在任意时刻变化，保持 15~80 ns（clk 10 ns，≥ 1.5 周期），
//     检查每个输入边沿恰好产生一个单周期脉冲，并统计延迟
//   D 异步窄脉冲：宽 2~6 ns（< 1 个周期），演示被漏采（只统计，要求确实有丢失）
// =============================================================================
`timescale 1ns / 1ps

module tb_edge_detect;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    integer errors = 0;
    integer k;

    // ---------------- A 同步输入 ----------------
    reg  din = 0;
    wire r0, f0, b0, r1, f1, b1;
    edge_detect #(.REG_OUT(0)) u_comb (.clk(clk), .rst_n(rst_n), .din(din), .rise(r0), .fall(f0), .both(b0));
    edge_detect #(.REG_OUT(1)) u_reg  (.clk(clk), .rst_n(rst_n), .din(din), .rise(r1), .fall(f1), .both(b1));

    reg     m_d = 0;
    reg     e_r, e_f, e_b, p_r = 0, p_f = 0, p_b = 0;
    integer n_in_rise = 0, n_in_fall = 0, n_r0 = 0, n_f0 = 0, n_r1 = 0, n_f1 = 0;
    reg     a_on = 0;
    always @(posedge clk) if (rst_n && a_on) begin
        e_r = din & ~m_d;  e_f = ~din & m_d;  e_b = din ^ m_d;
        if ({r0, f0, b0} !== {e_r, e_f, e_b} || {r1, f1, b1} !== {p_r, p_f, p_b}) begin
            if (errors < 10) $display("ERROR A @%0t din=%b comb=%b%b%b reg=%b%b%b", $time,
                                      din, r0, f0, b0, r1, f1, b1);
            errors = errors + 1;
        end
        n_in_rise = n_in_rise + e_r;  n_in_fall = n_in_fall + e_f;
        n_r0 = n_r0 + r0;  n_f0 = n_f0 + f0;  n_r1 = n_r1 + r1;  n_f1 = n_f1 + f1;
        m_d = din;  p_r = e_r;  p_f = e_f;  p_b = e_b;
    end

    // ---------------- B 复位值 ----------------
    reg  din_hi = 1;
    wire rb0, rb1, unused_fb0, unused_bb0, unused_fb1, unused_bb1;
    edge_detect #(.INIT(1'b0)) u_init0 (.clk(clk), .rst_n(rst_n), .din(din_hi),
        .rise(rb0), .fall(unused_fb0), .both(unused_bb0));
    edge_detect #(.INIT(1'b1)) u_init1 (.clk(clk), .rst_n(rst_n), .din(din_hi),
        .rise(rb1), .fall(unused_fb1), .both(unused_bb1));
    integer n_rb0 = 0, n_rb1 = 0;
    always @(posedge clk) if (rst_n) begin
        n_rb0 = n_rb0 + rb0;
        n_rb1 = n_rb1 + rb1;
    end

    // ---------------- C / D 异步输入 ----------------
    reg  din_a = 0;
    wire ra, fa, ba, sa;
    edge_detect_async u_async (.clk(clk), .rst_n(rst_n), .din_async(din_a),
        .rise(ra), .fall(fa), .both(ba), .din_sync(sa));

    integer n_a_in_r = 0, n_a_in_f = 0, n_a_r = 0, n_a_f = 0, n_a_b = 0, n_a_wide = 0;
    reg     ra_prev = 0, fa_prev = 0;
    always @(posedge clk) if (rst_n) begin
        n_a_r = n_a_r + ra;  n_a_f = n_a_f + fa;  n_a_b = n_a_b + ba;
        if ((ra && ra_prev) || (fa && fa_prev)) n_a_wide = n_a_wide + 1;   // 脉冲超过 1 拍
        ra_prev = ra;  fa_prev = fa;
    end

    // 延迟：输入上升沿时刻 → 输出 rise 拉高时刻
    real    t_in [0:4095];
    integer wq = 0, rq = 0;
    real    lat, lat_min = 1.0e9, lat_max = 0.0;
    reg     meas_lat = 0;
    always @(posedge din_a) if (meas_lat) begin t_in[wq] = $realtime; wq = wq + 1; end
    always @(posedge ra) if (meas_lat && rq < wq) begin
        lat = $realtime - t_in[rq];  rq = rq + 1;
        if (lat < lat_min) lat_min = lat;
        if (lat > lat_max) lat_max = lat;
    end

    // ---------------- 激励 ----------------
    integer hold, c_in_r, c_in_f, c_out_r, c_out_f, d_in, d_out, d_pred;
    real    w, ts, w_sum;
    initial begin
        $dumpfile("edge_detect.vcd");
        $dumpvars(0, tb_edge_detect);
        #22 rst_n = 1;

        // A：在上升沿用非阻塞赋值改 din，模拟"来自同一时钟域寄存器"的输入
        a_on = 1;
        for (k = 0; k < 400; k = k + 1) begin
            hold = 1 + $urandom % 5;
            repeat (hold) @(posedge clk);
            din <= ~din;
        end
        repeat (3) @(posedge clk);
        a_on = 0;

        // C：异步宽电平。时刻步长 0.01 ns，再错开 3 ps，保证输入边沿不会恰好落在
        // 时钟沿上（RTL 仿真没有亚稳态，同时刻的先后只取决于仿真器调度）
        #0.003;
        meas_lat = 1;
        for (k = 0; k < 400; k = k + 1) begin
            w = 15.0 + ($urandom % 6500) / 100.0;       // 15.00 ~ 79.99 ns
            #(w);
            din_a = ~din_a;
            if (din_a) n_a_in_r = n_a_in_r + 1; else n_a_in_f = n_a_in_f + 1;
        end
        #50;
        meas_lat = 0;
        c_in_r = n_a_in_r; c_in_f = n_a_in_f; c_out_r = n_a_r; c_out_f = n_a_f;

        // D：异步窄脉冲。脉冲内包含时钟上升沿（5 + 10k ns）才会被采到，
        // 按脉冲起止时刻算出应被采到的个数 d_pred，与实际比对
        d_pred = 0; w_sum = 0.0;
        for (k = 0; k < 200; k = k + 1) begin
            #(40.0 + ($urandom % 4000) / 100.0);
            din_a = 1; n_a_in_r = n_a_in_r + 1;
            ts = $realtime;
            w  = 2.0 + ($urandom % 400) / 100.0;        // 2.00 ~ 5.99 ns
            w_sum = w_sum + w;
            #(w);
            din_a = 0; n_a_in_f = n_a_in_f + 1;
            if ($rtoi(($realtime - 5.0) / 10.0) != $rtoi((ts - 5.0) / 10.0)) d_pred = d_pred + 1;
        end
        #50;
        d_in  = n_a_in_r - c_in_r;
        d_out = n_a_r - c_out_r;

        $display("----------------------------------------------------------");
        $display("A sync input : input rises=%0d falls=%0d | comb rise=%0d fall=%0d | reg rise=%0d fall=%0d",
                 n_in_rise, n_in_fall, n_r0, n_f0, n_r1, n_f1);
        $display("B idle-high  : false rises after reset  INIT=0 -> %0d   INIT=1 -> %0d", n_rb0, n_rb1);
        $display("C async wide : input rises=%0d falls=%0d | detected rise=%0d fall=%0d | pulses >1 cycle=%0d",
                 c_in_r, c_in_f, c_out_r, c_out_f, n_a_wide);
        $display("               latency input edge -> rise: %.2f ~ %.2f ns (clk 10 ns)", lat_min, lat_max);
        $display("D async 2~6ns: input pulses=%0d  detected=%0d  predicted=%0d  (avg width %.2f ns)",
                 d_in, d_out, d_pred, w_sum / d_in);
        $display("----------------------------------------------------------");
        if (n_r0 != n_in_rise || n_f0 != n_in_fall || n_r1 != n_in_rise || n_f1 != n_in_fall) begin
            $display("ERROR A: 边沿个数不符"); errors = errors + 1;
        end
        if (n_rb0 != 1 || n_rb1 != 0) begin
            $display("ERROR B: 复位值演示结果不符预期"); errors = errors + 1;
        end
        if (c_out_r != c_in_r || c_out_f != c_in_f || n_a_wide != 0) begin
            $display("ERROR C: 异步宽电平有丢失或脉冲过宽"); errors = errors + 1;
        end
        if (lat_min <= 10.0 || lat_max > 20.0) begin
            $display("ERROR C: 延迟应在 (10, 20] ns"); errors = errors + 1;
        end
        if (d_out >= d_in || d_out != d_pred) begin
            $display("ERROR D: 窄脉冲采到的个数与预测不符"); errors = errors + 1;
        end
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
