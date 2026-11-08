// =============================================================================
// RV32I 分支比较器（纯组合）。只服务 beq/bne/blt/bge/bltu/bgeu
//   funct3[2:1] 选比较方式，funct3[0] 把结果取反：
//     00 beq  → 再异或 bit0 变成 bne
//     10 blt  → 再异或 bit0 变成 bge
//     11 bltu → 再异或 bit0 变成 bgeu
//   比较为真时 taken=1，核选用 ALU 算出的 PC+imm；否则走 PC+4。
//   本模块的 a / b 是 rs1 / rs2（流水线中先前递），独立于 ALU 的 PC / imm 输入。
//   分支指令不写寄存器，也不访问数据存储器；流水线中仍会经过后续级。
// =============================================================================
module rv32i_branch (
    input  [31:0] a,          // rs1
    input  [31:0] b,          // rs2
    input  [2:0]  funct3,
    output        taken       // 1 = 条件成立，要跳
);
    reg cond;
    always @* begin
        case (funct3[2:1])
            2'b00:   cond = (a == b);
            2'b10:   cond = ($signed(a) < $signed(b));
            2'b11:   cond = (a < b);
            default: cond = 1'b0;           // 010 / 011 是非法编码，译码器已报 illegal
        endcase
    end
    assign taken = cond ^ funct3[0];
endmodule
