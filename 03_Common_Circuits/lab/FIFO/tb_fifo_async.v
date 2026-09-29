// =============================================================================
// 异步 FIFO testbench（自检查），同时测整理版 fifo_async.v 和早期版 FIFO.v
//   每个场景写入 NWORDS 个随机数据，读侧逐个和期望序列比对（顺序、数值）。
//   额外统计：
//     occ          = 已写入个数 - 已读出个数（TB 看到的"真实"存量）
//     false full   = full=1 但真实存量 < DEPTH 的写时钟周期数（偏保守的体现）
//     false empty  = empty=1 但真实存量 > 0 的读时钟周期数
//     gray_evt     = 本域 Gray 指针"每次变化"超过 1 bit 的次数（事件级，含零宽度毛刺）
//     gray_smp     = 本域时钟沿后 1 ns 采样，相邻两次采样超过 1 bit 的次数
//   检查：数据全部正确、从不写穿（接受写时 occ < DEPTH）、从不读穿、gray_smp = 0；
//   整理版还要求 gray_evt = 0。FIFO.v 的 Gray 是组合 XOR，gray_evt 不为 0 是
//   预期现象，只打印不判错（见章 README 1.3 节）。
// =============================================================================
`timescale 1ns / 1ps

module afifo_case #(
    parameter real    TW     = 10.0,    // 写时钟周期
    parameter real    TR     = 27.0,    // 读时钟周期
    parameter real    RPH    = 1.7,     // 读时钟起始相位
    parameter integer WR_PCT = 100,     // 每拍尝试写的概率（%）
    parameter integer RD_PCT = 100,     // 每拍尝试读的概率（%）
    parameter integer NWORDS = 2000,
    parameter integer USE_OLD = 0       // 1：测 FIFO.v
)(
    output reg     done,
    output integer errors,
    output integer n_full,  output integer n_false_full,
    output integer n_empty, output integer n_false_empty,
    output integer max_occ, output integer n_gray_err, output integer n_gray_smp_err
);
    localparam DW = 8, AW = 3, DEPTH = 1 << AW;

    reg           wclk = 0, rclk = 0, wrst_n = 0, rrst_n = 0;
    reg           wr_en = 0, rd_en = 0;
    reg  [DW-1:0] wdata = 0;
    wire [DW-1:0] rdata;
    wire          full, empty;
    wire [AW:0]   wg, rg;

    always #(TW/2) wclk = ~wclk;
    initial begin #(RPH); forever #(TR/2) rclk = ~rclk; end

    generate if (USE_OLD) begin : g_old
        FIFO_async #(.FIFO_data_size(DW), .FIFO_addr_size(AW)) u_dut (
            .clk_w(wclk), .rst_w(wrst_n), .w_en(wr_en), .data_in(wdata),
            .clk_r(rclk), .rst_r(rrst_n), .r_en(rd_en), .data_out(rdata),
            .empty(empty), .full(full));
        assign wg = u_dut.w_pointer_gray;
        assign rg = u_dut.r_pointer_gray;
    end else begin : g_new
        fifo_async #(.DW(DW), .AW(AW)) u_dut (
            .wclk(wclk), .wrst_n(wrst_n), .wr_en(wr_en), .wdata(wdata), .wfull(full),
            .rclk(rclk), .rrst_n(rrst_n), .rd_en(rd_en), .rdata(rdata), .rempty(empty));
        assign wg = u_dut.wgray;
        assign rg = u_dut.rgray;
    end endgenerate

    reg [DW-1:0] exp_data [0:NWORDS-1];
    integer wcnt = 0, rcnt = 0, occ, k;
    reg          chk_pending = 0;
    reg [DW-1:0] exp_rdata;

    function integer popcount(input [AW:0] v);
        integer b;
        begin
            popcount = 0;
            for (b = 0; b <= AW; b = b + 1) popcount = popcount + v[b];
        end
    endfunction

    initial begin
        done = 0; errors = 0; n_full = 0; n_false_full = 0;
        n_empty = 0; n_false_empty = 0; max_occ = 0; n_gray_err = 0; n_gray_smp_err = 0;
        for (k = 0; k < NWORDS; k = k + 1) exp_data[k] = $urandom;
        #(2*TW) wrst_n = 1;
        #(3*TR) rrst_n = 1;                 // 两域复位释放时刻不同
    end

    // ---------------- 写侧 ----------------
    always @(negedge wclk) if (wrst_n) begin
        wr_en <= (wcnt < NWORDS) && (($urandom % 100) < WR_PCT);
        wdata <= (wcnt < NWORDS) ? exp_data[wcnt] : {DW{1'b0}};
    end

    always @(posedge wclk) if (wrst_n) begin
        occ = wcnt - rcnt;
        if (full) begin
            n_full = n_full + 1;
            if (occ < DEPTH) n_false_full = n_false_full + 1;
        end
        if (wr_en && !full) begin
            if (occ >= DEPTH) begin
                $display("ERROR @%0t: 写穿 occ=%0d", $time, occ);
                errors = errors + 1;
            end
            wcnt = wcnt + 1;
            if (wcnt - rcnt > max_occ) max_occ = wcnt - rcnt;
        end
    end

    // ---------------- 读侧 ----------------
    always @(negedge rclk) if (rrst_n) begin
        if (chk_pending) begin
            if (rdata !== exp_rdata) begin
                if (errors < 5)
                    $display("ERROR @%0t: rdata=%0h expect=%0h", $time, rdata, exp_rdata);
                errors = errors + 1;
            end
            chk_pending = 0;
        end
        rd_en <= (rcnt < NWORDS) && (($urandom % 100) < RD_PCT);
    end

    always @(posedge rclk) if (rrst_n) begin
        occ = wcnt - rcnt;
        if (empty) begin
            n_empty = n_empty + 1;
            if (occ > 0) n_false_empty = n_false_empty + 1;
        end
        if (rd_en && !empty) begin
            if (occ <= 0) begin
                $display("ERROR @%0t: 读穿", $time);
                errors = errors + 1;
            end
            exp_rdata   = exp_data[rcnt];
            chk_pending = 1;
            rcnt = rcnt + 1;
        end
    end

    // ---------------- Gray 指针每次只变 1 bit ----------------
    // 事件级：信号每次变化都检查（能看到组合逻辑的零宽度 delta 毛刺）
    reg [AW:0] wg_prev = 0, rg_prev = 0;
    always @(wg) begin
        if (popcount(wg ^ wg_prev) > 1) n_gray_err = n_gray_err + 1;
        wg_prev = wg;
    end
    always @(rg) begin
        if (popcount(rg ^ rg_prev) > 1) n_gray_err = n_gray_err + 1;
        rg_prev = rg;
    end
    // 采样级：本域时钟沿后 1 ns 采一次（稳定值）
    reg [AW:0] wg_smp = 0, rg_smp = 0;
    always @(posedge wclk) begin
        #1;
        if (popcount(wg ^ wg_smp) > 1) n_gray_smp_err = n_gray_smp_err + 1;
        wg_smp = wg;
    end
    always @(posedge rclk) begin
        #1;
        if (popcount(rg ^ rg_smp) > 1) n_gray_smp_err = n_gray_smp_err + 1;
        rg_smp = rg;
    end

    initial begin
        wait (rcnt == NWORDS);
        repeat (3) @(posedge rclk);
        done = 1;
    end
endmodule


// 定向测延迟：空 FIFO 写入 1 个字，数读时钟上升沿直到 empty 撤销；
// 读出后再写满，数写时钟上升沿直到读走一个后 full 撤销。两时钟同为 10 ns，读时钟晚 3 ns。
module afifo_latency #(parameter integer USE_OLD = 0)(
    output reg     done,
    output integer empty_lat,           // 写入沿 → empty=0 的读时钟沿数
    output integer full_lat             // 读出沿 → full=0 的写时钟沿数
);
    localparam DW = 8, AW = 3, DEPTH = 1 << AW;
    reg wclk = 0, rclk = 0, wrst_n = 0, rrst_n = 0, wr_en = 0, rd_en = 0;
    reg  [DW-1:0] wdata = 8'h5a;
    wire [DW-1:0] rdata;
    wire full, empty;
    always #5 wclk = ~wclk;
    initial begin #3; forever #5 rclk = ~rclk; end

    generate if (USE_OLD) begin : g_old
        FIFO_async #(.FIFO_data_size(DW), .FIFO_addr_size(AW)) u_dut (
            .clk_w(wclk), .rst_w(wrst_n), .w_en(wr_en), .data_in(wdata),
            .clk_r(rclk), .rst_r(rrst_n), .r_en(rd_en), .data_out(rdata),
            .empty(empty), .full(full));
    end else begin : g_new
        fifo_async #(.DW(DW), .AW(AW)) u_dut (
            .wclk(wclk), .wrst_n(wrst_n), .wr_en(wr_en), .wdata(wdata), .wfull(full),
            .rclk(rclk), .rrst_n(rrst_n), .rd_en(rd_en), .rdata(rdata), .rempty(empty));
    end endgenerate

    integer n;
    initial begin
        done = 0; empty_lat = 0; full_lat = 0;
        #22 wrst_n = 1; rrst_n = 1;
        repeat (5) @(posedge wclk);
        // 写 1 个：wr_en 在这个写沿被采样
        @(negedge wclk) wr_en = 1;
        @(posedge wclk); #1 wr_en = 0;
        n = 0;
        while (empty) begin @(posedge rclk); #0.5; n = n + 1; end
        empty_lat = n;
        // 读走它，再写满
        @(negedge rclk) rd_en = 1;
        @(posedge rclk); #1 rd_en = 0;
        repeat (6) @(posedge wclk);
        @(negedge wclk) wr_en = 1;
        while (!full) @(negedge wclk);
        wr_en = 0;
        repeat (6) @(posedge rclk);
        // 读 1 个：rd_en 在这个读沿被采样
        @(negedge rclk) rd_en = 1;
        @(posedge rclk); #1 rd_en = 0;
        n = 0;
        while (full) begin @(posedge wclk); #0.5; n = n + 1; end
        full_lat = n;
        done = 1;
    end
endmodule


module tb_fifo_async;
    localparam N = 6;
    wire [N-1:0] done;
    integer e [0:N-1], fu [0:N-1], ffu [0:N-1], em [0:N-1], fem [0:N-1], mo [0:N-1];
    integer ge [0:N-1], gs [0:N-1];
    integer errors = 0, i;

    // 场景 A：写快读慢，两边都满负荷 → 常满
    // 场景 B：写慢读快 → 常空
    // 场景 C：频率接近，随机使能 → 满空都会出现
    afifo_case #(.TW(10.0), .TR(27.0), .WR_PCT(100), .RD_PCT(100), .USE_OLD(0)) a0
        (done[0], e[0], fu[0], ffu[0], em[0], fem[0], mo[0], ge[0], gs[0]);
    afifo_case #(.TW(27.0), .TR(10.0), .WR_PCT(100), .RD_PCT(100), .USE_OLD(0)) b0
        (done[1], e[1], fu[1], ffu[1], em[1], fem[1], mo[1], ge[1], gs[1]);
    afifo_case #(.TW(10.0), .TR(13.0), .WR_PCT(70),  .RD_PCT(60),  .USE_OLD(0)) c0
        (done[2], e[2], fu[2], ffu[2], em[2], fem[2], mo[2], ge[2], gs[2]);
    afifo_case #(.TW(10.0), .TR(27.0), .WR_PCT(100), .RD_PCT(100), .USE_OLD(1)) a1
        (done[3], e[3], fu[3], ffu[3], em[3], fem[3], mo[3], ge[3], gs[3]);
    afifo_case #(.TW(27.0), .TR(10.0), .WR_PCT(100), .RD_PCT(100), .USE_OLD(1)) b1
        (done[4], e[4], fu[4], ffu[4], em[4], fem[4], mo[4], ge[4], gs[4]);
    afifo_case #(.TW(10.0), .TR(13.0), .WR_PCT(70),  .RD_PCT(60),  .USE_OLD(1)) c1
        (done[5], e[5], fu[5], ffu[5], em[5], fem[5], mo[5], ge[5], gs[5]);

    wire [1:0] ldone;
    integer el [0:1], fl [0:1];
    afifo_latency #(.USE_OLD(0)) l0 (ldone[0], el[0], fl[0]);
    afifo_latency #(.USE_OLD(1)) l1 (ldone[1], el[1], fl[1]);

    initial begin
        $dumpfile("fifo_async_check.vcd");
        $dumpvars(0, a0);
        $dumpvars(0, l0);
        fork
            wait (&done && &ldone);
            begin #2000000; $display("ERROR: timeout"); errors = errors + 1; end
        join_any
        $display("----------------------------------------------------------------------------------------------");
        $display("case                 dut         err  full  false_full  empty  false_empty  max_occ  gray_evt  gray_smp");
        for (i = 0; i < N; i = i + 1) begin
            $display("%s  %s  %3d  %4d  %10d  %5d  %11d  %7d  %8d  %8d",
                     (i % 3 == 0) ? "A wr 10ns/rd 27ns" :
                     (i % 3 == 1) ? "B wr 27ns/rd 10ns" : "C wr 10ns/rd 13ns",
                     (i < 3) ? "fifo_async" : "FIFO.v    ",
                     e[i], fu[i], ffu[i], em[i], fem[i], mo[i], ge[i], gs[i]);
            errors = errors + e[i] + gs[i] + ((i < 3) ? ge[i] : 0);
            if (mo[i] > 8) errors = errors + 1;
        end
        $display("----------------------------------------------------------------------------------------------");
        $display("latency (both clocks 10 ns): write -> empty=0 after N rclk edges; read -> full=0 after N wclk edges");
        $display("  fifo_async (registered flags): empty %0d, full %0d", el[0], fl[0]);
        $display("  FIFO.v     (combinational)   : empty %0d, full %0d", el[1], fl[1]);
        if (el[0] != 3 || fl[0] != 3 || el[1] != 2 || fl[1] != 2) begin
            $display("ERROR: 同步延迟与预期（整理版 3 拍、FIFO.v 2 拍）不符");
            errors = errors + 1;
        end
        $display("----------------------------------------------------------------------------------------------");
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
