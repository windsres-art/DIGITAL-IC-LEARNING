// =============================================================================
// 状态机与序列检测 testbench（自检查）
//   1 定向："1101101" 在重叠 / 不重叠下分别检测到几次
//   2 随机 5000 bit（1 的概率 60%），参考模型用比特历史直接比对：
//       重叠：最近 4 位 == 1101
//       不重叠：最近 4 位 == 1101 且距上次匹配 >= 4 位
//     Mealy 与移位寄存器实现当拍比对，Moore 晚 1 拍比对
//   3 序列 0010：带 fill 计数的正常，去掉 fill 的在复位后出现假匹配（演示）
//   4 售货机：随机投币，与金额模型比对 dispense / change，并核对总账
// =============================================================================
`timescale 1ns / 1ps

module tb_fsm;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    integer errors = 0, k;

    reg din = 0;
    wire [5:0] d;           // mealy_ov mealy_nov moore_ov moore_nov shift_ov shift_nov
    seq_fsm_1101 #(.MEALY(1), .OVERLAP(1)) u_mo  (.clk(clk), .rst_n(rst_n), .din(din), .dout(d[0]));
    seq_fsm_1101 #(.MEALY(1), .OVERLAP(0)) u_mn  (.clk(clk), .rst_n(rst_n), .din(din), .dout(d[1]));
    seq_fsm_1101 #(.MEALY(0), .OVERLAP(1)) u_oo  (.clk(clk), .rst_n(rst_n), .din(din), .dout(d[2]));
    seq_fsm_1101 #(.MEALY(0), .OVERLAP(0)) u_on  (.clk(clk), .rst_n(rst_n), .din(din), .dout(d[3]));
    seq_detect_shift #(.LEN(4), .PATTERN(4'b1101), .OVERLAP(1)) u_so (.clk(clk), .rst_n(rst_n), .din(din), .dout(d[4]));
    seq_detect_shift #(.LEN(4), .PATTERN(4'b1101), .OVERLAP(0)) u_sn (.clk(clk), .rst_n(rst_n), .din(din), .dout(d[5]));

    wire z_ok, z_bad;
    seq_detect_shift #(.LEN(4), .PATTERN(4'b0010), .USE_FILL(1)) u_z1 (.clk(clk), .rst_n(rst_n), .din(din), .dout(z_ok));
    seq_detect_shift #(.LEN(4), .PATTERN(4'b0010), .USE_FILL(0)) u_z0 (.clk(clk), .rst_n(rst_n), .din(din), .dout(z_bad));

    // ---------------- 参考模型（在上升沿用本拍 din 计算） ----------------
    reg     [3:0] hist;                 // 最近 4 位（含本拍）
    integer nbits, last_ov, last_nov;
    reg     m_ov, m_nov, m_z, p_ov = 0, p_nov = 0;
    integer cnt [0:5], n_ov, n_nov, n_z_ok, n_z_bad, n_z_false, ci;
    reg     chk = 0;

    task model_reset;
        integer j;
        begin
            hist = 0; nbits = 0; last_ov = -100; last_nov = -100; p_ov = 0; p_nov = 0;
            n_ov = 0; n_nov = 0; n_z_ok = 0; n_z_bad = 0; n_z_false = 0;
            for (j = 0; j < 6; j = j + 1) cnt[j] = 0;
        end
    endtask

    always @(posedge clk) if (rst_n && chk) begin
        hist  = {hist[2:0], din};
        nbits = nbits + 1;
        m_ov  = (nbits >= 4) && (hist == 4'b1101);
        m_nov = m_ov && (nbits - last_nov >= 4);
        m_z   = (nbits >= 4) && (hist == 4'b0010);
        if (m_ov)  begin last_ov = nbits; n_ov = n_ov + 1; end
        if (m_nov) begin last_nov = nbits; n_nov = n_nov + 1; end

        if (d[0] !== m_ov || d[4] !== m_ov || d[1] !== m_nov || d[5] !== m_nov
            || d[2] !== p_ov || d[3] !== p_nov || z_ok !== m_z) begin
            if (errors < 10) $display("ERROR @%0t din=%b dout=%b model ov=%b nov=%b (moore prev %b %b)",
                                      $time, din, d, m_ov, m_nov, p_ov, p_nov);
            errors = errors + 1;
        end
        for (ci = 0; ci < 6; ci = ci + 1) cnt[ci] = cnt[ci] + d[ci];
        n_z_ok  = n_z_ok + z_ok;
        n_z_bad = n_z_bad + z_bad;
        if (z_bad && !m_z) n_z_false = n_z_false + 1;
        p_ov = m_ov; p_nov = m_nov;
    end

    // ---------------- 售货机 ----------------
    reg  coin5 = 0, coin10 = 0;
    wire dispense, change;
    vending u_vm (.clk(clk), .rst_n(rst_n), .coin5(coin5), .coin10(coin10),
                  .dispense(dispense), .change(change));

    integer amount = 0, paid = 0, n_disp = 0, n_chg = 0;
    reg     e_disp = 0, e_chg = 0;
    always @(posedge clk) if (rst_n) begin
        // 寄存输出：本拍看到的是上一拍投币的结果
        if (dispense !== e_disp || change !== e_chg) begin
            if (errors < 10) $display("ERROR vending @%0t disp=%b chg=%b expect %b %b",
                                      $time, dispense, change, e_disp, e_chg);
            errors = errors + 1;
        end
        n_disp = n_disp + dispense;
        n_chg  = n_chg + change;
        e_disp = 0; e_chg = 0;
        if (coin5)  begin amount = amount + 5;  paid = paid + 5;  end
        if (coin10) begin amount = amount + 10; paid = paid + 10; end
        if (amount >= 15) begin
            e_disp = 1;
            e_chg  = (amount == 20);
            amount = 0;
        end
    end

    // ---------------- 激励 ----------------
    task send_bits(input [31:0] bits, input integer n);
        integer j;
        begin
            for (j = n - 1; j >= 0; j = j - 1) begin
                @(negedge clk); din = bits[j];
            end
        end
    endtask

    task do_reset;
        begin
            @(negedge clk); rst_n = 0; chk = 0; din = 0;
            @(negedge clk); rst_n = 1; model_reset; chk = 1;
        end
    endtask

    integer dir_ov [0:5];
    integer j2;
    initial begin
        $dumpfile("fsm.vcd");
        $dumpvars(0, tb_fsm);
        model_reset;
        #22 rst_n = 1; chk = 1;

        // 1 定向 1101101，后面补 0 让 Moore 的输出出来
        send_bits(32'b1101101_00, 9);
        @(negedge clk);
        for (j2 = 0; j2 < 6; j2 = j2 + 1) dir_ov[j2] = cnt[j2];
        $display("directed 1101101: mealy ov=%0d nov=%0d | moore ov=%0d nov=%0d | shift ov=%0d nov=%0d",
                 dir_ov[0], dir_ov[1], dir_ov[2], dir_ov[3], dir_ov[4], dir_ov[5]);
        if (dir_ov[0] != 2 || dir_ov[1] != 1 || dir_ov[2] != 2 || dir_ov[3] != 1
            || dir_ov[4] != 2 || dir_ov[5] != 1) begin
            $display("ERROR: 定向序列计数不对"); errors = errors + 1;
        end

        // 2、3 随机：复位后先送 "10"，让去掉 fill 的 0010 检测器在只收到 2 位时假匹配
        do_reset;
        send_bits(32'b10, 2);
        for (k = 0; k < 5000; k = k + 1) begin
            @(negedge clk);
            din = ($urandom % 100) < 60;
            if ($urandom % 100 < 60) begin
                coin5  = ($urandom % 2);
                coin10 = !coin5;
            end else begin
                coin5 = 0; coin10 = 0;
            end
        end
        @(negedge clk); coin5 = 0; coin10 = 0; din = 0;
        repeat (2) @(negedge clk);

        $display("----------------------------------------------------------");
        $display("random 5000 bits: model ov=%0d nov=%0d", n_ov, n_nov);
        $display("  mealy  ov=%0d nov=%0d | moore ov=%0d nov=%0d | shift ov=%0d nov=%0d",
                 cnt[0], cnt[1], cnt[2], cnt[3], cnt[4], cnt[5]);
        $display("pattern 0010: with fill=%0d  without fill=%0d  (false matches=%0d)",
                 n_z_ok, n_z_bad, n_z_false);
        $display("vending: paid=%0d  dispensed=%0d  change=%0d  left in machine=%0d",
                 paid, n_disp, n_chg, amount);
        $display("----------------------------------------------------------");
        if (n_z_false == 0) begin
            $display("ERROR: 没有复现去掉 fill 后的假匹配"); errors = errors + 1;
        end
        if (paid != 15 * n_disp + 5 * n_chg + amount) begin
            $display("ERROR: 售货机账不平"); errors = errors + 1;
        end
        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
