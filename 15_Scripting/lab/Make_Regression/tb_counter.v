// =============================================================================
// 计数器自检查 testbench：随机激励 + 参考模型逐拍比对
// -----------------------------------------------------------------------------
// 编译期参数：W（iverilog -P tb_counter.W=16）
// 运行期参数（vvp ... +seed=3 +cycles=1000 +corner=1 +vcd=build/x.vcd）：
//   seed    随机种子，同一个种子结果完全可复现
//   cycles  随机激励的拍数
//   corner  1 = 装载值有 1/4 概率取全 1 / 全 0（corner 偏置），0 = 纯均匀随机
// 最后一行固定格式 "PASS/FAIL key=value ..."，回归脚本靠它判断结果、收集统计
// =============================================================================
`timescale 1ns/1ps

module tb_counter;
    parameter W = 8;

    reg          clk = 1'b0;
    reg          rst_n = 1'b0;
    reg          en = 1'b0;
    reg          load = 1'b0;
    reg  [W-1:0] load_val = {W{1'b0}};
    wire [W-1:0] cnt;
    wire         wrap;

    counter #(.W(W)) dut (
        .clk(clk), .rst_n(rst_n), .en(en), .load(load),
        .load_val(load_val), .cnt(cnt), .wrap(wrap)
    );

    always #5 clk = ~clk;

    integer seed = 1, seed0, cycles = 1000, corner = 0, dummy;
    reg [8*128-1:0] vcd;

    // ---------------- 参考模型 ----------------
    // 故意不照抄 RTL 的写法：用 64 bit 整数取模表示回绕，wrap = 下一个值为 0
    reg [63:0] ref_cnt;
    reg        ref_wrap;
    wire [63:0] MOD = 64'd1 << W;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_cnt  <= 64'd0;
            ref_wrap <= 1'b0;
        end else if (load) begin
            ref_cnt  <= load_val;
            ref_wrap <= 1'b0;
        end else if (en) begin
            ref_cnt  <= (ref_cnt + 1) % MOD;
            ref_wrap <= ((ref_cnt + 1) % MOD) == 0;
        end else begin
            ref_wrap <= 1'b0;
        end
    end

    // ---------------- 激励与比对 ----------------
    integer i, errors = 0, n_load = 0, n_both = 0, n_ones = 0, n_wrap = 0;
    initial begin
        dummy = $value$plusargs("seed=%d", seed);
        dummy = $value$plusargs("cycles=%d", cycles);
        dummy = $value$plusargs("corner=%d", corner);
        if (!$value$plusargs("vcd=%s", vcd)) vcd = "counter.vcd";
        seed0 = seed;   // $random 会改写 seed，先存一份用于打印
        $dumpfile(vcd);
        $dumpvars(0, tb_counter);

        repeat (3) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;

        for (i = 0; i < cycles; i = i + 1) begin
            // 在下降沿比对上一个上升沿的结果，并给出新激励，避开与 DUT 的竞争
            @(negedge clk);
            if (cnt !== ref_cnt[W-1:0] || wrap !== ref_wrap) begin
                errors = errors + 1;
                if (errors <= 3)
                    $display("  mismatch @%0t: cnt=%h wrap=%b, expect cnt=%h wrap=%b",
                             $time, cnt, wrap, ref_cnt[W-1:0], ref_wrap);
            end
            if (wrap) n_wrap = n_wrap + 1;

            en   = ({$random(seed)} % 10) < 7;
            load = ({$random(seed)} % 10) == 0;
            if (corner && ({$random(seed)} % 4) == 0)
                load_val = ({$random(seed)} % 2) ? {W{1'b1}} : {W{1'b0}};
            else
                load_val = $random(seed);
            if (load)               n_load = n_load + 1;
            if (load && en)         n_both = n_both + 1;
            if (load && en && (&load_val)) n_ones = n_ones + 1;
        end

        // 统计量相当于最简单的功能覆盖率：关键场景到底有没有被打到
        if (errors == 0)
            $display("PASS W=%0d seed=%0d cycles=%0d loads=%0d load_en=%0d load_en_ones=%0d wraps=%0d",
                     W, seed0, cycles, n_load, n_both, n_ones, n_wrap);
        else
            $display("FAIL W=%0d seed=%0d cycles=%0d errors=%0d load_en_ones=%0d wraps=%0d",
                     W, seed0, cycles, errors, n_ones, n_wrap);
        $finish;
    end

endmodule
