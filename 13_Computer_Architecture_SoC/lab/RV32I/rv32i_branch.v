// =============================================================================
// RV32I 分支比较器（纯组合）
// =============================================================================
// 分支条件：funct3 = 000 beq / 001 bne / 100 blt / 101 bge / 110 bltu / 111 bgeu
// 规律：funct3[2:1] 选比较方式，funct3[0] 取反（bne = !beq，bge = !blt）
module rv32i_branch (
    input  [31:0] a,
    input  [31:0] b,
    input  [2:0]  funct3,
    output        taken
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
