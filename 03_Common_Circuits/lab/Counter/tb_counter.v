// =============================================================================
// 计数器 testbench（自检查）
//   1 counter_load (WIDTH=4, MAX=11)：随机 en/load/up，每拍与整数模型比对 cnt 和 tc
//   2 counter_bcd  (3 位)：随机 en，与十进制模型比对每一位和 co
//   3 counter_ring / counter_johnson (N=4)：检查状态序列与周期；
//     再把每一个非法状态逐个强行写进寄存器，检查下一拍回到合法状态并继续正常计数
//   对照：SELF_START=0 的 Johnson 计数器进入非法状态后一直在非法环里转
// =============================================================================
`timescale 1ns / 1ps

module tb_counter;
    localparam NCYC = 3000;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    integer errors = 0;

    // ---------------- 1 可加载可逆计数器 ----------------
    localparam W = 4, MAX = 11;
    reg          en_l = 0, load = 0, up = 1;
    reg  [W-1:0] din = 0;
    wire [W-1:0] cnt;
    wire         tc;
    counter_load #(.WIDTH(W), .MAX(MAX)) u_load (
        .clk(clk), .rst_n(rst_n), .en(en_l), .load(load), .up(up),
        .din(din), .cnt(cnt), .tc(tc));

    integer m_cnt = 0, n_tc = 0, n_load = 0;
    reg     m_tc;
    always @(posedge clk) if (rst_n) begin
        m_tc = en_l && !load && (up ? (m_cnt == MAX) : (m_cnt == 0));
        if (cnt !== m_cnt[W-1:0] || tc !== m_tc) begin
            if (errors < 10) $display("ERROR load @%0t cnt=%0d tc=%b model=%0d/%b",
                                      $time, cnt, tc, m_cnt, m_tc);
            errors = errors + 1;
        end
        if (tc) n_tc = n_tc + 1;
        if (load)      begin m_cnt = din; n_load = n_load + 1; end
        else if (en_l) m_cnt = up ? (m_cnt == MAX ? 0 : m_cnt + 1)
                                  : (m_cnt == 0 ? MAX : m_cnt - 1);
    end

    // ---------------- 2 BCD 计数器 ----------------
    localparam DIG = 3;
    reg                en_b = 0;
    wire [4*DIG-1:0]   bcd;
    wire               co;
    counter_bcd #(.DIGITS(DIG)) u_bcd (.clk(clk), .rst_n(rst_n), .en(en_b), .bcd(bcd), .co(co));

    integer m_dec = 0, n_co = 0, got;
    always @(posedge clk) if (rst_n) begin
        got = bcd[11:8] * 100 + bcd[7:4] * 10 + bcd[3:0];
        if (got !== m_dec || bcd[3:0] > 9 || bcd[7:4] > 9 || bcd[11:8] > 9
            || co !== (en_b && m_dec == 999)) begin
            if (errors < 10) $display("ERROR bcd @%0t bcd=%h model=%0d", $time, bcd, m_dec);
            errors = errors + 1;
        end
        if (co) n_co = n_co + 1;
        if (en_b) m_dec = (m_dec + 1) % 1000;
    end

    // ---------------- 3 环形 / Johnson ----------------
    localparam N = 4;
    reg          en_r = 0;
    wire [N-1:0] ring, john;
    counter_ring    #(.N(N)) u_ring (.clk(clk), .rst_n(rst_n), .en(en_r), .q(ring));
    counter_johnson #(.N(N)) u_john (.clk(clk), .rst_n(rst_n), .en(en_r), .q(john));

    // 对照：去掉自启动的 Johnson 计数器
    wire [N-1:0] john_ns;
    counter_johnson #(.N(N), .SELF_START(0)) u_john_ns (.clk(clk), .rst_n(rst_n), .en(en_r), .q(john_ns));

    function ring_legal(input [N-1:0] v);
        ring_legal = (v == 4'b0001) || (v == 4'b0010) || (v == 4'b0100) || (v == 4'b1000);
    endfunction
    function john_legal(input [N-1:0] v);
        john_legal = (v == 4'b0000) || (v == 4'b0001) || (v == 4'b0011) || (v == 4'b0111)
                  || (v == 4'b1111) || (v == 4'b1110) || (v == 4'b1100) || (v == 4'b1000);
    endfunction

    reg [N-1:0] john_seq [0:2*N-1];
    initial begin
        john_seq[0] = 4'b0000; john_seq[1] = 4'b0001; john_seq[2] = 4'b0011; john_seq[3] = 4'b0111;
        john_seq[4] = 4'b1111; john_seq[5] = 4'b1110; john_seq[6] = 4'b1100; john_seq[7] = 4'b1000;
    end

    integer k, v, n_ring_ill, n_john_ill, n_rec_err, n_ns_legal;

    // 从当前状态开始，连续 3 圈检查序列与周期
    task check_sequence;
        integer c, ri, ji, start_j;
        begin
            ri = 0;
            while (ring != (4'b0001 << ri)) ri = ri + 1;
            start_j = 0;
            while (john != john_seq[start_j]) start_j = start_j + 1;
            ji = start_j;
            for (c = 0; c < 3 * 2 * N; c = c + 1) begin
                @(negedge clk);
                ri = (ri + 1) % N;
                ji = (ji + 1) % (2 * N);
                if (ring !== (4'b0001 << ri) || john !== john_seq[ji]) begin
                    $display("ERROR seq @%0t ring=%b john=%b", $time, ring, john);
                    errors = errors + 1;
                end
            end
        end
    endtask

    // ---------------- 激励 ----------------
    initial begin
        $dumpfile("counter.vcd");
        $dumpvars(0, tb_counter);
        #22 rst_n = 1;

        // 1、2：随机激励
        for (k = 0; k < NCYC; k = k + 1) begin
            @(negedge clk);
            en_l <= ($urandom % 100) < 80;
            load <= ($urandom % 100) < 3;
            din  <= $urandom % (MAX + 1);
            if (k % 200 == 0) up <= ~up;       // 每 200 拍换方向，保证加减都覆盖回绕
            en_b <= ($urandom % 100) < 90;
        end
        @(negedge clk); en_l <= 0; load <= 0; en_b <= 0;

        // 3：正常序列
        en_r <= 1;
        @(negedge clk);
        check_sequence;

        // 3：注入每一个非法状态，检查自启动
        n_ring_ill = 0; n_john_ill = 0; n_rec_err = 0;
        for (v = 0; v < 16; v = v + 1) begin
            if (!ring_legal(v)) begin
                @(negedge clk); u_ring.q = v;             // 直接改寄存器，模拟上电随机值 / SEU
                @(negedge clk);
                if (!ring_legal(ring)) n_rec_err = n_rec_err + 1;
                n_ring_ill = n_ring_ill + 1;
            end
            if (!john_legal(v)) begin
                @(negedge clk); u_john.q = v;
                @(negedge clk);
                if (!john_legal(john)) n_rec_err = n_rec_err + 1;
                n_john_ill = n_john_ill + 1;
            end
        end
        errors = errors + n_rec_err;
        check_sequence;                                   // 恢复后能继续正常计数

        // 对照：无自启动的 Johnson 进入 0101 后，打印 16 拍的轨迹
        @(negedge clk); u_john_ns.q = 4'b0101;
        $write("no self-start johnson from 0101:");
        n_ns_legal = 0;
        for (k = 0; k < 16; k = k + 1) begin
            $write(" %b", john_ns);
            if (john_legal(john_ns)) n_ns_legal = n_ns_legal + 1;
            @(negedge clk);
        end
        $display("");
        if (n_ns_legal != 0) begin
            $display("ERROR: 对照组意外回到合法状态");
            errors = errors + 1;
        end

        $display("----------------------------------------------------------");
        $display("counter_load  mod %0d: %0d cycles, %0d loads, %0d tc pulses", MAX + 1, NCYC, n_load, n_tc);
        $display("counter_bcd   %0d digits: final=%h, co pulses=%0d (model %0d)", DIG, bcd, n_co, m_dec);
        $display("ring    N=%0d: period %0d, illegal states injected=%0d", N, N, n_ring_ill);
        $display("johnson N=%0d: period %0d, illegal states injected=%0d", N, 2 * N, n_john_ill);
        $display("illegal-state recoveries that took > 1 cycle: %0d", n_rec_err);
        $display("----------------------------------------------------------");
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
