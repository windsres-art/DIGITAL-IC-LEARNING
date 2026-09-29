// =============================================================================
// 同步 FIFO testbench（自检查）
//   参考模型：TB 里的数组队列。每个时钟上升沿先比对 full/empty/count，
//   再按"本拍是否真的写/读"更新模型；读出的数据在下一拍下降沿和模型比对。
//   三个阶段：
//     1 偏写（写 90%、读 10%）→ 必然写满，并在满时继续尝试写
//     2 偏读（写 10%、读 90%）→ 必然读空，并在空时继续尝试读
//     3 随机（各 50%）      → 满空之间来回，包括同拍读写
// =============================================================================
`timescale 1ns / 1ps

module tb_fifo_sync;
    parameter DW = 8;
    parameter AW = 3;                       // 深度 8，方便看波形
    localparam DEPTH = 1 << AW;
    localparam NCYC  = 3000;                // 每个阶段的周期数

    reg           clk = 0, rst_n = 0;
    reg           wr_en = 0, rd_en = 0;
    reg  [DW-1:0] wdata = 0;
    wire [DW-1:0] rdata;
    wire          full, empty;
    wire [AW:0]   count;

    always #5 clk = ~clk;

    fifo_sync #(.DW(DW), .AW(AW)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wdata(wdata),
        .rd_en(rd_en), .rdata(rdata),
        .full(full), .empty(empty), .count(count));

    // ---------------- 参考模型 ----------------
    reg [DW-1:0] q [0:65535];
    integer wp = 0, rp = 0;                 // 模型的写/读序号（不取模，只增）
    integer errors = 0;
    integer n_wr = 0, n_rd = 0, n_same = 0;
    integer n_wr_blk = 0, n_rd_blk = 0;     // 满时写、空时读被正确挡住的次数
    integer n_full_cyc = 0, n_empty_cyc = 0;
    reg          chk_pending = 0;
    reg [DW-1:0] exp_rdata;
    integer      m_cnt;
    reg          do_wr, do_rd;

    always @(posedge clk) if (rst_n) begin
        m_cnt = wp - rp;
        if (full !== (m_cnt == DEPTH) || empty !== (m_cnt == 0) || count !== m_cnt) begin
            if (errors < 10)
                $display("ERROR @%0t: full=%b empty=%b count=%0d, model count=%0d",
                         $time, full, empty, count, m_cnt);
            errors = errors + 1;
        end
        if (full)  n_full_cyc  = n_full_cyc + 1;
        if (empty) n_empty_cyc = n_empty_cyc + 1;

        do_wr = wr_en && (m_cnt != DEPTH);
        do_rd = rd_en && (m_cnt != 0);
        if (wr_en && !do_wr) n_wr_blk = n_wr_blk + 1;
        if (rd_en && !do_rd) n_rd_blk = n_rd_blk + 1;
        if (do_wr && do_rd)  n_same   = n_same + 1;

        chk_pending = do_rd;
        if (do_rd) begin exp_rdata = q[rp[15:0]]; rp = rp + 1; n_rd = n_rd + 1; end
        if (do_wr) begin q[wp[15:0]] = wdata;     wp = wp + 1; n_wr = n_wr + 1; end
    end

    // 同步读：读出数据在读有效的下一拍才出现，放到下降沿比对
    always @(negedge clk) if (chk_pending) begin
        if (rdata !== exp_rdata) begin
            if (errors < 10)
                $display("ERROR @%0t: rdata=%0h expect=%0h", $time, rdata, exp_rdata);
            errors = errors + 1;
        end
        chk_pending = 0;
    end

    // ---------------- 激励（下降沿改输入，远离采样沿）----------------
    task run_phase(input integer wr_pct, input integer rd_pct);
        integer k;
        begin
            for (k = 0; k < NCYC; k = k + 1) begin
                @(negedge clk);
                wr_en <= ($urandom % 100) < wr_pct;
                rd_en <= ($urandom % 100) < rd_pct;
                wdata <= $urandom;
            end
        end
    endtask

    integer i;
    initial begin
        $dumpfile("fifo_sync.vcd");
        $dumpvars(0, tb_fifo_sync);
        for (i = 0; i < DEPTH; i = i + 1) $dumpvars(0, u_dut.mem[i]);

        #22 rst_n = 1;
        run_phase(90, 10);
        run_phase(10, 90);
        run_phase(50, 50);
        @(negedge clk); wr_en <= 0; rd_en <= 0;
        repeat (3) @(negedge clk);

        $display("------------------------------------------------");
        $display("depth=%0d  writes=%0d  reads=%0d  same-cycle r+w=%0d",
                 DEPTH, n_wr, n_rd, n_same);
        $display("cycles full=%0d  empty=%0d", n_full_cyc, n_empty_cyc);
        $display("blocked: write-when-full=%0d  read-when-empty=%0d", n_wr_blk, n_rd_blk);
        $display("------------------------------------------------");
        if (n_wr_blk == 0 || n_rd_blk == 0) begin
            $display("ERROR: 没有覆盖到满写/空读");
            errors = errors + 1;
        end
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
