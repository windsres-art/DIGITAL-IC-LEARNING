// =============================================================================
// 无毛刺时钟切换 testbench（自检查）
//   Part A：clk0 = 10 ns，clk1 = 14.6 ns，互为异步；sel 在任意时刻变化 → clk_mux_async
//   Part B：clk0 = 10 ns，clk1 = clk0/2（同源）；sel 由 clk0 上升沿寄存器产生（Tcq 0.3 ns）→ clk_mux_sync
//   两部分都同时接一个普通 MUX（clk_mux_bad）做对照
//
// 检查项：
//   1. 输出时钟的每段高/低电平都不短于两个输入时钟中较短的半周期（否则就是毛刺）
//   2. 切换稳定后（sel 变化后 > SETTLE ns），输出必须与被选中的时钟完全一致
// =============================================================================
`timescale 1ns / 1ps

// 统计比 MIN_W 窄的高电平 / 低电平段
module width_mon #(
    parameter real MIN_W = 5.0
)(
    input clk,
    input check_on,
    output reg [31:0] n_narrow
);
    realtime t_last;
    reg      seen;
    initial begin n_narrow = 0; seen = 0; end
    always @(clk) if (check_on) begin
        if (seen && ($realtime - t_last) < MIN_W - 0.001)
            n_narrow = n_narrow + 1;
        t_last = $realtime;
        seen   = 1'b1;
    end
endmodule


module tb_clk_mux;
    localparam real SETTLE = 150.0;
    localparam integer NSW = 40;          // 每部分切换次数

    integer errors = 0;
    integer k;

    // ------------------------------------------------------------------ Part A
    reg a_clk0 = 0, a_clk1 = 0, a_sel = 0, a_rst_n = 0, a_on = 0;
    realtime a_t_sel = 0;
    integer  a_mismatch = 0;
    always #5.0 a_clk0 = ~a_clk0;
    initial begin #1.37; forever #7.3 a_clk1 = ~a_clk1; end   // 相位也错开

    wire a_out_good, a_out_bad;
    clk_mux_async u_a_good (.clk0(a_clk0), .clk1(a_clk1), .rst_n(a_rst_n), .sel(a_sel), .clk_out(a_out_good));
    clk_mux_bad   u_a_bad  (.clk0(a_clk0), .clk1(a_clk1),                  .sel(a_sel), .clk_out(a_out_bad));

    wire [31:0] a_n_good, a_n_bad;
    width_mon #(.MIN_W(5.0)) m_a_good (.clk(a_out_good), .check_on(a_on), .n_narrow(a_n_good));
    width_mon #(.MIN_W(5.0)) m_a_bad  (.clk(a_out_bad),  .check_on(a_on), .n_narrow(a_n_bad));

    // 采样点取 x.x5 ns，永远不和时钟沿重合，避免竞争
    initial begin
        #0.05;
        forever begin
            #0.1;
            if (a_on && ($realtime - a_t_sel > SETTLE) &&
                a_out_good !== (a_sel ? a_clk1 : a_clk0))
                a_mismatch = a_mismatch + 1;
        end
    end

    // ------------------------------------------------------------------ Part B
    reg b_clk0 = 0, b_clk1 = 0, b_sel = 0, b_rst_n = 0, b_on = 0;
    reg b_sel_next = 0;
    realtime b_t_sel = 0;
    integer  b_mismatch = 0;
    always #5.0 b_clk0 = ~b_clk0;
    always @(posedge b_clk0) b_clk1 <= ~b_clk1;           // 二分频，与 clk0 同源
    // sel 来自 clk0 域寄存器，带 0.3 ns 的 clk-to-q 延时
    // （零延时时 sel 与时钟沿完全重合，普通 MUX 的毛刺反而看不出来）
    always @(posedge b_clk0) begin
        if (b_sel != b_sel_next) b_t_sel = $realtime;
        b_sel <= #0.3 b_sel_next;
    end

    wire b_out_good, b_out_bad;
    clk_mux_sync u_b_good (.clk0(b_clk0), .clk1(b_clk1), .rst_n(b_rst_n), .sel(b_sel), .clk_out(b_out_good));
    clk_mux_bad  u_b_bad  (.clk0(b_clk0), .clk1(b_clk1),                  .sel(b_sel), .clk_out(b_out_bad));

    wire [31:0] b_n_good, b_n_bad;
    width_mon #(.MIN_W(5.0)) m_b_good (.clk(b_out_good), .check_on(b_on), .n_narrow(b_n_good));
    width_mon #(.MIN_W(5.0)) m_b_bad  (.clk(b_out_bad),  .check_on(b_on), .n_narrow(b_n_bad));

    initial begin
        #0.05;
        forever begin
            #0.1;
            if (b_on && ($realtime - b_t_sel > SETTLE) &&
                b_out_good !== (b_sel ? b_clk1 : b_clk0))
                b_mismatch = b_mismatch + 1;
        end
    end

    // ------------------------------------------------------------------ 激励
    initial begin
        $dumpfile("clk_mux.vcd");
        $dumpvars(0, tb_clk_mux);

        #23.1 a_rst_n = 1; b_rst_n = 1;
        #200  a_on = 1;    b_on = 1;      // 复位后先让 clk0 那一路打开

        fork
            // A：sel 在完全随机的时刻翻转
            for (k = 0; k < NSW; k = k + 1) begin
                #(60 + ($urandom % 240) + ($urandom % 1000) / 1000.0);
                a_sel   = ~a_sel;
                a_t_sel = $realtime;
            end
            // B：sel 只在 clk0 上升沿改变（通过 b_sel_next 打一拍）
            begin : part_b
                integer j;
                for (j = 0; j < NSW; j = j + 1) begin
                    repeat (6 + $urandom % 25) @(posedge b_clk0);
                    #1 b_sel_next = ~b_sel_next;   // 沿后再改，避免和寄存器同一时刻读写产生竞争
                end
            end
        join
        #(SETTLE + 50);
        a_on = 0; b_on = 0;

        $display("----------------------------------------------------------");
        $display("                        narrow_pulses  mismatch_after_settle");
        $display("A async  clk_mux_async  %8d       %8d", a_n_good, a_mismatch);
        $display("A async  clk_mux_bad    %8d            -", a_n_bad);
        $display("B sync   clk_mux_sync   %8d       %8d", b_n_good, b_mismatch);
        $display("B sync   clk_mux_bad    %8d            -", b_n_bad);
        $display("----------------------------------------------------------");

        if (a_n_good != 0 || b_n_good != 0) begin
            $display("ERROR: 无毛刺 MUX 输出了窄脉冲"); errors = errors + 1;
        end
        if (a_mismatch != 0 || b_mismatch != 0) begin
            $display("ERROR: 切换稳定后输出与所选时钟不一致"); errors = errors + 1;
        end
        if (a_n_bad == 0 || b_n_bad == 0) begin
            $display("ERROR: 普通 MUX 没有复现毛刺，演示场景不对"); errors = errors + 1;
        end

        if (errors == 0) $display("PASS");
        else             $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
