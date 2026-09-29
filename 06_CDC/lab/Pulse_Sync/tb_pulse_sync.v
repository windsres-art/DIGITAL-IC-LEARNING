// =============================================================================
// 脉冲同步 testbench（自检查）
//   A 快→慢：src 10 ns → dst 33 ns，源端遵守 busy 发脉冲
//   B 慢→快：src 37 ns → dst 10 ns，源端遵守 busy 发脉冲
//   C 快→慢：同 A 的时钟，但无视 busy，脉冲间隔 1~4 个源周期（违规）
//   每个场景同时接 pulse_sync（toggle 型）和 pulse_sync_naive（直接打两拍）
//
// 检查：A、B 中 toggle 型输出脉冲数 == 输入脉冲数；
//       A 中 naive 丢脉冲（演示问题）；C 中 toggle 型也会丢（演示间隔约束）
// =============================================================================
`timescale 1ns / 1ps

module pulse_test #(
    parameter real    TSRC      = 10.0,
    parameter real    TDST      = 33.0,
    parameter real    DST_PH    = 1.7,
    parameter integer OBEY_BUSY = 1,
    parameter integer MAX_GAP   = 4,     // 额外随机间隔（源周期）
    parameter integer NPULSE    = 200
)(
    output reg     done,
    output integer n_in,
    output integer n_out,
    output integer n_naive,
    output integer busy_max      // 观察到的最长 busy（源周期数）
);
    reg clk_src = 0, clk_dst = 0, rst_n = 0;
    reg pulse_src = 0;
    wire busy, pulse_dst, pulse_naive;

    always #(TSRC/2) clk_src = ~clk_src;
    initial begin #(DST_PH); forever #(TDST/2) clk_dst = ~clk_dst; end

    pulse_sync u_dut (
        .clk_src(clk_src), .rst_src_n(rst_n), .pulse_src(pulse_src), .busy(busy),
        .clk_dst(clk_dst), .rst_dst_n(rst_n), .pulse_dst(pulse_dst));
    pulse_sync_naive u_naive (
        .clk_dst(clk_dst), .rst_dst_n(rst_n), .pulse_src(pulse_src), .pulse_dst(pulse_naive));

    integer k, busy_cnt;

    initial begin
        done = 0; n_in = 0; n_out = 0; n_naive = 0; busy_max = 0; busy_cnt = 0;
        #(3*TSRC + 3*TDST) rst_n = 1;
        repeat (3) @(posedge clk_src);
        for (k = 0; k < NPULSE; k = k + 1) begin
            if (OBEY_BUSY)
                while (busy) @(posedge clk_src);
            pulse_src <= 1'b1;
            @(posedge clk_src);
            pulse_src <= 1'b0;
            n_in = n_in + 1;
            repeat (1 + $urandom % MAX_GAP) @(posedge clk_src);
        end
        repeat (10) @(posedge clk_dst);
        repeat (10) @(posedge clk_src);
        done = 1;
    end

    // 目的端：每个为 1 的周期算一个脉冲
    always @(posedge clk_dst) if (rst_n) begin
        if (pulse_dst)   n_out   = n_out + 1;
        if (pulse_naive) n_naive = n_naive + 1;
    end

    always @(posedge clk_src) begin
        if (busy) busy_cnt = busy_cnt + 1;
        else      busy_cnt = 0;
        if (busy_cnt > busy_max) busy_max = busy_cnt;
    end
endmodule


module tb_pulse_sync;
    wire da, db, dc;
    integer ia, oa, na, ba, ib, ob, nb, bb, ic, oc, nc, bc;
    integer errors = 0;

    pulse_test #(.TSRC(10.0), .TDST(33.0), .DST_PH(1.7), .OBEY_BUSY(1))
        u_a (.done(da), .n_in(ia), .n_out(oa), .n_naive(na), .busy_max(ba));
    pulse_test #(.TSRC(37.0), .TDST(10.0), .DST_PH(1.7), .OBEY_BUSY(1))
        u_b (.done(db), .n_in(ib), .n_out(ob), .n_naive(nb), .busy_max(bb));
    pulse_test #(.TSRC(10.0), .TDST(33.0), .DST_PH(1.7), .OBEY_BUSY(0))
        u_c (.done(dc), .n_in(ic), .n_out(oc), .n_naive(nc), .busy_max(bc));

    initial begin
        $dumpfile("pulse_sync.vcd");
        $dumpvars(0, tb_pulse_sync);
        wait (da && db && dc);
        $display("----------------------------------------------------------");
        $display("case                        pulses_in  toggle_out  naive_out  max_busy(src cyc)");
        $display("A fast->slow 10->33, busy   %8d    %8d   %8d   %8d", ia, oa, na, ba);
        $display("B slow->fast 37->10, busy   %8d    %8d   %8d   %8d", ib, ob, nb, bb);
        $display("C fast->slow, ignore busy   %8d    %8d   %8d          -", ic, oc, nc);
        $display("----------------------------------------------------------");
        if (oa != ia) begin $display("ERROR: A toggle 型丢脉冲"); errors = errors + 1; end
        if (ob != ib) begin $display("ERROR: B toggle 型丢脉冲"); errors = errors + 1; end
        if (na >= ia) begin $display("ERROR: A naive 没有复现丢脉冲"); errors = errors + 1; end
        if (oc >= ic) begin $display("ERROR: C 没有复现间隔过近导致的丢失"); errors = errors + 1; end
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
