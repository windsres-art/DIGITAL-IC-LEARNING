// =============================================================================
// Gray 码 testbench（自检查）
//   1. N = 4 打印码表
//   2. N = 4 / 8 / 13 全遍历：
//        gray2bin(bin2gray(x)) == x（两种逆变换写法都查）
//        bin2gray 是双射（2^N 个输入得到 2^N 个不同的码）
//        相邻值（含 2^N-1 → 0 回绕）的 Gray 只差 1 bit
//        错误写法 b = g ^ (g >> 1) 的出错个数
//   3. Gray 计数器：随机 en，与参考模型比对；每拍 Gray 变化的 bit 数 ≤ 1；
//      两种写法逐拍一致
//   4. 非 2 的幂模数（模 10）：直接截取 0..9 时回绕翻几位；对称截取 3..12 时翻几位
// =============================================================================
`timescale 1ns / 1ps

module gray_exhaustive #(
    parameter N = 4
)(
    output reg done
);
    reg  [N-1:0] b;
    wire [N-1:0] g, b1, b2, g_next;
    reg  [N-1:0] b_next;
    bin2gray     #(.N(N)) u_b2g  (.bin(b),      .gray(g));
    gray2bin     #(.N(N)) u_g2b  (.gray(g),     .bin(b1));
    gray2bin_log #(.N(N)) u_g2bl (.gray(g),     .bin(b2));
    bin2gray     #(.N(N)) u_nxt  (.bin(b_next), .gray(g_next));

    wire [N-1:0] b_wrong = g ^ (g >> 1);

    reg  seen [0:(1<<N)-1];
    integer errors = 0, wrong = 0, dup = 0, nondist1 = 0, k;

    function integer popcount(input [N-1:0] v);
        integer j;
        begin
            popcount = 0;
            for (j = 0; j < N; j = j + 1) popcount = popcount + v[j];
        end
    endfunction

    initial begin
        done = 0;
        #100;                           // 等顶层先打印完码表
        for (k = 0; k < (1 << N); k = k + 1) seen[k] = 1'b0;
        for (k = 0; k < (1 << N); k = k + 1) begin
            b      = k;
            b_next = k + 1;             // N 位截断，最后一个自然回绕到 0
            #1;
            if (b1 !== b || b2 !== b) begin
                if (errors < 5) $display("ERROR N=%0d bin=%0d gray=%b g2b=%0d g2b_log=%0d", N, k, g, b1, b2);
                errors = errors + 1;
            end
            if (seen[g]) dup = dup + 1;
            seen[g] = 1'b1;
            if (popcount(g ^ g_next) != 1) nondist1 = nondist1 + 1;
            if (b_wrong !== b) wrong = wrong + 1;
        end
        errors = errors + dup + nondist1;
        $display("N=%2d  %5d codes | round-trip & log version ok=%0d | duplicates=%0d | adjacent!=1bit=%0d | wrong inverse g^(g>>1) mismatches=%0d",
                 N, 1 << N, (errors == 0), dup, nondist1, wrong);
        done = 1;
    end
endmodule


module tb_gray;
    wire [2:0] done;
    gray_exhaustive #(.N(4))  e4  (done[0]);
    gray_exhaustive #(.N(8))  e8  (done[1]);
    gray_exhaustive #(.N(13)) e13 (done[2]);

    // ---------------- 码表 ----------------
    reg  [3:0] tb;
    wire [3:0] tg, tback;
    bin2gray #(.N(4)) t_b2g (.bin(tb),  .gray(tg));
    gray2bin #(.N(4)) t_g2b (.gray(tg), .bin(tback));

    // ---------------- 计数器 ----------------
    localparam CN = 4;
    reg clk = 0, rst_n = 0, en = 0;
    always #5 clk = ~clk;
    wire [CN-1:0] d_bin, d_gray, p_gray;
    gray_cnt_dual #(.N(CN)) u_dual (.clk(clk), .rst_n(rst_n), .en(en), .bin(d_bin), .gray(d_gray));
    gray_cnt_pure #(.N(CN)) u_pure (.clk(clk), .rst_n(rst_n), .en(en), .gray(p_gray));

    reg  [CN-1:0] m_bin = 0, prev_gray = 0;
    integer cnt_err = 0, flips_bad = 0, wraps = 0, steps = 0, k, j, fl;
    always @(posedge clk) if (rst_n) begin
        // 上升沿之前的 en 决定这一拍是否计数（en 在下降沿改变）
        if (en) begin
            m_bin = m_bin + 1'b1;
            steps = steps + 1;
            if (m_bin == 0) wraps = wraps + 1;
        end
        #1;
        if (d_bin !== m_bin || d_gray !== (m_bin ^ (m_bin >> 1)) || p_gray !== d_gray) begin
            if (cnt_err < 5) $display("ERROR counter @%0t model=%0d bin=%0d gray=%b pure=%b", $time, m_bin, d_bin, d_gray, p_gray);
            cnt_err = cnt_err + 1;
        end
        fl = 0;
        for (j = 0; j < CN; j = j + 1) fl = fl + (d_gray[j] ^ prev_gray[j]);
        if (fl > 1) flips_bad = flips_bad + 1;
        prev_gray = d_gray;
    end

    // ---------------- 非 2 的幂模数 ----------------
    function [3:0] g4(input [3:0] v);
        g4 = v ^ (v >> 1);
    endfunction
    function integer pop4(input [3:0] v);
        pop4 = v[0] + v[1] + v[2] + v[3];
    endfunction

    integer errors, flips_direct, flips_sym, max_sym;
    initial begin
        $dumpfile("gray.vcd");
        $dumpvars(0, tb_gray.clk, tb_gray.en, tb_gray.d_bin, tb_gray.d_gray, tb_gray.p_gray);

        $display("------------------------------------------------------------");
        $display("dec  bin   gray  gray2bin");
        for (k = 0; k < 16; k = k + 1) begin
            tb = k; #1;
            $display("%3d  %b  %b  %0d", k, tb, tg, tback);
        end
        wait (&done);
        $display("------------------------------------------------------------");

        #20 rst_n = 1;
        for (k = 0; k < 2000; k = k + 1) begin
            @(negedge clk);
            en = (($urandom % 100) < 70);
        end
        @(negedge clk); en = 0;
        @(negedge clk);
        $display("gray counter N=4: %0d steps, %0d wraps | model mismatches=%0d | cycles with >1 bit flip=%0d",
                 steps, wraps, cnt_err, flips_bad);

        flips_direct = pop4(g4(9) ^ g4(0));
        max_sym = 0;
        for (k = 3; k <= 12; k = k + 1) begin
            flips_sym = pop4(g4(k) ^ g4((k == 12) ? 3 : k + 1));
            if (flips_sym > max_sym) max_sym = flips_sym;
        end
        $display("mod-10 gray: codes 0..9 wrap 9->0 flips %0d bits (%b -> %b); symmetric codes 3..12 max flips per step = %0d (12->3: %b -> %b)",
                 flips_direct, g4(9), g4(0), max_sym, g4(12), g4(3));
        $display("------------------------------------------------------------");

        errors = e4.errors + e8.errors + e13.errors + cnt_err + flips_bad;
        if (e4.wrong == 0 || e8.wrong == 0) errors = errors + 1;       // 错误写法必须被查出来
        if (steps < 1000 || wraps < 50)     errors = errors + 1;
        if (max_sym != 1)                   errors = errors + 1;
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
