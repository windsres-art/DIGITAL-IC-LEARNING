// =============================================================================
// 仲裁器 testbench（自检查），N = 4
//   每种仲裁器一个 arb_harness，两个阶段：
//     阶段 1：4 路一直请求 1000 拍 → 统计各路授权次数（公平性 / 权重比例）
//     阶段 2：请求"保持到被授权为止"（真实总线的行为），空闲的请求者每拍以 40%
//             概率发起新请求，5000 拍 → 统计每路最长等待拍数
//   每拍检查：gnt 独热（或全 0）、gnt 是 req 的子集、有请求必有授权；
//   固定优先级 / 轮询还与参考模型逐拍比对。
//   另外：arb_rr 与 arb_rr_mask 用同一个随机请求流逐拍比对，验证两种写法等价。
// =============================================================================
`timescale 1ns / 1ps

module arb_harness #(
    parameter KIND = 0                  // 0 fixed, 1 rr, 2 rr_mask, 3 wrr
)(
    output reg done
);
    localparam N = 4;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [N-1:0] req = 0;
    wire [N-1:0] gnt;
    generate
        if (KIND == 0)      begin : g_f arb_fixed   #(.N(N)) u (.req(req), .gnt(gnt)); end
        else if (KIND == 1) begin : g_r arb_rr      #(.N(N)) u (.clk(clk), .rst_n(rst_n), .req(req), .gnt(gnt)); end
        else if (KIND == 2) begin : g_m arb_rr_mask #(.N(N)) u (.clk(clk), .rst_n(rst_n), .req(req), .gnt(gnt)); end
        else                begin : g_w arb_wrr     #(.N(N)) u (.clk(clk), .rst_n(rst_n), .req(req), .gnt(gnt)); end
    endgenerate

    integer errors = 0;
    integer cnt1 [0:N-1], wait_c [0:N-1], wait_max [0:N-1], cnt2 [0:N-1];
    integer phase = 0, i, s, p = N - 1;
    reg [N-1:0] exp_g, g_acc = 0;

    function onehot0(input [N-1:0] v);
        onehot0 = ((v & (v - 1'b1)) == 0);
    endfunction

    // 上升沿检查（输入在下降沿改变）
    always @(posedge clk) if (rst_n && phase != 0) begin
        if (!onehot0(gnt) || (gnt & ~req) != 0 || ((|req) && !(|gnt))) begin
            if (errors < 5) $display("ERROR kind%0d @%0t req=%b gnt=%b", KIND, $time, req, gnt);
            errors = errors + 1;
        end
        // 参考模型
        exp_g = 0;
        if (KIND == 0) begin
            for (i = N - 1; i >= 0; i = i - 1) if (req[i]) exp_g = 1 << i;
        end else if (KIND == 1 || KIND == 2) begin
            for (s = N; s >= 1; s = s - 1) if (req[(p + s) % N]) exp_g = 1 << ((p + s) % N);
        end
        if (KIND <= 2 && gnt !== exp_g) begin
            if (errors < 5) $display("ERROR kind%0d @%0t req=%b gnt=%b model=%b", KIND, $time, req, gnt, exp_g);
            errors = errors + 1;
        end
        for (i = 0; i < N; i = i + 1) if (gnt[i]) p = i;
        g_acc = gnt;                    // 本拍真正生效的授权
        // 统计
        for (i = 0; i < N; i = i + 1) begin
            if (phase == 1 && gnt[i]) cnt1[i] = cnt1[i] + 1;
            if (phase == 2) begin
                if (gnt[i]) begin
                    cnt2[i] = cnt2[i] + 1;
                    if (wait_c[i] > wait_max[i]) wait_max[i] = wait_c[i];
                    wait_c[i] = 0;
                end else if (req[i]) wait_c[i] = wait_c[i] + 1;
            end
        end
    end

    integer k;
    reg [N-1:0] nreq;
    initial begin
        done = 0;
        for (i = 0; i < N; i = i + 1) begin cnt1[i] = 0; cnt2[i] = 0; wait_c[i] = 0; wait_max[i] = 0; end
        #22 rst_n = 1;
        @(negedge clk);
        phase = 1; req = {N{1'b1}};
        repeat (1000) @(negedge clk);
        phase = 2;
        for (k = 0; k < 5000; k = k + 1) begin
            @(negedge clk);
            // 被授权的撤销请求，没被授权的保持；空闲的以 40% 概率发起。
            // 用上升沿记下的 g_acc：上升沿之后 last 已更新，此刻的 gnt 是"下一次"的结果
            nreq = req & ~g_acc;
            for (i = 0; i < N; i = i + 1)
                if (!nreq[i] && ($urandom % 100) < 40) nreq[i] = 1'b1;
            req = nreq;
        end
        done = 1;
    end
endmodule


module tb_arbiter;
    wire [3:0] done;
    arb_harness #(.KIND(0)) h_fixed (done[0]);
    arb_harness #(.KIND(1)) h_rr    (done[1]);
    arb_harness #(.KIND(2)) h_rrm   (done[2]);
    arb_harness #(.KIND(3)) h_wrr   (done[3]);

    // 两种轮询写法的等价性：同一请求流
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg  [3:0] req = 0;
    wire [3:0] g_a, g_b;
    arb_rr      #(.N(4)) ea (.clk(clk), .rst_n(rst_n), .req(req), .gnt(g_a));
    arb_rr_mask #(.N(4)) eb (.clk(clk), .rst_n(rst_n), .req(req), .gnt(g_b));
    integer n_eq_err = 0, k, errors = 0;
    always @(posedge clk) if (rst_n && g_a !== g_b) n_eq_err = n_eq_err + 1;

    task show(input [8*11-1:0] name, input integer c0, input integer c1, input integer c2, input integer c3,
              input integer w0, input integer w1, input integer w2, input integer w3);
        $display("%s | all-request grants %4d %4d %4d %4d | max wait %4d %4d %4d %4d",
                 name, c0, c1, c2, c3, w0, w1, w2, w3);
    endtask

    initial begin
        $dumpfile("arbiter.vcd");
        $dumpvars(0, h_rr);
        $dumpvars(0, h_wrr);
        #22 rst_n = 1;
        for (k = 0; k < 20000; k = k + 1) begin
            @(negedge clk); req = $urandom;
        end
        wait (&done);
        $display("--------------------------------------------------------------------------------");
        $display("arbiter     |          requester:    0    1    2    3 |            0    1    2    3");
        show("fixed      ", h_fixed.cnt1[0], h_fixed.cnt1[1], h_fixed.cnt1[2], h_fixed.cnt1[3],
             h_fixed.wait_max[0], h_fixed.wait_max[1], h_fixed.wait_max[2], h_fixed.wait_max[3]);
        show("rr         ", h_rr.cnt1[0], h_rr.cnt1[1], h_rr.cnt1[2], h_rr.cnt1[3],
             h_rr.wait_max[0], h_rr.wait_max[1], h_rr.wait_max[2], h_rr.wait_max[3]);
        show("rr_mask    ", h_rrm.cnt1[0], h_rrm.cnt1[1], h_rrm.cnt1[2], h_rrm.cnt1[3],
             h_rrm.wait_max[0], h_rrm.wait_max[1], h_rrm.wait_max[2], h_rrm.wait_max[3]);
        show("wrr 4:3:2:1", h_wrr.cnt1[0], h_wrr.cnt1[1], h_wrr.cnt1[2], h_wrr.cnt1[3],
             h_wrr.wait_max[0], h_wrr.wait_max[1], h_wrr.wait_max[2], h_wrr.wait_max[3]);
        $display("rr vs rr_mask on 20000 random cycles: %0d mismatches", n_eq_err);
        $display("--------------------------------------------------------------------------------");
        errors = h_fixed.errors + h_rr.errors + h_rrm.errors + h_wrr.errors + n_eq_err;
        if (h_fixed.cnt1[0] != 1000) errors = errors + 1;
        for (k = 0; k < 4; k = k + 1) begin
            if (h_rr.cnt1[k] != 250 || h_rrm.cnt1[k] != 250) errors = errors + 1;
            if (h_rr.wait_max[k] > 3 || h_rrm.wait_max[k] > 3) errors = errors + 1;   // N-1
            if (h_wrr.cnt1[k] != 100 * (4 - k)) errors = errors + 1;
        end
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
