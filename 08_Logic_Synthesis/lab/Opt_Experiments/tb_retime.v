// retime_mac 自检查 TB：两个 RTL 版本与 retiming 后的门级网表共用
// 期望：输入在第 N 个上升沿被采样，第 N+3 个上升沿后 y = ((a*b) >> W) * c
// 用 -DDUT=retime_mac_manual 切换被测模块
`timescale 1ns/1ps
`ifndef DUT
`define DUT retime_mac
`endif
module tb_retime;
    localparam W = 8;
    reg            clk = 0;
    reg  [W-1:0]   a = 0, b = 0, c = 0;
    wire [2*W-1:0] y;

    always #5 clk = ~clk;

`ifdef GLS
    `DUT dut (.clk(clk), .a(a), .b(b), .c(c), .y(y));
`else
    `DUT #(.W(W)) dut (.clk(clk), .a(a), .b(b), .c(c), .y(y));
`endif

    reg  [2*W-1:0] exp_pipe [0:2];
    wire [2*W-1:0] prod = a * b;
    integer i, errors = 0, checked = 0;

    always @(posedge clk) begin
        exp_pipe[0] <= prod[2*W-1:W] * c;
        exp_pipe[1] <= exp_pipe[0];
        exp_pipe[2] <= exp_pipe[1];
    end

    initial begin
        $dumpfile("retime.vcd");
        $dumpvars(0, tb_retime);
        for (i = 0; i < 500; i = i + 1) begin
            @(negedge clk);
            // 前几拍流水线里还是 X，跳过
            if (i >= 4) begin
                checked = checked + 1;
                if (y !== exp_pipe[2]) begin
                    errors = errors + 1;
                    if (errors <= 5) $display("[%0t] y=%h 期望 %h", $time, y, exp_pipe[2]);
                end
            end
            a = $random; b = $random; c = $random;
        end
        if (errors == 0) $display("PASS: %0d 个结果正确", checked);
        else             $display("FAIL: %0d 个错误", errors);
        $finish;
    end
endmodule
