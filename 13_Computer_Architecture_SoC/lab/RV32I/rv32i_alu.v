// =============================================================================
// RV32I ALU（纯组合）
//   alu_op = {funct7[5], funct3}：直接复用指令编码，译码器几乎不用做转换。
//   移位量只取 b[4:0]（RV32I 规定），寄存器移位 sll/srl/sra 的高位被忽略。
// =============================================================================
module rv32i_alu (
    input      [31:0] a,
    input      [31:0] b,
    input      [3:0]  op,
    output reg [31:0] y
);
    always @* begin
        case (op)
            4'b0000: y = a + b;                                   // add / addi / 地址计算
            4'b1000: y = a - b;                                   // sub
            4'b0001: y = a << b[4:0];                             // sll
            4'b0010: y = {31'b0, $signed(a) < $signed(b)};        // slt
            4'b0011: y = {31'b0, a < b};                          // sltu
            4'b0100: y = a ^ b;                                   // xor
            4'b0101: y = a >> b[4:0];                             // srl
            4'b1101: y = $unsigned($signed(a) >>> b[4:0]);        // sra：>>> 只在操作数有符号时补符号位
            4'b0110: y = a | b;                                   // or
            4'b0111: y = a & b;                                   // and
            default: y = a + b;
        endcase
    end
endmodule
