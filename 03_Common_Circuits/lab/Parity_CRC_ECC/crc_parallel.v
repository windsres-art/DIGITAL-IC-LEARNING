// =============================================================================
// 并行 CRC：每拍 DW bit
//   把串行 LFSR 的 DW 次迭代在函数里展开，综合后就是一张异或矩阵：
//   crc_next 的每一位 = 若干 crc 位和 data 位的异或（CRC 是线性的）
//   与 crc_serial.v 逐 bit 喂入的结果完全相同（testbench 验证）
//
//   完整描述一个 CRC 标准要 6 个参数（Rocksoft 模型）：
//     W、POLY、INIT、REFIN（每个字节 LSB 先进）、REFOUT（结果整体位反转）、XOROUT
//   例：CRC-32（以太网 / zip）= 32, 04C11DB7, FFFFFFFF, 1, 1, FFFFFFFF
//   DW > 8 时整个字按 LSB 先进（REFIN = 1）或 MSB 先进（REFIN = 0）：
//   相当于要求字节按小端 / 大端拼成字，拼法和协议对不上结果就错（testbench 用
//   DW = 32 小端拼字与 DW = 8 逐字节比对）
// =============================================================================
module crc_parallel #(
    parameter           W      = 32,
    parameter           DW     = 8,
    parameter [W-1:0]   POLY   = 32'h04C11DB7,
    parameter [W-1:0]   INIT   = 32'hFFFFFFFF,
    parameter           REFIN  = 1,
    parameter           REFOUT = 1,
    parameter [W-1:0]   XOROUT = 32'hFFFFFFFF
)(
    input               clk,
    input               rst_n,
    input               clr,
    input               en,
    input  [DW-1:0]     data,
    output reg [W-1:0]  crc,        // 寄存器原始值（多项式除法的余数）
    output     [W-1:0]  crc_out     // 按标准做完输出反射和最终异或后的值
);
    function [W-1:0] crc_next(input [W-1:0] c, input [DW-1:0] d);
        integer i;
        reg     fb;
        begin
            crc_next = c;
            for (i = 0; i < DW; i = i + 1) begin
                fb = crc_next[W-1] ^ ((REFIN != 0) ? d[i] : d[DW-1-i]);
                crc_next = {crc_next[W-2:0], 1'b0} ^ ({W{fb}} & POLY);
            end
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)   crc <= INIT;
        else if (clr) crc <= INIT;
        else if (en)  crc <= crc_next(crc, data);
    end

    reg [W-1:0] crc_ref;
    integer     k;
    always @(*) begin
        for (k = 0; k < W; k = k + 1)
            crc_ref[k] = (REFOUT != 0) ? crc[W-1-k] : crc[k];
    end
    assign crc_out = crc_ref ^ XOROUT;
endmodule
