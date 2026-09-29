// =============================================================================
// valid/ready 握手 testbench（自检查）
//   每种寄存器级串 3 级（hs_harness），源端遵守协议：valid 拉高后保持到握手完成，
//   期间数据不变；valid 不看 ready。四个阶段：
//     P1 随机：源 valid 70%，宿 ready 70%，3000 拍
//     P2 满速：valid、ready 恒为 1，1000 拍 → 吞吐
//     P3 反压：valid 恒为 1，ready 每拍翻转（50%），1000 拍 → 吞吐
//     P4 排空：valid=0，ready=1
//   检查：记分板（顺序、不丢不重）、输出端协议（valid 未握手不许撤、数据不许变）
// =============================================================================
`timescale 1ns / 1ps

module hs_harness #(
    parameter KIND   = 1,               // 0 bubble, 1 pipe
    parameter STAGES = 3
)(
    output reg done
);
    localparam DW = 16;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ---------------- 3 级串联 ----------------
    wire [STAGES:0]   v, r;
    wire [DW-1:0]     dat [0:STAGES];
    reg               src_valid = 0, snk_ready = 0;
    reg  [DW-1:0]     src_data = 0;
    assign v[0]   = src_valid;
    assign dat[0] = src_data;
    assign r[STAGES] = snk_ready;

    genvar g;
    generate
        for (g = 0; g < STAGES; g = g + 1) begin : g_st
            if (KIND == 0) begin : g_b
                hs_stage_bubble #(.DW(DW)) u (.clk(clk), .rst_n(rst_n),
                    .in_valid(v[g]), .in_ready(r[g]), .in_data(dat[g]),
                    .out_valid(v[g+1]), .out_ready(r[g+1]), .out_data(dat[g+1]));
            end else begin : g_p
                hs_stage_pipe #(.DW(DW)) u (.clk(clk), .rst_n(rst_n),
                    .in_valid(v[g]), .in_ready(r[g]), .in_data(dat[g]),
                    .out_valid(v[g+1]), .out_ready(r[g+1]), .out_data(dat[g+1]));
            end
        end
    endgenerate

    wire in_fire  = v[0] & r[0];
    wire out_fire = v[STAGES] & r[STAGES];

    // ---------------- 记分板与协议检查（上升沿，采样本拍的值） ----------------
    reg [DW-1:0] q [0:16383];
    integer      qt [0:16383];
    integer wp = 0, rp = 0, errors = 0, cyc = 0, phase = 0;
    integer n_out [0:4], lat_min = 1 << 30, lat_max = 0;
    reg          hold_v = 0;
    reg [DW-1:0] hold_d;
    reg          src_fire_q = 0;

    initial begin n_out[0] = 0; n_out[1] = 0; n_out[2] = 0; n_out[3] = 0; n_out[4] = 0; end

    always @(posedge clk) if (rst_n) begin
        cyc = cyc + 1;
        // 输出端协议：上一拍 valid=1 而 ready=0，这一拍必须仍然 valid 且数据不变
        if (hold_v && (!v[STAGES] || dat[STAGES] !== hold_d)) begin
            if (errors < 5) $display("ERROR kind%0d @%0t 输出端违反协议", KIND, $time);
            errors = errors + 1;
        end
        hold_v = v[STAGES] && !r[STAGES];
        hold_d = dat[STAGES];

        if (in_fire) begin q[wp] = dat[0]; qt[wp] = cyc; wp = wp + 1; end
        if (out_fire) begin
            if (rp >= wp || dat[STAGES] !== q[rp]) begin
                if (errors < 5) $display("ERROR kind%0d @%0t 数据 %h 期望 %h", KIND, $time, dat[STAGES], q[rp]);
                errors = errors + 1;
            end
            if (phase == 2) begin
                if (cyc - qt[rp] < lat_min) lat_min = cyc - qt[rp];
                if (cyc - qt[rp] > lat_max) lat_max = cyc - qt[rp];
            end
            rp = rp + 1;
            n_out[phase] = n_out[phase] + 1;
        end
        src_fire_q = in_fire;
    end

    // ---------------- 激励（下降沿） ----------------
    task drive(input integer vp, input integer rpct, input integer toggle_ready);
        begin
            @(negedge clk);
            // 源：没有未完成的数据时才决定要不要发新数据；否则保持 valid 与 data
            if (!src_valid || src_fire_q) begin
                src_valid = ($urandom % 100) < vp;
                if (src_valid) src_data = src_data + 1'b1;     // 每个新数据值都不同
            end
            if (toggle_ready) snk_ready = ~snk_ready;
            else              snk_ready = ($urandom % 100) < rpct;
        end
    endtask

    integer k;
    initial begin
        done = 0;
        #22 rst_n = 1;
        phase = 1; for (k = 0; k < 3000; k = k + 1) drive(70, 70, 0);
        phase = 2; for (k = 0; k < 1000; k = k + 1) drive(100, 100, 0);
        phase = 3; for (k = 0; k < 1000; k = k + 1) drive(100, 0, 1);
        phase = 4;
        // 已经发出、还没握手的那个继续保持到被接收，之后不再发新数据
        do begin
            @(negedge clk);
            snk_ready = 1;
            if (src_fire_q) src_valid = 0;
        end while (src_valid);
        repeat (4 * STAGES) @(negedge clk);
        if (rp != wp) begin
            $display("ERROR kind%0d: 排空后还有 %0d 个没出来", KIND, wp - rp);
            errors = errors + 1;
        end
        done = 1;
    end
endmodule


module tb_handshake;
    wire [1:0] done;
    hs_harness #(.KIND(0)) h_bub  (done[0]);
    hs_harness #(.KIND(1)) h_pipe (done[1]);
    integer errors;

    initial begin
        $dumpfile("handshake.vcd");
        $dumpvars(0, tb_handshake);
        wait (&done);
        $display("------------------------------------------------------------------------------");
        $display("3-stage chain  | P1 random 3000 | P2 full-rate 1000 | P3 ready 50%% 1000 | latency P2 | total");
        $display("bubble stage   | %14d | %17d | %17d | %4d~%-4d  | %5d",
                 h_bub.n_out[1], h_bub.n_out[2], h_bub.n_out[3], h_bub.lat_min, h_bub.lat_max, h_bub.rp);
        $display("pipe stage     | %14d | %17d | %17d | %4d~%-4d  | %5d",
                 h_pipe.n_out[1], h_pipe.n_out[2], h_pipe.n_out[3], h_pipe.lat_min, h_pipe.lat_max, h_pipe.rp);
        $display("------------------------------------------------------------------------------");
        errors = h_bub.errors + h_pipe.errors;
        if (h_pipe.n_out[2] < 995 || h_bub.n_out[2] > 505) begin
            $display("ERROR: 吞吐与预期不符"); errors = errors + 1;
        end
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
