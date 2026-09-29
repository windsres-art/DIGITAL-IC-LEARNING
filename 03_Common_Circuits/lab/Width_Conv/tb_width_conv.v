// =============================================================================
// 位宽转换 testbench（自检查）
//   loop_harness：width_up(8→32) → width_down(32→8) 环回
//     源端发随机长度 1..13 的包（带 last），检查：
//       宽总线：每个宽字的有效槽数据、keep、last 与参考模型一致
//       环回输出：窄字流（含 last）与输入完全一致
//     阶段：P1 随机（valid 70%、ready 70%）3000 拍，P2 满速 1000 拍，P3 排空
//   gb_harness：width_gearbox，比特流参考模型（逐位队列），随机 3000 拍 + 满速 1000 拍，
//     满速时量输入 / 输出每拍传了多少
// 两者都检查输出端协议（valid 未握手不撤、数据不变）
// =============================================================================
`timescale 1ns / 1ps

module loop_harness #(
    parameter FULLONLY = 0,             // 1：包长都是 4 的倍数，宽字全满
    parameter MIDBUF   = 0              // 1：宽总线中间插一级 skid_buffer（2 个缓存位）
)(output reg done);
    localparam W = 8, R = 4;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg          src_valid = 0, src_last = 0, snk_ready = 0;
    reg  [W-1:0] src_data = 0;
    wire         up_ready, mid_valid, mid_ready, mid_last, out_valid, out_last;
    wire [W*R-1:0] mid_data;
    wire [R-1:0]   mid_keep;
    wire [W-1:0]   out_data;

    width_up #(.IN_W(W), .RATIO(R)) u_up (.clk(clk), .rst_n(rst_n),
        .in_valid(src_valid), .in_ready(up_ready), .in_data(src_data), .in_last(src_last),
        .out_valid(mid_valid), .out_ready(mid_ready), .out_data(mid_data),
        .out_keep(mid_keep), .out_last(mid_last));

    wire           dn_valid, dn_ready, dn_last;
    wire [W*R-1:0] dn_data;
    wire [R-1:0]   dn_keep;
    generate
        if (MIDBUF) begin : g_buf
            skid_buffer #(.DW(W*R + R + 1)) u_sb (.clk(clk), .rst_n(rst_n),
                .in_valid(mid_valid), .in_ready(mid_ready), .in_data({mid_last, mid_keep, mid_data}),
                .out_valid(dn_valid), .out_ready(dn_ready), .out_data({dn_last, dn_keep, dn_data}));
        end else begin : g_direct
            assign dn_valid  = mid_valid;
            assign mid_ready = dn_ready;
            assign {dn_last, dn_keep, dn_data} = {mid_last, mid_keep, mid_data};
        end
    endgenerate

    width_down #(.OUT_W(W), .RATIO(R)) u_dn (.clk(clk), .rst_n(rst_n),
        .in_valid(dn_valid), .in_ready(dn_ready), .in_data(dn_data),
        .in_keep(dn_keep), .in_last(dn_last),
        .out_valid(out_valid), .out_ready(snk_ready), .out_data(out_data), .out_last(out_last));

    wire in_fire  = src_valid & up_ready;
    wire mid_fire = mid_valid & mid_ready;
    wire out_fire = out_valid & snk_ready;

    // 窄字队列（环回比对）与宽字期望队列（宽总线比对）
    reg [W:0]     nq [0:65535];             // {last, data}
    reg [W*R-1:0] wq_d [0:16383];
    reg [R-1:0]   wq_k [0:16383];
    reg           wq_l [0:16383];
    integer nwp = 0, nrp = 0, wwp = 0, wrp = 0, slot = 0;
    reg [W*R-1:0] acc_d = 0;
    reg [R-1:0]   acc_k = 0;
    integer errors = 0, phase = 0, i;
    integer n_in [0:3], n_mid [0:3], n_out [0:3], n_part = 0;
    reg          hold_v = 0, hold_l;
    reg [W-1:0]  hold_d;
    reg          src_fire_q = 0;

    initial for (i = 0; i < 4; i = i + 1) begin n_in[i] = 0; n_mid[i] = 0; n_out[i] = 0; end

    always @(posedge clk) if (rst_n) begin
        if (hold_v && (!out_valid || out_data !== hold_d || out_last !== hold_l)) begin
            if (errors < 5) $display("ERROR loop @%0t 输出端违反协议", $time);
            errors = errors + 1;
        end
        hold_v = out_valid && !snk_ready;
        hold_d = out_data;
        hold_l = out_last;

        if (in_fire) begin
            nq[nwp] = {src_last, src_data}; nwp = nwp + 1;
            acc_d[slot*W +: W] = src_data;
            acc_k[slot] = 1'b1;
            if (slot == R - 1 || src_last) begin
                wq_d[wwp] = acc_d; wq_k[wwp] = acc_k; wq_l[wwp] = src_last; wwp = wwp + 1;
                if (slot != R - 1) n_part = n_part + 1;
                slot = 0; acc_k = 0;
            end else slot = slot + 1;
            n_in[phase] = n_in[phase] + 1;
        end
        if (mid_fire) begin
            if (wrp >= wwp || mid_keep !== wq_k[wrp] || mid_last !== wq_l[wrp]) begin
                if (errors < 5) $display("ERROR loop @%0t 宽字 keep/last 错", $time);
                errors = errors + 1;
            end else for (i = 0; i < R; i = i + 1)
                if (wq_k[wrp][i] && mid_data[i*W +: W] !== wq_d[wrp][i*W +: W]) begin
                    if (errors < 5) $display("ERROR loop @%0t 宽字槽 %0d 数据错", $time, i);
                    errors = errors + 1;
                end
            wrp = wrp + 1;
            n_mid[phase] = n_mid[phase] + 1;
        end
        if (out_fire) begin
            if (nrp >= nwp || {out_last, out_data} !== nq[nrp]) begin
                if (errors < 5) $display("ERROR loop @%0t 输出 %b_%h 期望 %b_%h", $time,
                                         out_last, out_data, nq[nrp][W], nq[nrp][W-1:0]);
                errors = errors + 1;
            end
            nrp = nrp + 1;
            n_out[phase] = n_out[phase] + 1;
        end
        src_fire_q = in_fire;
    end

    integer remain = 0;
    task drive(input integer vp, input integer rp);
        begin
            @(negedge clk);
            if (!src_valid || src_fire_q) begin
                // 排空阶段：当前包发完就不再开新包
                src_valid = (phase == 3 && remain == 0) ? 1'b0 : (($urandom % 100) < vp);
                if (src_valid) begin
                    if (remain == 0) remain = FULLONLY ? R * (1 + $urandom % 3) : 1 + $urandom % 13;
                    src_data = $urandom;
                    src_last = (remain == 1);
                    remain   = remain - 1;
                end
            end
            snk_ready = ($urandom % 100) < rp;
        end
    endtask

    integer k;
    initial begin
        done = 0;
        #22 rst_n = 1;
        phase = 1; for (k = 0; k < 3000; k = k + 1) drive(70, 70);
        phase = 2; for (k = 0; k < 1000; k = k + 1) drive(100, 100);
        phase = 3;
        // 把当前包发完（最后一个带 last），再排空
        while (remain != 0 || src_valid) drive(100, 100);
        repeat (20) drive(0, 100);
        if (nrp != nwp || wrp != wwp) begin
            $display("ERROR loop: 排空后窄字差 %0d、宽字差 %0d", nwp - nrp, wwp - wrp);
            errors = errors + 1;
        end
        done = 1;
    end
endmodule


module gb_harness #(
    parameter IN_W  = 24,
    parameter OUT_W = 32
)(output reg done);
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg              src_valid = 0, snk_ready = 0;
    reg  [IN_W-1:0]  src_data = 0;
    wire             in_ready, out_valid;
    wire [OUT_W-1:0] out_data;

    width_gearbox #(.IN_W(IN_W), .OUT_W(OUT_W)) dut (.clk(clk), .rst_n(rst_n),
        .in_valid(src_valid), .in_ready(in_ready), .in_data(src_data),
        .out_valid(out_valid), .out_ready(snk_ready), .out_data(out_data));

    wire in_fire  = src_valid & in_ready;
    wire out_fire = out_valid & snk_ready;

    reg     bq [0:(1<<20)-1];               // 比特队列参考模型
    integer bwp = 0, brp = 0, errors = 0, phase = 0, i;
    integer n_in [0:3], n_out [0:3];
    reg     hold_v = 0;
    reg [OUT_W-1:0] hold_d, exp_w;
    reg     src_fire_q = 0;

    initial for (i = 0; i < 4; i = i + 1) begin n_in[i] = 0; n_out[i] = 0; end

    always @(posedge clk) if (rst_n) begin
        if (hold_v && (!out_valid || out_data !== hold_d)) begin
            if (errors < 5) $display("ERROR gb%0d->%0d @%0t 输出端违反协议", IN_W, OUT_W, $time);
            errors = errors + 1;
        end
        hold_v = out_valid && !snk_ready;
        hold_d = out_data;

        if (in_fire) begin
            for (i = 0; i < IN_W; i = i + 1) bq[bwp + i] = src_data[i];
            bwp = bwp + IN_W;
            n_in[phase] = n_in[phase] + 1;
        end
        if (out_fire) begin
            for (i = 0; i < OUT_W; i = i + 1) exp_w[i] = bq[brp + i];
            if (brp + OUT_W > bwp || out_data !== exp_w) begin
                if (errors < 5) $display("ERROR gb%0d->%0d @%0t 输出 %h 期望 %h",
                                         IN_W, OUT_W, $time, out_data, exp_w);
                errors = errors + 1;
            end
            brp = brp + OUT_W;
            n_out[phase] = n_out[phase] + 1;
        end
        src_fire_q = in_fire;
    end

    task drive(input integer vp, input integer rp);
        begin
            @(negedge clk);
            if (!src_valid || src_fire_q) begin
                src_valid = ($urandom % 100) < vp;
                if (src_valid) src_data = {$urandom, $urandom};
            end
            snk_ready = ($urandom % 100) < rp;
        end
    endtask

    integer k;
    initial begin
        done = 0;
        #22 rst_n = 1;
        phase = 1; for (k = 0; k < 3000; k = k + 1) drive(70, 70);
        phase = 2; for (k = 0; k < 1000; k = k + 1) drive(100, 100);
        phase = 3;
        do begin @(negedge clk); snk_ready = 1; if (src_fire_q) src_valid = 0; end while (src_valid);
        repeat (20) @(negedge clk);
        // 不满一个输出字的尾巴留在缓冲里是正常的
        if (bwp - brp >= OUT_W) begin
            $display("ERROR gb%0d->%0d: 排空后还剩 %0d 位", IN_W, OUT_W, bwp - brp);
            errors = errors + 1;
        end
        done = 1;
    end
endmodule


module tb_width_conv;
    wire [6:0] done;
    loop_harness #(1, 0)    h_full (done[5]);
    loop_harness #(0, 0)    h_loop (done[0]);
    loop_harness #(0, 1)    h_buf  (done[6]);
    gb_harness #(24, 32)    g24_32 (done[1]);
    gb_harness #(32, 24)    g32_24 (done[2]);
    gb_harness #(8, 12)     g8_12  (done[3]);
    gb_harness #(12, 8)     g12_8  (done[4]);
    integer errors;

    task gb_row(input [8*12-1:0] name, input integer i1, input integer o1,
                input integer i2, input integer o2, input integer iw, input integer ow, input integer err);
        $display("%s | %5d / %5d | %5d / %5d  (%5.1f%% / %5.1f%%) | bits in/out %6d / %6d | err %0d",
                 name, i1, o1, i2, o2, i2 / 10.0, o2 / 10.0, i2 * iw, o2 * ow, err);
    endtask

    task loop_row(input [8*28-1:0] name, input integer i1, input integer o1, input integer i2,
                  input integer o2, input integer nw, input integer np, input integer err);
        $display("%s  |        %5d / %5d     |      %5d / %5d     |     %5d (%4d)      | %0d",
                 name, i1, o1, i2, o2, nw, np, err);
    endtask

    initial begin
        $dumpfile("width_conv.vcd");
        $dumpvars(0, tb_width_conv);
        wait (&done);
        $display("-----------------------------------------------------------------------------------------------");
        $display("loopback width_up 8->32 -> width_down 32->8");
        $display("config                        | P1 random 3000: in / out | P2 full 1000: in / out | wide words (partial) | err");
        loop_row("packets 4/8/12, direct      ", h_full.n_in[1], h_full.n_out[1], h_full.n_in[2], h_full.n_out[2],
                 h_full.wwp, h_full.n_part, h_full.errors);
        loop_row("packets 1..13, direct       ", h_loop.n_in[1], h_loop.n_out[1], h_loop.n_in[2], h_loop.n_out[2],
                 h_loop.wwp, h_loop.n_part, h_loop.errors);
        loop_row("packets 1..13, skid between ", h_buf.n_in[1],  h_buf.n_out[1],  h_buf.n_in[2],  h_buf.n_out[2],
                 h_buf.wwp,  h_buf.n_part,  h_buf.errors);
        $display("-----------------------------------------------------------------------------------------------");
        $display("gearbox      | P1 in / out   | P2 full-rate in / out (per cycle) | P2 bits                | ");
        gb_row("24 -> 32    ", g24_32.n_in[1], g24_32.n_out[1], g24_32.n_in[2], g24_32.n_out[2], 24, 32, g24_32.errors);
        gb_row("32 -> 24    ", g32_24.n_in[1], g32_24.n_out[1], g32_24.n_in[2], g32_24.n_out[2], 32, 24, g32_24.errors);
        gb_row(" 8 -> 12    ", g8_12.n_in[1],  g8_12.n_out[1],  g8_12.n_in[2],  g8_12.n_out[2],   8, 12, g8_12.errors);
        gb_row("12 ->  8    ", g12_8.n_in[1],  g12_8.n_out[1],  g12_8.n_in[2],  g12_8.n_out[2],  12,  8, g12_8.errors);
        $display("-----------------------------------------------------------------------------------------------");
        errors = h_full.errors + h_loop.errors + h_buf.errors
               + g24_32.errors + g32_24.errors + g8_12.errors + g12_8.errors;
        // 满速时瓶颈一侧必须每拍一个；宽字全满时环回也必须不断流
        if (h_full.n_in[2] < 995 || h_full.n_out[2] < 990 || h_full.n_part != 0 ||
            h_buf.n_out[2] <= h_loop.n_out[2] ||
            g24_32.n_in[2] < 995 || g32_24.n_out[2] < 995 ||
            g8_12.n_in[2]  < 995 || g12_8.n_out[2]  < 995) begin
            $display("ERROR: 满速吞吐不足"); errors = errors + 1;
        end
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
