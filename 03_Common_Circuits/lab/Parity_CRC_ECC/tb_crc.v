// =============================================================================
// 奇偶校验 + CRC testbench（自检查）
//   1. parity：8 bit 偶 / 奇校验全遍历；所有 1 bit 错、2 bit 错的检出情况
//   2. CRC 标准校验值（"123456789"）：CRC-8、CRC-16/CCITT-FALSE、CRC-32，
//      串行（每拍 1 bit）与并行（每拍 1 字节）两种实现都算，原始余数必须相同
//   3. 200 条随机长度消息：三种标准下串行 == 并行
//   4. CRC-32 并行 DW = 32（小端拼字）与 DW = 8 逐字节结果相同
//   5. CRC-8（x^8+x^2+x+1）检错能力：64 bit 消息 + 8 bit CRC = 72 bit 码字，
//      码字整体再过一遍 CRC 余数为 0；注入各类错误统计漏检
// =============================================================================
`timescale 1ns / 1ps

module tb_crc;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    integer errors = 0, k, i, j, b;

    // ======================= parity =======================
    reg  [7:0] pd; reg pin_e, pin_o;
    wire       pe, po, ee, eo;
    parity #(.DW(8), .ODD(0)) u_pe (.data(pd), .par_in(pin_e), .par(pe), .err(ee));
    parity #(.DW(8), .ODD(1)) u_po (.data(pd), .par_in(pin_o), .par(po), .err(eo));
    integer p_err = 0, p_single_miss = 0, p_double_det = 0, ones;
    reg [8:0] cw_e, cw_o, ecw;

    // ======================= CRC 实例 =======================
    // 并行，每拍 1 字节
    reg        pc_clr = 0, pc_en = 0;
    reg  [7:0] pc_d = 0;
    wire [7:0]  p8_crc,  p8_out;
    wire [15:0] p16_crc, p16_out;
    wire [31:0] p32_crc, p32_out;
    crc_parallel #(.W(8),  .DW(8), .POLY(8'h07),         .INIT(8'h00),         .REFIN(0), .REFOUT(0), .XOROUT(8'h00))
        u_p8  (.clk(clk), .rst_n(rst_n), .clr(pc_clr), .en(pc_en), .data(pc_d), .crc(p8_crc),  .crc_out(p8_out));
    crc_parallel #(.W(16), .DW(8), .POLY(16'h1021),      .INIT(16'hFFFF),      .REFIN(0), .REFOUT(0), .XOROUT(16'h0000))
        u_p16 (.clk(clk), .rst_n(rst_n), .clr(pc_clr), .en(pc_en), .data(pc_d), .crc(p16_crc), .crc_out(p16_out));
    crc_parallel #(.W(32), .DW(8), .POLY(32'h04C11DB7),  .INIT(32'hFFFFFFFF),  .REFIN(1), .REFOUT(1), .XOROUT(32'hFFFFFFFF))
        u_p32 (.clk(clk), .rst_n(rst_n), .clr(pc_clr), .en(pc_en), .data(pc_d), .crc(p32_crc), .crc_out(p32_out));

    // 串行，每拍 1 bit；REFIN 由喂入顺序体现（CRC-32 每字节低位先进）
    reg  sc_clr = 0, sc_en = 0, s_msb = 0, s_lsb = 0;
    wire [7:0]  s8_crc;
    wire [15:0] s16_crc;
    wire [31:0] s32_crc;
    crc_serial #(.W(8),  .POLY(8'h07),        .INIT(8'h00))        u_s8  (.clk(clk), .rst_n(rst_n), .clr(sc_clr), .en(sc_en), .din(s_msb), .crc(s8_crc));
    crc_serial #(.W(16), .POLY(16'h1021),     .INIT(16'hFFFF))     u_s16 (.clk(clk), .rst_n(rst_n), .clr(sc_clr), .en(sc_en), .din(s_msb), .crc(s16_crc));
    crc_serial #(.W(32), .POLY(32'h04C11DB7), .INIT(32'hFFFFFFFF)) u_s32 (.clk(clk), .rst_n(rst_n), .clr(sc_clr), .en(sc_en), .din(s_lsb), .crc(s32_crc));

    // CRC-32，每拍 32 bit
    reg         w_clr = 0, w_en = 0;
    reg  [31:0] w_d = 0;
    wire [31:0] w_crc, w_out;
    crc_parallel #(.W(32), .DW(32), .POLY(32'h04C11DB7), .INIT(32'hFFFFFFFF), .REFIN(1), .REFOUT(1), .XOROUT(32'hFFFFFFFF))
        u_w32 (.clk(clk), .rst_n(rst_n), .clr(w_clr), .en(w_en), .data(w_d), .crc(w_crc), .crc_out(w_out));

    // CRC-8 检错统计用
    reg        e_clr = 0, e_en = 0;
    reg  [7:0] e_d = 0;
    wire [7:0] e_crc, e_out;
    crc_parallel #(.W(8), .DW(8), .POLY(8'h07), .INIT(8'h00), .REFIN(0), .REFOUT(0), .XOROUT(8'h00))
        u_e8 (.clk(clk), .rst_n(rst_n), .clr(e_clr), .en(e_en), .data(e_d), .crc(e_crc), .crc_out(e_out));

    // ======================= 任务 =======================
    reg [7:0] msg [0:31];
    integer   mlen;

    task run_parallel;
        integer n;
        begin
            @(negedge clk); pc_clr = 1;
            for (n = 0; n < mlen; n = n + 1) begin
                @(negedge clk); pc_clr = 0; pc_en = 1; pc_d = msg[n];
            end
            @(negedge clk); pc_clr = 0; pc_en = 0;
        end
    endtask

    task run_serial;
        integer n, t;
        begin
            @(negedge clk); sc_clr = 1;
            for (n = 0; n < mlen; n = n + 1)
                for (t = 0; t < 8; t = t + 1) begin
                    @(negedge clk); sc_clr = 0; sc_en = 1;
                    s_msb = msg[n][7 - t];
                    s_lsb = msg[n][t];
                end
            @(negedge clk); sc_en = 0;
        end
    endtask

    task run_word32;                    // mlen 必须是 4 的倍数，小端拼字
        integer n;
        begin
            @(negedge clk); w_clr = 1;
            for (n = 0; n < mlen; n = n + 4) begin
                @(negedge clk); w_clr = 0; w_en = 1;
                w_d = {msg[n+3], msg[n+2], msg[n+1], msg[n]};
            end
            @(negedge clk); w_en = 0;
        end
    endtask

    task crc8_codeword(input [71:0] cw, output [7:0] rem);
        integer n;
        begin
            @(negedge clk); e_clr = 1;
            for (n = 8; n >= 0; n = n - 1) begin
                @(negedge clk); e_clr = 0; e_en = 1; e_d = cw[n*8 +: 8];
            end
            @(negedge clk); e_en = 0;
            rem = e_crc;
        end
    endtask

    // 72 bit 中随机选 w 个不同位置
    function [71:0] rand_err(input integer w);
        integer c, pos;
        begin
            rand_err = 0; c = 0;
            while (c < w) begin
                pos = $urandom % 72;
                if (!rand_err[pos]) begin rand_err[pos] = 1'b1; c = c + 1; end
            end
        end
    endfunction

    // ======================= 主流程 =======================
    reg  [71:0] cw, ev;
    reg  [7:0]  rem, c8;
    integer n_tot, n_miss, eq_err = 0, L, pos, mid;
    reg [8*9-1:0] check_str;

    initial begin
        $dumpfile("crc.vcd");
        $dumpvars(0, tb_crc.clk, tb_crc.pc_d, tb_crc.pc_en, tb_crc.p8_crc, tb_crc.p16_crc, tb_crc.p32_crc,
                     tb_crc.s_msb, tb_crc.sc_en, tb_crc.s8_crc, tb_crc.s16_crc);
        #22 rst_n = 1;

        // ---------------- 1. parity ----------------
        for (k = 0; k < 256; k = k + 1) begin
            pd = k; #1;
            ones = 0; for (i = 0; i < 8; i = i + 1) ones = ones + pd[i];
            if (pe !== ones[0] || po !== ~ones[0]) p_err = p_err + 1;
            cw_e = {pd, pe}; cw_o = {pd, po};
            // 无错
            pin_e = pe; pin_o = po; #1;
            if (ee !== 1'b0 || eo !== 1'b0) p_err = p_err + 1;
            // 1 bit 错
            for (i = 0; i < 9; i = i + 1) begin
                ecw = cw_e ^ (9'b1 << i); pd = ecw[8:1]; pin_e = ecw[0];
                ecw = cw_o ^ (9'b1 << i); pin_o = ecw[0]; #1;
                if (ee !== 1'b1 || eo !== 1'b1) p_single_miss = p_single_miss + 1;
            end
            // 2 bit 错
            for (i = 0; i < 9; i = i + 1)
                for (j = i + 1; j < 9; j = j + 1) begin
                    ecw = cw_e ^ (9'b1 << i) ^ (9'b1 << j); pd = ecw[8:1]; pin_e = ecw[0];
                    ecw = cw_o ^ (9'b1 << i) ^ (9'b1 << j); pin_o = ecw[0]; #1;
                    if (ee === 1'b1 || eo === 1'b1) p_double_det = p_double_det + 1;
                end
        end
        $display("------------------------------------------------------------------------");
        $display("parity 8b even/odd : 256 words gen errors=%0d | 1-bit errors missed %0d / %0d | 2-bit errors detected %0d / %0d",
                 p_err, p_single_miss, 256 * 9, p_double_det, 256 * 36);

        // ---------------- 2. 标准校验值 ----------------
        check_str = "123456789";
        mlen = 9;
        for (k = 0; k < 9; k = k + 1) msg[k] = check_str[(8 - k) * 8 +: 8];
        run_parallel;
        run_serial;
        $display("check \"123456789\"  : CRC-8 = 0x%02h (expect f4)  CRC-16/CCITT-FALSE = 0x%04h (expect 29b1)  CRC-32 = 0x%08h (expect cbf43926)",
                 p8_out, p16_out, p32_out);
        $display("                     serial raw == parallel raw : %0d %0d %0d",
                 s8_crc == p8_crc, s16_crc == p16_crc, s32_crc == p32_crc);
        if (p8_out !== 8'hF4 || p16_out !== 16'h29B1 || p32_out !== 32'hCBF43926) errors = errors + 1;
        if (s8_crc !== p8_crc || s16_crc !== p16_crc || s32_crc !== p32_crc)    errors = errors + 1;

        // ---------------- 3. 随机消息串并等价 ----------------
        for (k = 0; k < 200; k = k + 1) begin
            mlen = 1 + ($urandom % 16);
            for (i = 0; i < mlen; i = i + 1) msg[i] = $urandom;
            run_parallel;
            run_serial;
            if (s8_crc !== p8_crc || s16_crc !== p16_crc || s32_crc !== p32_crc) eq_err = eq_err + 1;
        end
        $display("serial vs parallel : 200 random messages (1..16 bytes) x 3 standards, mismatches=%0d", eq_err);

        // ---------------- 4. CRC-32 DW=32 ----------------
        check_str = "12345678 ";
        mlen = 8;
        for (k = 0; k < 8; k = k + 1) msg[k] = check_str[(8 - k) * 8 +: 8];
        run_parallel;
        run_word32;
        $display("CRC-32 \"12345678\"  : DW=8 0x%08h, DW=32 little-endian words 0x%08h (%0d cycles vs 2)",
                 p32_out, w_out, mlen);
        if (w_out !== p32_out) errors = errors + 1;
        for (k = 0; k < 50; k = k + 1) begin
            mlen = 4 * (1 + ($urandom % 8));
            for (i = 0; i < mlen; i = i + 1) msg[i] = $urandom;
            run_parallel;
            run_word32;
            if (w_out !== p32_out) eq_err = eq_err + 1;
        end
        $display("                     50 random messages DW=32 vs DW=8, mismatches=%0d", eq_err);

        // ---------------- 5. CRC-8 检错能力 ----------------
        for (k = 0; k < 8; k = k + 1) msg[k] = $urandom;
        // 这种"直接算法"（输入位异或进最高位）寄存器里就是 M(x)*x^8 mod G，
        // 不需要在消息后补 8 个 0；INIT = 0 时前导 0 字节不改变余数，借它复用 9 字节任务
        cw = {8'h00, msg[0], msg[1], msg[2], msg[3], msg[4], msg[5], msg[6], msg[7]};
        crc8_codeword(cw, c8);
        cw = {msg[0], msg[1], msg[2], msg[3], msg[4], msg[5], msg[6], msg[7], c8};
        crc8_codeword(cw, rem);
        $display("CRC-8 codeword     : 64-bit msg + crc 0x%02h, remainder of whole codeword = 0x%02h", c8, rem);
        if (rem !== 8'h00) errors = errors + 1;

        $display("  error pattern          patterns  undetected");
        // 1 bit
        n_tot = 0; n_miss = 0;
        for (i = 0; i < 72; i = i + 1) begin
            crc8_codeword(cw ^ (72'b1 << i), rem);
            n_tot = n_tot + 1; if (rem == 0) n_miss = n_miss + 1;
        end
        $display("  all 1-bit              %8d  %10d", n_tot, n_miss);
        if (n_miss != 0) errors = errors + 1;
        // 2 bit
        n_tot = 0; n_miss = 0;
        for (i = 0; i < 72; i = i + 1)
            for (j = i + 1; j < 72; j = j + 1) begin
                crc8_codeword(cw ^ (72'b1 << i) ^ (72'b1 << j), rem);
                n_tot = n_tot + 1; if (rem == 0) n_miss = n_miss + 1;
            end
        $display("  all 2-bit              %8d  %10d", n_tot, n_miss);
        if (n_miss != 0) errors = errors + 1;
        // 突发 L <= 8：首尾两位必错，中间任意
        n_tot = 0; n_miss = 0;
        for (L = 1; L <= 8; L = L + 1)
            for (pos = 0; pos + L <= 72; pos = pos + 1)
                for (mid = 0; mid < ((L > 2) ? (1 << (L - 2)) : 1); mid = mid + 1) begin
                    ev = 0;
                    ev[pos] = 1'b1;
                    ev[pos + L - 1] = 1'b1;
                    for (b = 0; b < L - 2; b = b + 1) ev[pos + 1 + b] = mid[b];
                    crc8_codeword(cw ^ ev, rem);
                    n_tot = n_tot + 1; if (rem == 0) n_miss = n_miss + 1;
                end
        $display("  all bursts len 1..8    %8d  %10d", n_tot, n_miss);
        if (n_miss != 0) errors = errors + 1;
        // 突发 L = 9 / 16，随机
        for (L = 9; L <= 16; L = L + 7) begin
            n_tot = 0; n_miss = 0;
            for (k = 0; k < 4000; k = k + 1) begin
                pos = $urandom % (72 - L + 1);
                ev = 0;
                ev[pos] = 1'b1; ev[pos + L - 1] = 1'b1;
                for (b = 1; b < L - 1; b = b + 1) ev[pos + b] = $urandom;
                crc8_codeword(cw ^ ev, rem);
                n_tot = n_tot + 1; if (rem == 0) n_miss = n_miss + 1;
            end
            $display("  random bursts len %2d   %8d  %10d  (%.2f%%)", L, n_tot, n_miss, 100.0 * n_miss / n_tot);
        end
        // 3 bit / 4 bit 随机
        for (L = 3; L <= 4; L = L + 1) begin
            n_tot = 0; n_miss = 0;
            for (k = 0; k < 4000; k = k + 1) begin
                crc8_codeword(cw ^ rand_err(L), rem);
                n_tot = n_tot + 1; if (rem == 0) n_miss = n_miss + 1;
            end
            $display("  random %0d-bit           %8d  %10d  (%.2f%%)", L, n_tot, n_miss, 100.0 * n_miss / n_tot);
            if (L == 3 && n_miss != 0) errors = errors + 1;     // 多项式含 (x+1) 因子 → 奇数个错全部检出
        end
        $display("------------------------------------------------------------------------");

        errors = errors + p_err + p_single_miss + p_double_det + eq_err;
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
