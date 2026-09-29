// =============================================================================
// 多 bit 跨域 testbench（自检查）
//   MODE 0 = handshake_sync（四相握手），MODE 1 = mcp_sync（两相 MCP）
//   每种各跑 快→慢（10 ns → 27 ns）与 慢→快（27 ns → 10 ns）
//   源端 src_valid 一直为 1（满负荷），用来量出最大吞吐
//
// 检查：目的端收到的数据与源端被接受的数据逐笔比对（顺序、数值、个数）
// 同时打印平均每笔耗时，对比两种协议的吞吐
// =============================================================================
`timescale 1ns / 1ps

module xfer_test #(
    parameter integer MODE = 0,
    parameter real    TSRC = 10.0,
    parameter real    TDST = 27.0,
    parameter real    DST_PH = 1.3,
    parameter integer N    = 300,
    parameter integer W    = 16
)(
    output reg     done,
    output integer n_ok,
    output integer n_err,
    output real    ns_per_xfer
);
    reg clk_src = 0, clk_dst = 0, rst_n = 0;
    always #(TSRC/2) clk_src = ~clk_src;
    initial begin #(DST_PH); forever #(TDST/2) clk_dst = ~clk_dst; end

    reg          src_valid = 0;
    reg  [W-1:0] src_data  = 0;
    wire         src_ready;
    wire         dst_valid;
    wire [W-1:0] dst_data;

    generate
        if (MODE == 0) begin : g_hs
            handshake_sync #(.W(W)) u_dut (
                .clk_src(clk_src), .rst_src_n(rst_n), .src_valid(src_valid),
                .src_data(src_data), .src_ready(src_ready),
                .clk_dst(clk_dst), .rst_dst_n(rst_n), .dst_valid(dst_valid), .dst_data(dst_data));
        end else begin : g_mcp
            mcp_sync #(.W(W)) u_dut (
                .clk_src(clk_src), .rst_src_n(rst_n), .src_valid(src_valid),
                .src_data(src_data), .src_ready(src_ready),
                .clk_dst(clk_dst), .rst_dst_n(rst_n), .dst_valid(dst_valid), .dst_data(dst_data));
        end
    endgenerate

    // 记分板
    reg [W-1:0] exp_q [0:N-1];
    integer wr_p = 0, rd_p = 0;
    realtime t_first, t_last;

    initial begin
        done = 0; n_ok = 0; n_err = 0; ns_per_xfer = 0;
        #(3*TSRC + 3*TDST) rst_n = 1;
        @(posedge clk_src);
        src_valid <= 1'b1;
        src_data  <= $urandom;
        while (wr_p < N) begin
            @(posedge clk_src);
            if (src_ready) begin                 // 本沿 valid && ready → 被接受
                exp_q[wr_p] = src_data;
                if (wr_p == 0) t_first = $realtime;
                wr_p = wr_p + 1;
                src_data <= $urandom;
                if (wr_p == N) src_valid <= 1'b0;
            end
        end
        wait (rd_p == N);
        repeat (5) @(posedge clk_dst);
        ns_per_xfer = (t_last - t_first) / (N - 1);
        done = 1;
    end

    always @(posedge clk_dst) if (rst_n && dst_valid) begin
        if (rd_p >= N || dst_data !== exp_q[rd_p]) begin
            n_err = n_err + 1;
            if (n_err <= 3)
                $display("ERROR MODE=%0d #%0d: got %h expect %h", MODE, rd_p, dst_data, exp_q[rd_p]);
        end else
            n_ok = n_ok + 1;
        rd_p   = rd_p + 1;
        t_last = $realtime;
    end
endmodule


module tb_multi_bit_sync;
    localparam integer N = 300;
    wire d0, d1, d2, d3;
    integer ok0, ok1, ok2, ok3, e0, e1, e2, e3;
    real    t0, t1, t2, t3;
    integer errors = 0;

    xfer_test #(.MODE(0), .TSRC(10.0), .TDST(27.0), .N(N)) u0 (.done(d0), .n_ok(ok0), .n_err(e0), .ns_per_xfer(t0));
    xfer_test #(.MODE(1), .TSRC(10.0), .TDST(27.0), .N(N)) u1 (.done(d1), .n_ok(ok1), .n_err(e1), .ns_per_xfer(t1));
    xfer_test #(.MODE(0), .TSRC(27.0), .TDST(10.0), .N(N)) u2 (.done(d2), .n_ok(ok2), .n_err(e2), .ns_per_xfer(t2));
    xfer_test #(.MODE(1), .TSRC(27.0), .TDST(10.0), .N(N)) u3 (.done(d3), .n_ok(ok3), .n_err(e3), .ns_per_xfer(t3));

    initial begin
        $dumpfile("multi_bit_sync.vcd");
        $dumpvars(0, tb_multi_bit_sync);
        wait (d0 && d1 && d2 && d3);
        $display("----------------------------------------------------------");
        $display("scheme            clocks(src->dst)  ok/N      err   ns/xfer  src_cyc/xfer  dst_cyc/xfer");
        $display("4-phase handshake 10 -> 27 ns      %3d/%0d  %4d  %7.1f  %8.1f  %10.1f", ok0, N, e0, t0, t0/10.0, t0/27.0);
        $display("2-phase MCP       10 -> 27 ns      %3d/%0d  %4d  %7.1f  %8.1f  %10.1f", ok1, N, e1, t1, t1/10.0, t1/27.0);
        $display("4-phase handshake 27 -> 10 ns      %3d/%0d  %4d  %7.1f  %8.1f  %10.1f", ok2, N, e2, t2, t2/27.0, t2/10.0);
        $display("2-phase MCP       27 -> 10 ns      %3d/%0d  %4d  %7.1f  %8.1f  %10.1f", ok3, N, e3, t3, t3/27.0, t3/10.0);
        $display("----------------------------------------------------------");
        if (ok0 != N || ok1 != N || ok2 != N || ok3 != N || e0 || e1 || e2 || e3)
            errors = errors + 1;
        if (errors == 0) $display("PASS");
        else             $display("FAIL");
        $finish;
    end
endmodule
