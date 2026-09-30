// =============================================================================
// I2C testbench（自检查）：两个 i2c_master + 一个 i2c_slave（地址 0x50）挂在同一条开漏总线上
//   总线：tri1 模拟上拉电阻，各器件 *_oe=1 时拉低（线与）
//   参考模型：16 个寄存器 + 指针，按从机协议更新
//   引脚监视器（只看 SCL/SDA）：START/STOP 只能出现在字节边界；统计 START/STOP 数和 SCL 最长低电平
//   阶段：
//     P1 m0 随机事务 400 笔：写 1~4 字节 / 设指针后重复起始读 1~4 字节 / 从当前指针读 / 错误地址（期望 NACK）
//        每笔事务随机选从机时钟拉伸 0 或 20~60 clk
//     P2 仲裁：m0、m1 同时（相差 0~3 clk）向同一从机写不同的 {指针, 数据}，
//        期望"先发 0 的"赢（逐位比较，数值小的赢），输家报 arb_lost，赢家的写不受影响
// =============================================================================
`timescale 1ns / 1ps

module tb_i2c;
    localparam Q = 8;
    localparam [6:0] SADDR = 7'h50;
    localparam [1:0] C_START = 2'd0, C_WRITE = 2'd1, C_READ = 2'd2, C_STOP = 2'd3;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    tri1 scl, sda;
    wire m0_scl_oe, m0_sda_oe, m1_scl_oe, m1_sda_oe, s_scl_oe, s_sda_oe;
    assign scl = m0_scl_oe ? 1'b0 : 1'bz;
    assign sda = m0_sda_oe ? 1'b0 : 1'bz;
    assign scl = m1_scl_oe ? 1'b0 : 1'bz;
    assign sda = m1_sda_oe ? 1'b0 : 1'bz;
    assign scl = s_scl_oe  ? 1'b0 : 1'bz;
    assign sda = s_sda_oe  ? 1'b0 : 1'bz;

    reg        c0_v = 0, c1_v = 0, c0_nk = 0, c1_nk = 0;
    reg  [1:0] c0 = 0, c1 = 0;
    reg  [7:0] d0 = 0, d1 = 0;
    wire       r0_v, r1_v, rdy0, rdy1, ack0, ack1, lost0, lost1;
    wire [7:0] rd0, rd1;
    reg  [7:0] stretch = 0;

    i2c_master #(.Q(Q)) u_m0 (
        .clk(clk), .rst_n(rst_n), .cmd_valid(c0_v), .cmd_ready(rdy0), .cmd(c0), .wdata(d0), .rd_nack(c0_nk),
        .rsp_valid(r0_v), .rdata(rd0), .ack_n(ack0), .arb_lost(lost0),
        .scl_i(scl), .scl_oe(m0_scl_oe), .sda_i(sda), .sda_oe(m0_sda_oe));
    i2c_master #(.Q(Q)) u_m1 (
        .clk(clk), .rst_n(rst_n), .cmd_valid(c1_v), .cmd_ready(rdy1), .cmd(c1), .wdata(d1), .rd_nack(c1_nk),
        .rsp_valid(r1_v), .rdata(rd1), .ack_n(ack1), .arb_lost(lost1),
        .scl_i(scl), .scl_oe(m1_scl_oe), .sda_i(sda), .sda_oe(m1_sda_oe));
    i2c_slave #(.ADDR(SADDR)) u_s (
        .clk(clk), .rst_n(rst_n), .stretch(stretch),
        .scl_i(scl), .scl_oe(s_scl_oe), .sda_i(sda), .sda_oe(s_sda_oe));

    integer errors = 0;
    task err(input [8*48-1:0] msg);
        begin
            if (errors < 10) $display("ERROR @%0t: %0s", $time, msg);
            errors = errors + 1;
        end
    endtask

    // ---------------- 引脚监视器 ----------------
    // nbit：本次 START 以来 SCL 上升沿数。Sr / P 之前主机要先释放 SCL，多出 1 个上升沿，
    // 所以合法位置是 nbit == 0（空闲时起始）或 nbit % 9 == 1（第 9k 个时钟之后的那个 SCL 高电平）
    integer nbit = 0, n_start = 0, n_stop = 0;
    realtime t_fall = 0, max_low = 0;
    always @(negedge sda) if (rst_n && scl === 1'b1) begin
        if (nbit != 0 && nbit % 9 != 1) err("START inside a byte");
        n_start = n_start + 1; nbit = 0;
    end
    always @(posedge sda) if (rst_n && scl === 1'b1) begin
        if (nbit != 0 && nbit % 9 != 1) err("STOP inside a byte");
        n_stop = n_stop + 1; nbit = 0;
    end
    always @(posedge scl) if (rst_n) begin
        nbit = nbit + 1;
        if ($realtime - t_fall > max_low) max_low = $realtime - t_fall;
    end
    always @(negedge scl) t_fall = $realtime;

    // ---------------- 主机命令 ----------------
    reg [7:0] g_rd;
    reg       g_ack, g_lost;
    task m0cmd(input [1:0] c, input [7:0] d, input nk);
        begin
            @(negedge clk); c0_v = 1; c0 = c; d0 = d; c0_nk = nk;
            @(posedge clk); while (!rdy0) @(posedge clk);
            @(negedge clk); c0_v = 0;
            @(posedge r0_v); g_rd = rd0; g_ack = ack0; g_lost = lost0;
        end
    endtask
    reg [7:0] h_rd;
    reg       h_ack, h_lost;
    task m1cmd(input [1:0] c, input [7:0] d, input nk);
        begin
            @(negedge clk); c1_v = 1; c1 = c; d1 = d; c1_nk = nk;
            @(posedge clk); while (!rdy1) @(posedge clk);
            @(negedge clk); c1_v = 0;
            @(posedge r1_v); h_rd = rd1; h_ack = ack1; h_lost = lost1;
        end
    endtask

    // ---------------- 参考模型 ----------------
    reg [7:0] mreg [0:15];
    reg [3:0] mptr = 0;
    integer   n_wr = 0, n_rd = 0, n_nack = 0, n_bytes_chk = 0, n_stretch = 0, k, n;
    reg [7:0] b;
    reg [3:0] p;

    task do_write;
        begin
            p = $urandom; n = 1 + $urandom % 4;
            m0cmd(C_START, 0, 0);
            m0cmd(C_WRITE, {SADDR, 1'b0}, 0); if (g_ack) err("addr W not ACKed");
            m0cmd(C_WRITE, {4'h0, p}, 0);     if (g_ack) err("ptr not ACKed");
            mptr = p;
            for (k = 0; k < n; k = k + 1) begin
                b = $urandom;
                m0cmd(C_WRITE, b, 0); if (g_ack) err("data not ACKed");
                mreg[mptr] = b; mptr = mptr + 1;
            end
            m0cmd(C_STOP, 0, 0);
            n_wr = n_wr + 1;
        end
    endtask

    task do_read(input set_ptr);
        begin
            n = 1 + $urandom % 4;
            m0cmd(C_START, 0, 0);
            if (set_ptr) begin
                p = $urandom;
                m0cmd(C_WRITE, {SADDR, 1'b0}, 0); if (g_ack) err("addr W not ACKed");
                m0cmd(C_WRITE, {4'h0, p}, 0);     if (g_ack) err("ptr not ACKed");
                mptr = p;
                m0cmd(C_START, 0, 0);                                   // 重复起始
            end
            m0cmd(C_WRITE, {SADDR, 1'b1}, 0); if (g_ack) err("addr R not ACKed");
            for (k = 0; k < n; k = k + 1) begin
                m0cmd(C_READ, 0, (k == n - 1));                         // 最后一个字节回 NACK
                if (g_rd !== mreg[mptr]) err("read data mismatch");
                mptr = mptr + 1; n_bytes_chk = n_bytes_chk + 1;
            end
            m0cmd(C_STOP, 0, 0);
            n_rd = n_rd + 1;
        end
    endtask

    task do_bad_addr;
        begin
            m0cmd(C_START, 0, 0);
            m0cmd(C_WRITE, {7'h23, 1'b0}, 0); if (!g_ack) err("wrong addr was ACKed");
            m0cmd(C_STOP, 0, 0);
            n_nack = n_nack + 1;
        end
    endtask

    // ---------------- 仲裁 ----------------
    integer n_arb = 0, n_arb_ok = 0, win_expect, off;
    reg [3:0] ap0, ap1;
    reg [7:0] ad0, ad1;
    reg       done0, done1, lost_seen0, lost_seen1;

    task arb_trial;
        begin
            ap0 = $urandom; ap1 = $urandom; ad0 = $urandom; ad1 = $urandom;
            if (ap0 == ap1 && ad0 == ad1) ad1 = ad0 ^ 8'h01;
            // 逐位比较，先出现 0 的赢 → 数值小的 {ptr, data} 赢
            win_expect = ({ap0, ad0} < {ap1, ad1}) ? 0 : 1;
            off = $urandom % 4;
            lost_seen0 = 0; lost_seen1 = 0;
            fork
                begin
                    m0cmd(C_START, 0, 0);
                    m0cmd(C_WRITE, {SADDR, 1'b0}, 0);
                    m0cmd(C_WRITE, {4'h0, ap0}, 0); if (g_lost) lost_seen0 = 1;
                    if (!lost_seen0) begin m0cmd(C_WRITE, ad0, 0); if (g_lost) lost_seen0 = 1; end
                    if (!lost_seen0) m0cmd(C_STOP, 0, 0);
                end
                begin
                    repeat (off) @(posedge clk);
                    m1cmd(C_START, 0, 0);
                    m1cmd(C_WRITE, {SADDR, 1'b0}, 0);
                    m1cmd(C_WRITE, {4'h0, ap1}, 0); if (h_lost) lost_seen1 = 1;
                    if (!lost_seen1) begin m1cmd(C_WRITE, ad1, 0); if (h_lost) lost_seen1 = 1; end
                    if (!lost_seen1) m1cmd(C_STOP, 0, 0);
                end
            join
            n_arb = n_arb + 1;
            if (win_expect == 0 && !lost_seen0 && lost_seen1) begin
                n_arb_ok = n_arb_ok + 1; mreg[ap0] = ad0; mptr = ap0 + 1;
            end else if (win_expect == 1 && lost_seen0 && !lost_seen1) begin
                n_arb_ok = n_arb_ok + 1; mreg[ap1] = ad1; mptr = ap1 + 1;
            end else err("arbitration result wrong");
            repeat (20) @(posedge clk);
        end
    endtask

    integer i, r;
    initial begin
        $dumpfile("i2c.vcd");
        $dumpvars(0, tb_i2c);
        for (i = 0; i < 16; i = i + 1) begin
            mreg[i] = $urandom; u_s.regs[i] = mreg[i];
        end
        #22 rst_n = 1;
        repeat (10) @(posedge clk);

        // P1
        for (i = 0; i < 400; i = i + 1) begin
            if (($urandom % 3) == 0) begin stretch = 20 + $urandom % 41; n_stretch = n_stretch + 1; end
            else stretch = 0;
            r = $urandom % 10;
            if      (r < 4) do_write;
            else if (r < 7) do_read(1);
            else if (r < 9) do_read(0);
            else            do_bad_addr;
            if (i == 20) $dumpoff;
        end
        stretch = 0;
        $display("---------------------------------------------------------------");
        $display("P1 m0: write=%0d read=%0d (bytes checked %0d) wrong-addr NACK=%0d  stretched txns=%0d",
                 n_wr, n_rd, n_bytes_chk, n_nack, n_stretch);
        $display("   bus monitor: START(incl. Sr)=%0d STOP=%0d  max SCL low=%0.0f ns (nominal %0d ns)",
                 n_start, n_stop, max_low, 2 * Q * 10);

        // P2
        for (i = 0; i < 100; i = i + 1) arb_trial;
        // 仲裁后读回全部寄存器，确认只有赢家的写生效
        m0cmd(C_START, 0, 0);
        m0cmd(C_WRITE, {SADDR, 1'b0}, 0);
        m0cmd(C_WRITE, 8'h00, 0); mptr = 0;
        m0cmd(C_START, 0, 0);
        m0cmd(C_WRITE, {SADDR, 1'b1}, 0);
        for (k = 0; k < 16; k = k + 1) begin
            m0cmd(C_READ, 0, (k == 15));
            if (g_rd !== mreg[k]) err("register wrong after arbitration");
        end
        m0cmd(C_STOP, 0, 0);
        $display("P2 arbitration: %0d/%0d trials OK (winner data written, loser flagged arb_lost)",
                 n_arb_ok, n_arb);
        $display("---------------------------------------------------------------");
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("ERROR: timeout");
        $display("FAIL (%0d errors + timeout)", errors);
        $finish;
    end
endmodule
