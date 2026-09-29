// =============================================================================
// ALU 自检查 testbench
// -----------------------------------------------------------------------------
// 同一个 TB 跑两次：
//   RTL：   iverilog alu.v tb_alu.v
//   门级：  iverilog -DGLS build/alu_netlist.v <sky130 单元模型> tb_alu.v
// 网表里的模块名仍是 alu、端口不变，所以 TB 不需要改；门级时不传参数。
// 输出在 negedge 采样，避免和带单位延时的门级模型在 posedge 上竞争。
// =============================================================================
`timescale 1ns/1ps

module tb_alu;
    localparam W   = 16;
    localparam SHW = 4;
    localparam N_RANDOM = 2000;

    reg          clk = 1'b0;
    reg          rst_n;
    reg          in_valid;
    reg  [2:0]   op;
    reg  [W-1:0] a, b;
    wire         out_valid;
    wire [W-1:0] y;
    wire         zero;

    always #5 clk = ~clk;

`ifdef GLS
    alu dut (
`else
    alu #(.W(W)) dut (
`endif
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .op(op), .a(a), .b(b),
        .out_valid(out_valid), .y(y), .zero(zero)
    );

    // ---------------- 参考模型 ----------------
    function [W-1:0] ref_alu(input [2:0] f_op, input [W-1:0] fa, input [W-1:0] fb);
        case (f_op)
            3'd0: ref_alu = fa + fb;
            3'd1: ref_alu = fa - fb;
            3'd2: ref_alu = fa & fb;
            3'd3: ref_alu = fa | fb;
            3'd4: ref_alu = fa ^ fb;
            3'd5: ref_alu = ($signed(fa) < $signed(fb)) ? 1 : 0;
            3'd6: ref_alu = fa << fb[SHW-1:0];
            default: ref_alu = fa >> fb[SHW-1:0];
        endcase
    endfunction

    // 延迟 2 拍的期望值队列（输入寄存器 + 输出寄存器）
    reg [W-1:0] exp_q1, exp_q2;
    reg         vexp_q1, vexp_q2;
    integer     errors = 0, checked = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vexp_q1 <= 1'b0; vexp_q2 <= 1'b0;
            exp_q1  <= 0;    exp_q2  <= 0;
        end else begin
            vexp_q1 <= in_valid;
            if (in_valid) exp_q1 <= ref_alu(op, a, b);
            vexp_q2 <= vexp_q1;
            if (vexp_q1) exp_q2 <= exp_q1;
        end
    end

    always @(negedge clk) begin
        if (rst_n) begin
            if (out_valid !== vexp_q2) begin
                errors = errors + 1;
                $display("[%0t] out_valid 错误: got %b exp %b", $time, out_valid, vexp_q2);
            end else if (out_valid) begin
                checked = checked + 1;
                if (y !== exp_q2 || zero !== (exp_q2 == 0)) begin
                    errors = errors + 1;
                    if (errors <= 10)
                        $display("[%0t] 数据错误: y=%h zero=%b, 期望 y=%h zero=%b",
                                 $time, y, zero, exp_q2, exp_q2 == 0);
                end
            end
        end
    end

    // ---------------- 激励 ----------------
    task drive(input [2:0] t_op, input [W-1:0] ta, input [W-1:0] tb_, input tv);
        begin
            @(posedge clk); #1;
            op = t_op; a = ta; b = tb_; in_valid = tv;
        end
    endtask

    integer i, k;
    initial begin
        $dumpfile("alu.vcd");
        $dumpvars(0, tb_alu);
        rst_n = 1'b0; in_valid = 1'b0; op = 0; a = 0; b = 0;
        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;

        // 定向用例：溢出、有符号比较边界、移位边界、结果为 0
        for (k = 0; k < 8; k = k + 1) begin
            drive(k, 16'h7FFF, 16'h0001, 1'b1);
            drive(k, 16'h8000, 16'h0001, 1'b1);
            drive(k, 16'h8000, 16'h7FFF, 1'b1);
            drive(k, 16'hFFFF, 16'hFFFF, 1'b1);
            drive(k, 16'h1234, 16'h000F, 1'b1);
            drive(k, 16'h0000, 16'h0000, 1'b1);
        end
        // 随机用例，夹杂 in_valid=0 的空拍
        for (i = 0; i < N_RANDOM; i = i + 1)
            drive($random, $random, $random, ($random % 4) != 0);
        drive(0, 0, 0, 1'b0);
        repeat (4) @(posedge clk);

        if (errors == 0 && checked > 0)
            $display("PASS: %0d 个有效结果全部与参考模型一致", checked);
        else
            $display("FAIL: %0d 个错误（检查了 %0d 个结果）", errors, checked);
        $finish;
    end
endmodule
