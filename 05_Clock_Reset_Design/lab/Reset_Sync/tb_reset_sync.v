// =============================================================================
// 复位 testbench（自检查）
//   Part 1：reset_sync（STAGES=2 和 3），arst_n 在随机时刻拉低 / 释放，脉宽随机（含 < 1 个周期）
//     检查 a. arst_n 拉低后 srst_n 立即为 0（不等时钟）
//          b. srst_n 只在 clk 上升沿释放，且恰好是 arst_n 释放后的第 STAGES 个上升沿
//             （arst_n 高电平不足 STAGES 个沿就再次拉低时，srst_n 根本不释放）
//   Part 2：时钟停振时施加复位
//     检查 c. 异步复位寄存器立即清零
//          d. 同步复位寄存器保持旧值，直到时钟恢复后的第一个上升沿才清零
// =============================================================================
`timescale 1ns / 1ps

module tb_reset_sync;
    localparam real T = 10.0;
    localparam integer NRST = 60;

    reg clk = 1'b0;
    always #(T/2) clk = ~clk;

    integer errors = 0;
    integer k;

    // ------------------------------------------------------------------ Part 1
    // 声明时初始化为 0 不会产生 negedge 事件，同步器会一直是 X；
    // 所以先为 1，再在 initial 里显式拉低一次（上电复位）
    reg arst_n = 1'b1;
    wire srst2_n, srst3_n;
    reset_sync #(.STAGES(2)) u_rs2 (.clk(clk), .arst_n(arst_n), .srst_n(srst2_n));
    reset_sync #(.STAGES(3)) u_rs3 (.clk(clk), .arst_n(arst_n), .srst_n(srst3_n));

    realtime t_clk;
    integer  edges_since_release = 0;
    integer  n_assert = 0, n_release2 = 0, n_release3 = 0;

    integer  exp_release2 = 0, exp_release3 = 0;

    always @(posedge clk) begin
        t_clk = $realtime;
        if (arst_n) begin
            edges_since_release = edges_since_release + 1;
            if (edges_since_release == 2) exp_release2 = exp_release2 + 1;
            if (edges_since_release == 3) exp_release3 = exp_release3 + 1;
        end
        // 逐拍参考模型：已释放且过了 STAGES 个沿才为 1
        #0.001;
        if (srst2_n !== (arst_n && edges_since_release >= 2) ||
            srst3_n !== (arst_n && edges_since_release >= 3)) begin
            $display("ERROR %.3f: srst_n 与参考模型不一致", $realtime);
            errors = errors + 1;
        end
    end
    always @(posedge arst_n) edges_since_release = 0;

    // a. 拉起必须立即生效
    always @(negedge arst_n) begin
        n_assert = n_assert + 1;
        #0.001;
        if (srst2_n !== 1'b0 || srst3_n !== 1'b0) begin
            $display("ERROR %.3f: arst_n 拉低后 srst_n 没有立即有效", $realtime);
            errors = errors + 1;
        end
    end

    // b. 释放必须与时钟沿对齐，且延迟 STAGES 个沿
    always @(posedge srst2_n) if ($realtime > 1) begin
        n_release2 = n_release2 + 1;
        if ($realtime != t_clk || edges_since_release != 2) begin
            $display("ERROR %.3f: STAGES=2 释放不对齐 (edges=%0d)", $realtime, edges_since_release);
            errors = errors + 1;
        end
    end
    always @(posedge srst3_n) if ($realtime > 1) begin
        n_release3 = n_release3 + 1;
        if ($realtime != t_clk || edges_since_release != 3) begin
            $display("ERROR %.3f: STAGES=3 释放不对齐 (edges=%0d)", $realtime, edges_since_release);
            errors = errors + 1;
        end
    end

    // 等一段随机时间，并保证不正好落在时钟沿上（零延时仿真里那会变成竞争）
    task rand_wait(input integer max_ns);
        real phase;
        begin
            #(($urandom % max_ns) + ($urandom % 1000) / 1000.0 + 0.1);
            phase = $realtime - (T/2) * $floor($realtime / (T/2));
            if (phase < 0.1 || phase > T/2 - 0.1) #0.3;
        end
    endtask

    // ------------------------------------------------------------------ Part 2
    reg        run = 1'b1;
    wire       clk_g = clk & run;          // TB 里模拟"时钟停振"，不是设计里的门控
    reg        rst_n = 1'b1;
    reg  [7:0] d = 8'h00;
    wire [7:0] q_sync, q_async;
    reg_sync_rst  u_srst (.clk(clk_g), .rst_n(rst_n), .d(d), .q(q_sync));
    reg_async_rst u_arst (.clk(clk_g), .rst_n(rst_n), .d(d), .q(q_async));

    initial begin
        $dumpfile("reset_sync.vcd");
        $dumpvars(0, tb_reset_sync);

        // ---------------- Part 1 ----------------
        #0.5 arst_n = 1'b0;
        #2.8 arst_n = 1'b1;
        for (k = 0; k < NRST; k = k + 1) begin
            rand_wait(80);
            arst_n = 1'b0;
            rand_wait((k % 3 == 0) ? 3 : 40);    // 每 3 次有一次复位脉宽 < 1 个周期
            arst_n = 1'b1;
        end
        rand_wait(60);

        $display("----------------------------------------------------------");
        $display("Part 1  asserts=%0d  releases STAGES=2: %0d (expect %0d)  STAGES=3: %0d (expect %0d)",
                 n_assert, n_release2, exp_release2, n_release3, exp_release3);
        if (n_release2 != exp_release2 || n_release3 != exp_release3) begin
            $display("ERROR: 释放次数不对");
            errors = errors + 1;
        end

        // ---------------- Part 2 ----------------
        rst_n = 1'b0; @(posedge clk); #1 rst_n = 1'b1;
        d = 8'hA5;
        repeat (2) @(posedge clk);
        @(negedge clk) run = 1'b0;               // 在低电平时停振
        #20 rst_n = 1'b0;
        #1;
        $display("Part 2  clock stopped, rst_n=0 : q_async=%h  q_sync=%h", q_async, q_sync);
        if (q_async !== 8'h00) begin
            $display("ERROR: 异步复位没有在无时钟时生效"); errors = errors + 1;
        end
        if (q_sync !== 8'hA5) begin
            $display("ERROR: 同步复位不应在无时钟时生效"); errors = errors + 1;
        end
        #30 @(negedge clk) run = 1'b1;          // 恢复时钟
        @(posedge clk_g); #1;
        $display("Part 2  first edge after restart : q_async=%h  q_sync=%h", q_async, q_sync);
        if (q_sync !== 8'h00) begin
            $display("ERROR: 同步复位在时钟恢复后仍未生效"); errors = errors + 1;
        end
        rst_n = 1'b1;
        $display("----------------------------------------------------------");

        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
