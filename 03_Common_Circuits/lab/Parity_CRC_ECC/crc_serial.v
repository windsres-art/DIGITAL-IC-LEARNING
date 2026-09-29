// =============================================================================
// 串行 CRC：每拍 1 bit，就是一个以生成多项式为反馈的 Galois LFSR（第 3 节）
//   fb = crc 最高位 ^ 输入位；crc 左移一位，fb 为 1 时再异或 POLY
//   POLY 用"常规"表示法（省略最高次项）：CRC-8 x^8+x^2+x+1 → 8'h07
//   只做多项式除法本身；输入位序（反射）、最终异或、输出反射见 crc_parallel.v
// =============================================================================
module crc_serial #(
    parameter           W    = 8,
    parameter [W-1:0]   POLY = 8'h07,
    parameter [W-1:0]   INIT = {W{1'b0}}
)(
    input              clk,
    input              rst_n,
    input              clr,         // 新一帧开始前装入 INIT
    input              en,
    input              din,
    output reg [W-1:0] crc
);
    wire fb = crc[W-1] ^ din;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)   crc <= INIT;
        else if (clr) crc <= INIT;
        else if (en)  crc <= {crc[W-2:0], 1'b0} ^ ({W{fb}} & POLY);
    end
endmodule
