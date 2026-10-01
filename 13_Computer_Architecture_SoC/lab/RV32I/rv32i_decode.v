// =============================================================================
// RV32I 译码器（纯组合）：指令 → 字段、立即数、控制信号
//   单周期核与五级流水线共用。
//   - 立即数五种格式（I/S/B/U/J）的拼接是面试手写重点：符号位永远是 instr[31]，
//     所以符号扩展不依赖格式，这是 RISC-V 编码设计的用心之处。
//   - uses_rs1 / uses_rs2 标出指令是否真的读源寄存器。流水线的冒险检测要用它，
//     否则 lui/jal 这类不读寄存器的指令会因为"字段碰巧相等"而被误停。
//   - reg_we 不考虑 rd 是否为 x0，x0 由寄存器堆和前递逻辑各自处理。
// =============================================================================
module rv32i_decode (
    input      [31:0] instr,
    output     [4:0]  rd,
    output     [4:0]  rs1,
    output     [4:0]  rs2,
    output     [2:0]  funct3,       // 访存宽度 / 分支条件
    output reg [31:0] imm,
    output reg [3:0]  alu_op,       // {funct7[5], funct3} 的编码，见 rv32i_alu.v
    output reg        alu_a_pc,     // ALU A 口选 PC（auipc）
    output reg        alu_a_zero,   // ALU A 口选 0（lui）
    output reg        alu_b_imm,    // ALU B 口选立即数
    output reg        reg_we,
    output reg        mem_re,
    output reg        mem_we,
    output reg [1:0]  wb_sel,       // 0 = ALU，1 = 访存，2 = PC+4（jal / jalr 的链接值）
    output reg        is_branch,
    output reg        is_jal,
    output reg        is_jalr,
    output reg        is_system,    // ecall / ebreak：本章用作"程序结束"
    output reg        uses_rs1,
    output reg        uses_rs2,
    output reg        illegal
);
    localparam OP_LUI    = 7'b0110111, OP_AUIPC = 7'b0010111, OP_JAL    = 7'b1101111,
               OP_JALR   = 7'b1100111, OP_BRANCH = 7'b1100011, OP_LOAD  = 7'b0000011,
               OP_STORE  = 7'b0100011, OP_IMM   = 7'b0010011, OP_REG    = 7'b0110011,
               OP_FENCE  = 7'b0001111, OP_SYSTEM = 7'b1110011;

    wire [6:0] opcode = instr[6:0];
    wire [6:0] funct7 = instr[31:25];
    assign rd     = instr[11:7];
    assign funct3 = instr[14:12];
    assign rs1    = instr[19:15];
    assign rs2    = instr[24:20];

    // 五种立即数。B / J 的最低位恒为 0，不存储在指令里，换来多一倍的跳转范围
    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'b0};
    wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    always @* begin
        imm        = imm_i;
        alu_op     = 4'b0000;               // ADD
        alu_a_pc   = 1'b0;
        alu_a_zero = 1'b0;
        alu_b_imm  = 1'b1;
        reg_we     = 1'b0;
        mem_re     = 1'b0;
        mem_we     = 1'b0;
        wb_sel     = 2'd0;
        is_branch  = 1'b0;
        is_jal     = 1'b0;
        is_jalr    = 1'b0;
        is_system  = 1'b0;
        uses_rs1   = 1'b0;
        uses_rs2   = 1'b0;
        illegal    = 1'b0;
        case (opcode)
            OP_LUI:   begin imm = imm_u; alu_a_zero = 1'b1; reg_we = 1'b1; end
            OP_AUIPC: begin imm = imm_u; alu_a_pc   = 1'b1; reg_we = 1'b1; end
            OP_JAL:   begin imm = imm_j; is_jal = 1'b1; reg_we = 1'b1; wb_sel = 2'd2; end
            OP_JALR:  begin
                // ALU 算 rs1 + imm 作为跳转目标，链接值 PC+4 走 wb_sel = 2
                is_jalr = 1'b1; reg_we = 1'b1; wb_sel = 2'd2; uses_rs1 = 1'b1;
                illegal = (funct3 != 3'b000);
            end
            OP_BRANCH: begin
                imm = imm_b; is_branch = 1'b1; alu_b_imm = 1'b0;
                uses_rs1 = 1'b1; uses_rs2 = 1'b1;
                illegal = (funct3 == 3'b010) || (funct3 == 3'b011);
            end
            OP_LOAD: begin
                mem_re = 1'b1; reg_we = 1'b1; wb_sel = 2'd1; uses_rs1 = 1'b1;
                illegal = (funct3 == 3'b011) || (funct3[2:1] == 2'b11);
            end
            OP_STORE: begin
                imm = imm_s; mem_we = 1'b1; uses_rs1 = 1'b1; uses_rs2 = 1'b1;
                illegal = (funct3[2] == 1'b1) || (funct3 == 3'b011);
            end
            OP_IMM: begin
                reg_we = 1'b1; uses_rs1 = 1'b1;
                // 只有移位指令的 instr[30] 有意义（区分 srli / srai），其它 I 型的这一位属于立即数
                alu_op = {(funct3 == 3'b101) & instr[30], funct3};
                if (funct3 == 3'b001) illegal = (funct7 != 7'b0000000);
                if (funct3 == 3'b101) illegal = (funct7 != 7'b0000000) && (funct7 != 7'b0100000);
            end
            OP_REG: begin
                reg_we = 1'b1; alu_b_imm = 1'b0; uses_rs1 = 1'b1; uses_rs2 = 1'b1;
                alu_op = {instr[30], funct3};
                illegal = !((funct7 == 7'b0000000) ||
                            (funct7 == 7'b0100000 && (funct3 == 3'b000 || funct3 == 3'b101)));
            end
            OP_FENCE:  ;                    // 单核、无 cache 一致性问题：当作 nop
            OP_SYSTEM: begin
                is_system = 1'b1;
                illegal = (instr != 32'h00000073) && (instr != 32'h00100073);
            end
            default:   illegal = 1'b1;
        endcase
    end
endmodule
