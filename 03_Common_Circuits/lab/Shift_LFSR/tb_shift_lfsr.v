// =============================================================================
// 移位寄存器 / 串并转换 / LFSR testbench（自检查）
//   1 shift_reg：随机 mode 与串行输入，每拍与模型比对
//   2 p2s → s2p 环回：先随机间隔送 500 个字，再背靠背送 200 个字；
//     接收端按顺序比对，并检查背靠背时每 WIDTH 拍出一个字、中间没有空拍
//   3 LFSR：多组本原多项式 × Fibonacci/Galois，测周期（应为 2^N-1）、
//     一个周期内 1 的个数（应为 2^(N-1)）、从不出现全 0；
//     N<=8 时再检查 Fibonacci 输出序列倒过来是 Galois 序列的循环移位；
//     另测一个非本原多项式作对照
// =============================================================================
`timescale 1ns / 1ps

module lfsr_case #(
    parameter           N      = 8,
    parameter [N-1:0]   TAPS   = 8'b1011_1000,
    parameter           GALOIS = 0
)(
    output reg     done,
    output integer period,
    output integer ones,
    output integer zero_seen
);
    localparam integer MAXP = (1 << N) - 1;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    wire [N-1:0] q;
    wire         out;
    lfsr #(.N(N), .TAPS(TAPS), .GALOIS(GALOIS)) u (.clk(clk), .rst_n(rst_n), .en(1'b1), .q(q), .out(out));

    reg bits [0:MAXP];                  // 一个周期的输出序列
    reg [N-1:0] seed;

    // 复位释放后 q = SEED；每个下降沿记录当前输出位，直到状态回到 SEED
    initial begin : run
        done = 0; period = 0; ones = 0; zero_seen = 0;
        #12 rst_n = 1;
        seed = q;
        forever begin
            bits[period] = out;
            ones   = ones + out;
            period = period + 1;
            @(negedge clk);
            if (q == {N{1'b0}}) zero_seen = 1;
            if (q == seed || period > MAXP) begin
                done = 1;
                disable run;
            end
        end
    end
endmodule


module tb_shift_lfsr;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    integer errors = 0;
    integer k;

    // ---------------- 1 shift_reg ----------------
    localparam W = 8;
    reg  [1:0]   mode = 0;
    reg          smsb = 0, slsb = 0;
    reg  [W-1:0] sdin = 0;
    wire [W-1:0] sq;
    reg  [W-1:0] m_q = 0;
    shift_reg #(.WIDTH(W)) u_sr (.clk(clk), .rst_n(rst_n), .mode(mode),
        .ser_msb(smsb), .ser_lsb(slsb), .din(sdin), .q(sq));

    always @(posedge clk) if (rst_n) begin
        if (sq !== m_q) begin
            if (errors < 10) $display("ERROR shift_reg @%0t q=%b model=%b", $time, sq, m_q);
            errors = errors + 1;
        end
        case (mode)
            2'b01: m_q = {smsb, m_q[W-1:1]};
            2'b10: m_q = {m_q[W-2:0], slsb};
            2'b11: m_q = sdin;
            default: ;
        endcase
    end

    // ---------------- 2 p2s -> s2p 环回 ----------------
    localparam NW_RAND = 500, NW_B2B = 200, NW = NW_RAND + NW_B2B;
    reg  [W-1:0] words [0:NW-1];
    reg  [W-1:0] pin = 0;
    reg          load = 0;
    wire         ready, ser, ser_vld;
    wire [W-1:0] pout;
    wire         pout_vld;
    p2s #(.WIDTH(W)) u_p2s (.clk(clk), .rst_n(rst_n), .pin(pin), .load(load),
        .ready(ready), .sout(ser), .sout_vld(ser_vld));
    s2p #(.WIDTH(W)) u_s2p (.clk(clk), .rst_n(rst_n), .sin(ser), .sin_vld(ser_vld),
        .pout(pout), .pout_vld(pout_vld));

    integer tx = 0, rx = 0, last_vld_t = 0, gap_min = 1 << 30, gap_max = 0;
    integer cyc = 0;
    always @(posedge clk) begin
        cyc = cyc + 1;
        if (rst_n && load && ready) tx = tx + 1;
        if (rst_n && pout_vld) begin
            if (pout !== words[rx]) begin
                if (errors < 10) $display("ERROR s2p @%0t word %0d = %h expect %h",
                                          $time, rx, pout, words[rx]);
                errors = errors + 1;
            end
            // 背靠背阶段：统计相邻两个字之间的拍数
            if (rx > NW_RAND + 1) begin
                if (cyc - last_vld_t < gap_min) gap_min = cyc - last_vld_t;
                if (cyc - last_vld_t > gap_max) gap_max = cyc - last_vld_t;
            end
            last_vld_t = cyc;
            rx = rx + 1;
        end
    end

    // ---------------- 3 LFSR ----------------
    localparam NL = 11;
    wire [NL-1:0] ld;
    integer lp [0:NL-1], lo [0:NL-1], lz [0:NL-1];
    lfsr_case #(.N(4),  .TAPS(4'b1100),              .GALOIS(0)) f4  (ld[0],  lp[0],  lo[0],  lz[0]);
    lfsr_case #(.N(4),  .TAPS(4'b1100),              .GALOIS(1)) g4  (ld[1],  lp[1],  lo[1],  lz[1]);
    lfsr_case #(.N(5),  .TAPS(5'b10100),             .GALOIS(0)) f5  (ld[2],  lp[2],  lo[2],  lz[2]);
    lfsr_case #(.N(5),  .TAPS(5'b10100),             .GALOIS(1)) g5  (ld[3],  lp[3],  lo[3],  lz[3]);
    lfsr_case #(.N(7),  .TAPS(7'b1100000),           .GALOIS(0)) f7  (ld[4],  lp[4],  lo[4],  lz[4]);
    lfsr_case #(.N(7),  .TAPS(7'b1100000),           .GALOIS(1)) g7  (ld[5],  lp[5],  lo[5],  lz[5]);
    lfsr_case #(.N(8),  .TAPS(8'b1011_1000),         .GALOIS(0)) f8  (ld[6],  lp[6],  lo[6],  lz[6]);
    lfsr_case #(.N(8),  .TAPS(8'b1011_1000),         .GALOIS(1)) g8  (ld[7],  lp[7],  lo[7],  lz[7]);
    lfsr_case #(.N(16), .TAPS(16'b1101_0000_0000_1000), .GALOIS(0)) f16 (ld[8],  lp[8],  lo[8],  lz[8]);
    lfsr_case #(.N(16), .TAPS(16'b1101_0000_0000_1000), .GALOIS(1)) g16 (ld[9],  lp[9],  lo[9],  lz[9]);
    // 对照：x^4 + x^2 + 1 = (x^2+x+1)^2，不是本原多项式
    lfsr_case #(.N(4),  .TAPS(4'b1010),              .GALOIS(0)) bad (ld[10], lp[10], lo[10], lz[10]);

    // Fibonacci 序列倒序后是否为 Galois 序列的某个循环移位
    function integer is_rev_rotation(input integer which, input integer p);
        integer s, i, ok;
        reg a, b;
        begin
            is_rev_rotation = 0;
            for (s = 0; s < p && !is_rev_rotation; s = s + 1) begin
                ok = 1;
                for (i = 0; i < p && ok; i = i + 1) begin
                    case (which)
                        4: begin a = f4.bits[p-1-i]; b = g4.bits[(i+s)%p]; end
                        5: begin a = f5.bits[p-1-i]; b = g5.bits[(i+s)%p]; end
                        7: begin a = f7.bits[p-1-i]; b = g7.bits[(i+s)%p]; end
                        default: begin a = f8.bits[p-1-i]; b = g8.bits[(i+s)%p]; end
                    endcase
                    if (a !== b) ok = 0;
                end
                if (ok) is_rev_rotation = 1;
            end
        end
    endfunction

    // ---------------- 激励 ----------------
    integer i, nbits;
    reg [8*16-1:0] name;
    initial begin
        $dumpfile("shift_lfsr.vcd");
        // 只录环回和一个 8 位 LFSR；16 位 LFSR 跑 65535 拍，全录的话 VCD 很大
        $dumpvars(1, tb_shift_lfsr);
        $dumpvars(0, u_sr, u_p2s, u_s2p, f8.u, g8.u);
        for (k = 0; k < NW; k = k + 1) words[k] = $urandom;
        #22 rst_n = 1;

        // 1 shift_reg
        for (k = 0; k < 2000; k = k + 1) begin
            @(negedge clk);
            mode <= $urandom; smsb <= $urandom; slsb <= $urandom; sdin <= $urandom;
        end

        // 2 环回：随机间隔
        while (tx < NW_RAND) begin
            @(negedge clk);
            load <= (($urandom % 100) < 30);
            pin  <= words[tx];
        end
        // 2 环回：背靠背（每拍都请求 load，由 ready 节流）
        while (tx < NW) begin
            @(negedge clk);
            load <= 1'b1;
            pin  <= words[tx];
        end
        @(negedge clk); load <= 0;
        wait (rx == NW);
        $dumpoff;                       // 之后只剩 16 位 LFSR 在跑，不必再录

        // 3 LFSR
        wait (&ld);
        $display("----------------------------------------------------------");
        $display("shift_reg: 2000 random cycles checked");
        $display("p2s->s2p : %0d words, back-to-back gap = %0d..%0d cycles (WIDTH=%0d)",
                 rx, gap_min, gap_max, W);
        if (gap_min != W || gap_max != W) begin
            $display("ERROR: 背靠背时字间隔应恰好为 WIDTH");
            errors = errors + 1;
        end
        $display("LFSR          N  period  2^N-1   ones  zero  rev-rotation");
        for (i = 0; i < NL; i = i + 1) begin
            case (i)
                0: begin name = "fib 4,3";   nbits = 4;  end
                1: begin name = "gal 4,3";   nbits = 4;  end
                2: begin name = "fib 5,3";   nbits = 5;  end
                3: begin name = "gal 5,3";   nbits = 5;  end
                4: begin name = "fib 7,6";   nbits = 7;  end
                5: begin name = "gal 7,6";   nbits = 7;  end
                6: begin name = "fib 8,6,5,4"; nbits = 8; end
                7: begin name = "gal 8,6,5,4"; nbits = 8; end
                8: begin name = "fib 16,15,13,4"; nbits = 16; end
                9: begin name = "gal 16,15,13,4"; nbits = 16; end
                default: begin name = "fib 4,2 bad"; nbits = 4; end
            endcase
            $write("%-14s %2d  %6d  %5d  %5d  %4d", name, nbits, lp[i], (1 << nbits) - 1, lo[i], lz[i]);
            if (i % 2 == 1 && nbits <= 8)
                $write("  %s", is_rev_rotation(nbits, lp[i]) ? "yes" : "NO");
            $display("");
            if (i < 10) begin
                if (lp[i] != (1 << nbits) - 1 || lo[i] != (1 << (nbits - 1)) || lz[i] != 0) begin
                    $display("ERROR: %0s 不是最大长度序列", name);
                    errors = errors + 1;
                end
                if (i % 2 == 1 && nbits <= 8 && !is_rev_rotation(nbits, lp[i])) begin
                    $display("ERROR: %0s 与 Fibonacci 序列不互为逆序", name);
                    errors = errors + 1;
                end
            end else if (lp[i] == (1 << nbits) - 1) begin
                $display("ERROR: 非本原多项式不应达到最大周期");
                errors = errors + 1;
            end
        end
        $display("----------------------------------------------------------");
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
