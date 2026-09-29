// =============================================================================
// 同步复位 vs 异步复位：同样的 8 bit 寄存器，两种复位写法
// 用于 (1) 仿真对比"时钟停了能不能复位"，(2) Yosys 综合对比映射出的单元
// =============================================================================
`timescale 1ns / 1ps

// 同步复位：复位只是 D 端前面的一个条件，综合后是 普通 DFF + D 端的 AND/MUX
module reg_sync_rst #(
    parameter W = 8
)(
    input              clk,
    input              rst_n,
    input      [W-1:0] d,
    output reg [W-1:0] q
);
    always @(posedge clk) begin
        if (!rst_n) q <= {W{1'b0}};
        else        q <= d;
    end
endmodule


// 异步复位：复位接触发器的 RESET_B 引脚，综合后是 带异步复位端的 DFF
module reg_async_rst #(
    parameter W = 8
)(
    input              clk,
    input              rst_n,
    input      [W-1:0] d,
    output reg [W-1:0] q
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) q <= {W{1'b0}};
        else        q <= d;
    end
endmodule
