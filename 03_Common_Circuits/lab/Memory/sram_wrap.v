// =============================================================================
// SRAM 包装层（wrapper）：RTL 其余部分只看到高有效的 en / we / 字节使能 be
//   在这里完成：极性转换、字节使能 → 位屏蔽展开
//   换工艺、换宏、或 FPGA 上换成 Block RAM 时只改这个文件；
//   实际项目里 BIST 多路选择、冗余修复、功耗控制引脚通常也在这一层接
// =============================================================================
module sram_wrap #(
    parameter DW = 32,
    parameter AW = 6,
    parameter NB = DW / 8
)(
    input           clk,
    input           en,
    input           we,
    input  [NB-1:0] be,
    input  [AW-1:0] addr,
    input  [DW-1:0] wdata,
    output [DW-1:0] rdata
);
    wire [DW-1:0] bit_en;
    genvar b;
    generate
        for (b = 0; b < NB; b = b + 1) begin : g_be
            assign bit_en[b*8 +: 8] = {8{be[b]}};
        end
    endgenerate

    sram_model #(.DW(DW), .AW(AW)) u_sram (
        .CLK  (clk),
        .CEB  (~en),
        .WEB  (~we),
        .BWEB (~bit_en),
        .A    (addr),
        .D    (wdata),
        .Q    (rdata)
    );
endmodule
