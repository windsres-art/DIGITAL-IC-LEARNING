// =============================================================================
// SECDED 汉明码 testbench（自检查）
//   每种 DW 一个 ecc_harness：编码 → 注入错误 → 译码，逐项检查
//     无错：数据原样、无标志
//     1 bit 错（码字每一位都试）：纠正、err_corr = 1、syn = 错误位置
//     2 bit 错：err_uncorr = 1、不纠正
//     3 bit 错：统计被报不可纠正 / 被误纠（数据错却报"已纠正"）的比例
//   DW = 8 全遍历（256 个数据 × 所有 1/2/3 bit 错误组合）；DW = 32 / 64 随机
// =============================================================================
`timescale 1ns / 1ps

module ecc_harness #(
    parameter DW  = 8,
    parameter EXH = 0,          // 1：数据和错误组合全遍历
    parameter T   = 300         // EXH = 0 时的随机数据个数
)(
    output reg done
);
    function integer ecc_r(input integer dw);
        begin
            ecc_r = 0;
            while ((1 << ecc_r) < dw + ecc_r + 1) ecc_r = ecc_r + 1;
        end
    endfunction
    localparam R = ecc_r(DW);
    localparam N = DW + R;

    reg  [DW-1:0] d;
    reg  [N:0]    e;
    wire [N:0]    c;
    wire [DW-1:0] q;
    wire          corr, uncorr;
    wire [R-1:0]  syn;
    ecc_secded_enc #(.DW(DW)) u_enc (.data(d), .code(c));
    ecc_secded_dec #(.DW(DW)) u_dec (.code(c ^ e), .data(q), .err_corr(corr), .err_uncorr(uncorr), .syn(syn));

    integer errors = 0, n_data = 0;
    integer n1 = 0, n1_ok = 0, n2 = 0, n2_det = 0, n3 = 0, n3_det = 0, n3_mis = 0, n3_lucky = 0;
    integer it, i, j, l, nd, nb;

    task check3;
        begin
            #1;
            n3 = n3 + 1;
            if (uncorr)                    n3_det   = n3_det + 1;
            else if (corr && q !== d)      n3_mis   = n3_mis + 1;
            else if (corr && q === d)      n3_lucky = n3_lucky + 1;
            else errors = errors + 1;      // 奇数个错时 ovr = 1，必然有一个标志
        end
    endtask

    initial begin
        done = 0;
        #1;
        nd = EXH ? (1 << DW) : T;
        for (it = 0; it < nd; it = it + 1) begin
            d = EXH ? it : {$urandom, $urandom};
            n_data = n_data + 1;
            // 无错
            e = 0; #1;
            if (q !== d || corr || uncorr) errors = errors + 1;
            // 1 bit
            for (i = 0; i <= N; i = i + 1) begin
                e = 0; e[i] = 1'b1; #1;
                n1 = n1 + 1;
                if (q === d && corr && !uncorr && syn == i) n1_ok = n1_ok + 1;
                else begin
                    if (errors < 5) $display("ERROR DW=%0d single at %0d: q=%h d=%h corr=%b syn=%0d", DW, i, q, d, corr, syn);
                    errors = errors + 1;
                end
            end
            // 2 bit
            if (EXH) begin
                for (i = 0; i <= N; i = i + 1)
                    for (j = i + 1; j <= N; j = j + 1) begin
                        e = 0; e[i] = 1'b1; e[j] = 1'b1; #1;
                        n2 = n2 + 1;
                        if (uncorr && !corr) n2_det = n2_det + 1; else errors = errors + 1;
                    end
            end else begin
                for (l = 0; l < 30; l = l + 1) begin
                    i = $urandom % (N + 1);
                    j = (i + 1 + ($urandom % N)) % (N + 1);
                    e = 0; e[i] = 1'b1; e[j] = 1'b1; #1;
                    n2 = n2 + 1;
                    if (uncorr && !corr) n2_det = n2_det + 1; else errors = errors + 1;
                end
            end
            // 3 bit
            if (EXH) begin
                for (i = 0; i <= N; i = i + 1)
                    for (j = i + 1; j <= N; j = j + 1)
                        for (l = j + 1; l <= N; l = l + 1) begin
                            e = 0; e[i] = 1'b1; e[j] = 1'b1; e[l] = 1'b1;
                            check3;
                        end
            end else begin
                for (l = 0; l < 30; l = l + 1) begin
                    e = 0; nb = 0;
                    while (nb < 3) begin            // 3 个不同位置
                        i = $urandom % (N + 1);
                        if (!e[i]) begin e[i] = 1'b1; nb = nb + 1; end
                    end
                    check3;
                end
            end
        end
        $display("(%2d,%2d) R=%0d%s| %5d data | 1-bit corrected %6d/%-6d | 2-bit detected %6d/%-6d | 3-bit: flagged %5.1f%%  miscorrected %5.1f%%  lucky %4.1f%%",
                 N + 1, DW, R, EXH ? " exhaustive " : " random     ", n_data, n1_ok, n1, n2_det, n2,
                 100.0 * n3_det / n3, 100.0 * n3_mis / n3, 100.0 * n3_lucky / n3);
        done = 1;
    end
endmodule


module tb_ecc;
    wire [2:0] done;
    ecc_harness #(.DW(8),  .EXH(1))          h8  (done[0]);
    ecc_harness #(.DW(32), .EXH(0), .T(300)) h32 (done[1]);
    ecc_harness #(.DW(64), .EXH(0), .T(300)) h64 (done[2]);

    // 码字布局与一个例子（DW = 8）
    reg  [7:0]  d;
    reg  [12:0] e;
    wire [12:0] c;
    wire [7:0]  q;
    wire        corr, uncorr;
    wire [3:0]  syn;
    ecc_secded_enc #(.DW(8)) u_enc (.data(d), .code(c));
    ecc_secded_dec #(.DW(8)) u_dec (.code(c ^ e), .data(q), .err_corr(corr), .err_uncorr(uncorr), .syn(syn));

    integer errors, k;
    initial begin
        $dumpfile("ecc.vcd");
        $dumpvars(0, tb_ecc.d, tb_ecc.e, tb_ecc.c, tb_ecc.q, tb_ecc.corr, tb_ecc.uncorr, tb_ecc.syn);
        $display("------------------------------------------------------------------------");
        $display("(13,8) layout, position 12..0: d7 d6 d5 d4 p8 d3 d2 d1 p4 d0 p2 p1 p0(overall)");
        #1 d = 8'hA5; e = 0;            // 在 0 时刻之后赋值，组合 always 才会被触发
        #1;
        $display("data 0xA5 -> code %b", c);
        e = 13'b1 << 6; #1;
        $display("flip position 6  -> syn=%0d corr=%b uncorr=%b data=0x%h", syn, corr, uncorr, q);
        e = (13'b1 << 6) | (13'b1 << 11); #1;
        $display("flip 6 and 11    -> syn=%0d corr=%b uncorr=%b (6 xor 11 = %0d)", syn, corr, uncorr, 6 ^ 11);
        e = 0;
        wait (&done);
        $display("------------------------------------------------------------------------");
        errors = h8.errors + h32.errors + h64.errors;
        if (h8.n2_det != 256 * 78 || h8.n1_ok != 256 * 13) errors = errors + 1;
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
