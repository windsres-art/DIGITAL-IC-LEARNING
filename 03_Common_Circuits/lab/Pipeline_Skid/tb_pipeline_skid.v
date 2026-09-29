// =============================================================================
// 流水线与 skid buffer testbench（自检查）
//   四种 DUT（ps_harness 的 KIND）：
//     0  skid_buffer 串 3 级，数据原样透传
//     1  pipe_mac MODE=0（全局停顿）
//     2  pipe_mac MODE=1（逐级握手，气泡可压缩）
//     3  skid_buffer → pipe_mac MODE=1 → skid_buffer（两端的 ready 都被寄存切断）
//   源端遵守协议（valid 拉高后保持到握手、数据不变、不看 ready）。四个阶段：
//     P1 随机：源 valid 60%，宿 ready 60%，3000 拍
//     P2 满速：valid、ready 恒为 1，1000 拍 → 吞吐、延迟
//     P3 反压：valid 恒为 1，ready 每拍翻转，1000 拍
//     P4 排空
//   检查：记分板（参考模型、顺序、不丢不重）、输出端协议；
//   另外统计 in_ready 在两个时钟沿之间变化的次数：下降沿改 snk_ready 后，
//   in_ready 如果跟着变，说明 out_ready → in_ready 有组合路径
// =============================================================================
`timescale 1ns / 1ps

module ps_harness #(
    parameter KIND = 0
)(
    output reg done
);
    localparam DW = 8;
    localparam XW = 4 * DW;             // {a, b, c} 共 32 位
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg           src_valid = 0, snk_ready = 0;
    reg  [XW-1:0] src_x = 0;
    wire [DW-1:0]   a = src_x[XW-1 -: DW];
    wire [DW-1:0]   b = src_x[XW-DW-1 -: DW];
    wire [2*DW-1:0] c = src_x[2*DW-1:0];
    wire          in_ready, out_valid;
    wire [XW-1:0] out_data;

    // ---------------- DUT ----------------
    generate
        if (KIND == 0) begin : g_skid
            wire [2:0]    v, r;
            wire [XW-1:0] d0, d1;
            skid_buffer #(.DW(XW)) s0 (.clk(clk), .rst_n(rst_n),
                .in_valid(src_valid), .in_ready(in_ready), .in_data(src_x),
                .out_valid(v[0]), .out_ready(r[0]), .out_data(d0));
            skid_buffer #(.DW(XW)) s1 (.clk(clk), .rst_n(rst_n),
                .in_valid(v[0]), .in_ready(r[0]), .in_data(d0),
                .out_valid(v[1]), .out_ready(r[1]), .out_data(d1));
            skid_buffer #(.DW(XW)) s2 (.clk(clk), .rst_n(rst_n),
                .in_valid(v[1]), .in_ready(r[1]), .in_data(d1),
                .out_valid(out_valid), .out_ready(snk_ready), .out_data(out_data));
        end else if (KIND == 1 || KIND == 2) begin : g_mac
            wire [2*DW-1:0] y;
            pipe_mac #(.DW(DW), .MODE(KIND - 1)) u (.clk(clk), .rst_n(rst_n),
                .in_valid(src_valid), .in_ready(in_ready), .a(a), .b(b), .c(c),
                .out_valid(out_valid), .out_ready(snk_ready), .y(y));
            assign out_data = {{(XW-2*DW){1'b0}}, y};
        end else begin : g_wrap
            wire          iv, ir, ov, or_;
            wire [XW-1:0] ix;
            wire [2*DW-1:0] y;
            skid_buffer #(.DW(XW)) si (.clk(clk), .rst_n(rst_n),
                .in_valid(src_valid), .in_ready(in_ready), .in_data(src_x),
                .out_valid(iv), .out_ready(ir), .out_data(ix));
            pipe_mac #(.DW(DW), .MODE(1)) u (.clk(clk), .rst_n(rst_n),
                .in_valid(iv), .in_ready(ir),
                .a(ix[XW-1 -: DW]), .b(ix[XW-DW-1 -: DW]), .c(ix[2*DW-1:0]),
                .out_valid(ov), .out_ready(or_), .y(y));
            wire [2*DW-1:0] yo;
            skid_buffer #(.DW(2*DW)) so (.clk(clk), .rst_n(rst_n),
                .in_valid(ov), .in_ready(or_), .in_data(y),
                .out_valid(out_valid), .out_ready(snk_ready), .out_data(yo));
            assign out_data = {{(XW-2*DW){1'b0}}, yo};
        end
    endgenerate

    // ---------------- 参考模型 ----------------
    function [XW-1:0] model(input [XW-1:0] x);
        reg [2*DW:0] s;
        begin
            if (KIND == 0) model = x;
            else begin
                s = x[XW-1 -: DW] * x[XW-DW-1 -: DW] + x[2*DW-1:0];
                model = {{(XW-2*DW){1'b0}}, (s[2*DW] ? {(2*DW){1'b1}} : s[2*DW-1:0])};
            end
        end
    endfunction

    wire in_fire  = src_valid & in_ready;
    wire out_fire = out_valid & snk_ready;

    // ---------------- 记分板与协议检查 ----------------
    reg [XW-1:0] q  [0:16383];
    integer      qt [0:16383];
    integer wp = 0, rp = 0, errors = 0, cyc = 0, phase = 0, n_sat = 0;
    integer n_out [0:4], lat_min = 1 << 30, lat_max = 0;
    integer comb_chg = 0, p2_start = 0;
    reg          hold_v = 0;
    reg [XW-1:0] hold_d;
    reg          src_fire_q = 0;
    reg          rdy_at_edge;

    initial begin n_out[0] = 0; n_out[1] = 0; n_out[2] = 0; n_out[3] = 0; n_out[4] = 0; end

    always @(posedge clk) if (rst_n) begin
        cyc = cyc + 1;
        if (hold_v && (!out_valid || out_data !== hold_d)) begin
            if (errors < 5) $display("ERROR kind%0d @%0t 输出端违反协议", KIND, $time);
            errors = errors + 1;
        end
        hold_v = out_valid && !snk_ready;
        hold_d = out_data;

        if (in_fire) begin
            q[wp] = model(src_x); qt[wp] = cyc; wp = wp + 1;
            if (KIND != 0 && model(src_x) == {{(XW-2*DW){1'b0}}, {(2*DW){1'b1}}}) n_sat = n_sat + 1;
        end
        if (out_fire) begin
            if (rp >= wp || out_data !== q[rp]) begin
                if (errors < 5) $display("ERROR kind%0d @%0t 数据 %h 期望 %h", KIND, $time, out_data, q[rp]);
                errors = errors + 1;
            end
            // P1 结束时各级缓存里可能还有积压，跳过 P2 开头 50 拍再量稳态延迟
            if (phase == 2 && qt[rp] > p2_start + 50) begin
                if (cyc - qt[rp] < lat_min) lat_min = cyc - qt[rp];
                if (cyc - qt[rp] > lat_max) lat_max = cyc - qt[rp];
            end
            rp = rp + 1;
            n_out[phase] = n_out[phase] + 1;
        end
        src_fire_q = in_fire;
    end

    // 沿后 1 ns 记下 in_ready；下降沿改完激励后 1 ns 再看，变了就是组合穿透
    always @(posedge clk) begin #1 rdy_at_edge = in_ready; end

    // ---------------- 激励（下降沿） ----------------
    task drive(input integer vp, input integer rpct, input integer toggle_ready);
        begin
            @(negedge clk);
            if (!src_valid || src_fire_q) begin
                src_valid = ($urandom % 100) < vp;
                if (src_valid) src_x = {$urandom} ;
            end
            if (toggle_ready) snk_ready = ~snk_ready;
            else              snk_ready = ($urandom % 100) < rpct;
            #1 if (in_ready !== rdy_at_edge) comb_chg = comb_chg + 1;
        end
    endtask

    integer k;
    initial begin
        done = 0;
        #22 rst_n = 1;
        phase = 1; for (k = 0; k < 3000; k = k + 1) drive(60, 60, 0);
        phase = 2; p2_start = cyc;
        for (k = 0; k < 1000; k = k + 1) drive(100, 100, 0);
        phase = 3; for (k = 0; k < 1000; k = k + 1) drive(100, 0, 1);
        phase = 4;
        do begin
            @(negedge clk);
            snk_ready = 1;
            if (src_fire_q) src_valid = 0;
        end while (src_valid);
        repeat (20) @(negedge clk);
        if (rp != wp) begin
            $display("ERROR kind%0d: 排空后还有 %0d 个没出来", KIND, wp - rp);
            errors = errors + 1;
        end
        done = 1;
    end
endmodule


module tb_pipeline_skid;
    wire [3:0] done;
    ps_harness #(.KIND(0)) h_skid   (done[0]);
    ps_harness #(.KIND(1)) h_global (done[1]);
    ps_harness #(.KIND(2)) h_local  (done[2]);
    ps_harness #(.KIND(3)) h_wrap   (done[3]);
    integer errors;

    task row(input [8*24-1:0] name, input integer o1, input integer o2, input integer o3,
             input integer lmin, input integer lmax, input integer cc, input integer tot);
        $display("%s | %9d | %9d | %9d | %3d~%-3d | %13d | %5d",
                 name, o1, o2, o3, lmin, lmax, cc, tot);
    endtask

    initial begin
        $dumpfile("pipeline_skid.vcd");
        $dumpvars(0, tb_pipeline_skid);
        wait (&done);
        $display("------------------------------------------------------------------------------------------------");
        $display("DUT                      | P1 random | P2 full   | P3 rdy50%% | lat P2* | in_ready comb | total");
        $display("                         | 3000 cyc  | 1000 cyc  | 1000 cyc  |         | changes       |");
        row("skid_buffer x3          ", h_skid.n_out[1],   h_skid.n_out[2],   h_skid.n_out[3],
            h_skid.lat_min,   h_skid.lat_max,   h_skid.comb_chg,   h_skid.rp);
        row("pipe_mac global stall   ", h_global.n_out[1], h_global.n_out[2], h_global.n_out[3],
            h_global.lat_min, h_global.lat_max, h_global.comb_chg, h_global.rp);
        row("pipe_mac per-stage      ", h_local.n_out[1],  h_local.n_out[2],  h_local.n_out[3],
            h_local.lat_min,  h_local.lat_max,  h_local.comb_chg,  h_local.rp);
        row("skid + mac + skid       ", h_wrap.n_out[1],   h_wrap.n_out[2],   h_wrap.n_out[3],
            h_wrap.lat_min,   h_wrap.lat_max,   h_wrap.comb_chg,   h_wrap.rp);
        $display("------------------------------------------------------------------------------------------------");
        $display("* latency measured after the first 50 cycles of P2 (steady state)");
        $display("saturated results: global %0d, per-stage %0d, wrapped %0d",
                 h_global.n_sat, h_local.n_sat, h_wrap.n_sat);
        errors = h_skid.errors + h_global.errors + h_local.errors + h_wrap.errors;
        if (h_skid.n_out[2] < 995 || h_local.n_out[2] < 995 || h_wrap.n_out[2] < 990) begin
            $display("ERROR: 满速吞吐不足"); errors = errors + 1;
        end
        if (h_skid.comb_chg != 0 || h_wrap.comb_chg != 0) begin
            $display("ERROR: 寄存切断后 in_ready 仍随 out_ready 组合变化"); errors = errors + 1;
        end
        if (h_local.n_out[1] <= h_global.n_out[1]) begin
            $display("ERROR: 逐级握手在随机场景下应比全局停顿吞吐高"); errors = errors + 1;
        end
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
