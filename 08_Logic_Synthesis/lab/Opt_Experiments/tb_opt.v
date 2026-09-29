// =============================================================================
// Opt_Experiments 的 RTL 自检查：先确认各电路功能正确，再去比综合结果
//   boundary_top : y 在下一拍等于 a + b
//   share_mul_1/2: 与 sel ? a*b : c*d 一致
//   dup_*        : 与“en 打一拍后作为使能”的参考模型一致
//   seq_det      : 与“最近 4 个输入 == 1011”打一拍一致
// =============================================================================
`timescale 1ns/1ps
module tb_opt;
    reg         clk = 0, rst_n = 0;
    reg  [7:0]  a, b, c, d;
    reg         sel, din, en_in;
    reg  [15:0] dd;

    wire [15:0] y_bound, y_s2, y_s1, q_nk, q_k;
    wire        hit;

    always #5 clk = ~clk;

    boundary_top u_bound (.clk(clk), .rst_n(rst_n), .a(a), .b(b), .y(y_bound));
    share_mul_2  u_s2    (.sel(sel), .a(a), .b(b), .c(c), .d(d), .y(y_s2));
    share_mul_1  u_s1    (.sel(sel), .a(a), .b(b), .c(c), .d(d), .y(y_s1));
    dup_nokeep   u_nk    (.clk(clk), .rst_n(rst_n), .en_in(en_in), .d(dd), .q(q_nk));
    dup_keep     u_k     (.clk(clk), .rst_n(rst_n), .en_in(en_in), .d(dd), .q(q_k));
    seq_det      u_fsm   (.clk(clk), .rst_n(rst_n), .din(din), .hit(hit));

    // 参考模型
    reg  [15:0] exp_bound, exp_q;
    reg         en_d;
    reg  [3:0]  hist;       // 最近 4 个输入，hist[0] 最新
    reg         exp_hit;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            exp_bound <= 0; exp_q <= 0; en_d <= 0; hist <= 0; exp_hit <= 0;
        end else begin
            exp_bound <= a + b;
            en_d      <= en_in;
            if (en_d) exp_q <= dd;
            hist      <= {hist[2:0], din};
            exp_hit   <= ({hist[2:0], din} == 4'b1011);
        end

    integer i, errors = 0, hits = 0;
    task check(input cond, input [8*16-1:0] name);
        if (!cond) begin
            errors = errors + 1;
            if (errors <= 10) $display("[%0t] %0s 不一致", $time, name);
        end
    endtask

    initial begin
        $dumpfile("opt.vcd");
        $dumpvars(0, tb_opt);
        {a, b, c, d, sel, din, en_in, dd} = 0;
        repeat (2) @(posedge clk);
        #1 rst_n = 1;
        for (i = 0; i < 3000; i = i + 1) begin
            @(negedge clk);
            check(y_bound === exp_bound, "boundary_top");
            check(y_s2 === (sel ? a * b : c * d), "share_mul_2");
            check(y_s1 === y_s2, "share_mul_1");
            check(q_nk === exp_q, "dup_nokeep");
            check(q_k  === exp_q, "dup_keep");
            check(hit  === exp_hit, "seq_det");
            if (hit) hits = hits + 1;
            {a, b, c, d} = {$random, $random};
            sel   = $random;
            din   = $random;
            en_in = $random;
            dd    = $random;
        end
        if (errors == 0) $display("PASS: 6 个电路 3000 拍全部一致（seq_det 命中 %0d 次）", hits);
        else             $display("FAIL: %0d 处不一致", errors);
        $finish;
    end
endmodule
