// =============================================================================
// 单 bit 电平同步 testbench（自检查）
//   A 慢→快：src 30 ns，dst 10 ns，电平保持 2~6 个源周期
//   B 快→慢：src 10 ns，dst 37 ns，电平保持 >= 6 个源周期（> 1.5 个目的周期）
//   C 快→慢（违规）：同 B 的时钟，但电平只保持 1~3 个源周期 → 演示变化丢失
//
// 检查项（A、B）：
//   1. 源端每次电平变化都在目的端出现，次数相等
//   2. 延迟恰好是 STAGES 个目的时钟上升沿（RTL 仿真没有亚稳态，所以是确定值；
//      真实芯片里第 1 级亚稳时会多或少一拍，这就是"同步延迟不确定 1 拍"）
// C：期望目的端看到的变化次数 < 源端（丢失），否则说明演示场景没复现
// =============================================================================
`timescale 1ns / 1ps

module lvl_test #(
    parameter real    TSRC     = 30.0,
    parameter real    TDST     = 10.0,
    parameter real    DST_PH   = 1.3,     // 目的时钟相位，避免和源时钟沿重合
    parameter integer MIN_HOLD = 2,       // 电平保持的源周期数范围
    parameter integer MAX_HOLD = 6,
    parameter integer NTOG     = 100,
    parameter integer STAGES   = 2,
    parameter integer CHECK_LAT = 1
)(
    output reg     done,
    output integer n_src_tog,
    output integer n_dst_tog,
    output integer n_lat_err
);
    reg clk_src = 0, clk_dst = 0, rst_n = 0;
    reg lvl_src = 0;
    wire lvl_dst;

    always #(TSRC/2) clk_src = ~clk_src;
    initial begin #(DST_PH); forever #(TDST/2) clk_dst = ~clk_dst; end

    sync_2ff #(.WIDTH(1), .STAGES(STAGES)) u_sync (
        .clk_dst(clk_dst), .rst_dst_n(rst_n), .din(lvl_src), .dout(lvl_dst));

    // 电平保持时间可能短于 STAGES 个目的周期，同步器里会同时有多次变化在路上，
    // 所以按顺序记录每次源端变化时的目的沿计数，目的端出现变化时按顺序取出比较
    integer dst_edges;
    integer snap [0:1023];
    integer wr_p, rd_p;
    integer k;

    initial begin
        done = 0; n_src_tog = 0; n_dst_tog = 0; n_lat_err = 0;
        dst_edges = 0; wr_p = 0; rd_p = 0;
        #(3*TDST + 3*TSRC) rst_n = 1;
        repeat (3) @(posedge clk_src);
        for (k = 0; k < NTOG; k = k + 1) begin
            repeat (MIN_HOLD + $urandom % (MAX_HOLD - MIN_HOLD + 1)) @(posedge clk_src);
            lvl_src <= ~lvl_src;                // 源域寄存器输出
        end
        repeat (4 * STAGES) @(posedge clk_dst);
        repeat (2) @(posedge clk_src);
        done = 1;
    end

    always @(lvl_src) if (rst_n) begin
        n_src_tog  = n_src_tog + 1;
        snap[wr_p] = dst_edges;
        wr_p       = wr_p + 1;
    end
    always @(posedge clk_dst) dst_edges = dst_edges + 1;
    always @(lvl_dst) if (rst_n) begin
        n_dst_tog = n_dst_tog + 1;
        if (CHECK_LAT && dst_edges - snap[rd_p] != STAGES) n_lat_err = n_lat_err + 1;
        rd_p = rd_p + 1;
    end
endmodule


module tb_sync_2ff;
    wire da, db, dc;
    integer sa, ta, ea, sb, tb, eb, sc, tc, ec;
    integer errors = 0;

    lvl_test #(.TSRC(30.0), .TDST(10.0), .DST_PH(1.3), .MIN_HOLD(2), .MAX_HOLD(6))
        u_a (.done(da), .n_src_tog(sa), .n_dst_tog(ta), .n_lat_err(ea));
    lvl_test #(.TSRC(10.0), .TDST(37.0), .DST_PH(2.1), .MIN_HOLD(6), .MAX_HOLD(12))
        u_b (.done(db), .n_src_tog(sb), .n_dst_tog(tb), .n_lat_err(eb));
    lvl_test #(.TSRC(10.0), .TDST(37.0), .DST_PH(2.1), .MIN_HOLD(1), .MAX_HOLD(3), .CHECK_LAT(0))
        u_c (.done(dc), .n_src_tog(sc), .n_dst_tog(tc), .n_lat_err(ec));

    initial begin
        $dumpfile("sync_2ff.vcd");
        $dumpvars(0, tb_sync_2ff);
        wait (da && db && dc);
        $display("----------------------------------------------------------");
        $display("case                       src_toggles  dst_toggles  latency_err");
        $display("A slow->fast 30ns->10ns     %8d     %8d     %8d", sa, ta, ea);
        $display("B fast->slow hold>=6 src    %8d     %8d     %8d", sb, tb, eb);
        $display("C fast->slow hold 1~3 src   %8d     %8d          -", sc, tc);
        $display("----------------------------------------------------------");
        if (sa != ta || ea != 0) begin $display("ERROR: case A"); errors = errors + 1; end
        if (sb != tb || eb != 0) begin $display("ERROR: case B"); errors = errors + 1; end
        if (tc >= sc) begin $display("ERROR: case C 没有复现丢失"); errors = errors + 1; end
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
