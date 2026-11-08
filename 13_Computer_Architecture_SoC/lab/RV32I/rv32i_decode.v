// =============================================================================
// RV32I 译码器（纯组合）：指令 → 字段、立即数、控制信号
//   单周期核、基础五级流水线、Trap / SoC 核共用。
//   - jal / branch 的 ALU 算 PC + imm，jalr 的 ALU 算 rs1 + imm。
//     分支比较器独立比较 rs1 / rs2；jal / jalr 的写回值另取 PC+4。
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
    output reg        alu_a_pc,     // ALU A 口选本条 PC（auipc / jal / branch）
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
        // 下面的“段”列出指令实际使用的功能；单周期中都在一拍内完成。
        // 五级流水线仍逐级传递指令，不访存 / 不写回只是关闭对应使能，不是跳过 MEM / WB 级。
        // 取指 = 用 PC 拿出 instr；译码 = 本模块；执行 = ALU 或比较；
        // 访存 = 读写数据存储器；写回 = 把结果写入 rd。
        //
        // 六种结构（从 instr[31] 排到 instr[0]）：
        //   R  funct7 | rs2 | rs1 | funct3 | rd | opcode
        //   I  imm[11:0] | rs1 | funct3 | rd | opcode
        //   S  imm[11:5] | rs2 | rs1 | funct3 | imm[4:0] | opcode
        //   B  imm[12|10:5] | rs2 | rs1 | funct3 | imm[4:1|11] | opcode
        //   U  imm[31:12] | rd | opcode
        //   J  imm[20|10:1|11|19:12] | rd | opcode
        case (opcode)
            // lui  Load Upper Immediate。U 型：imm[31:12] | rd | opcode
            //   rd = {imm20, 12'b0}。A 口强制为 0，ALU 做 0 + imm_u。
            //   段：取指、译码、执行、写回。不读寄存器，不访存。
            OP_LUI:   begin imm = imm_u; alu_a_zero = 1'b1; reg_we = 1'b1; end

            // auipc  Add Upper Immediate to PC。U 型：imm[31:12] | rd | opcode
            //   rd = PC + {imm20, 12'b0}。A 口选 PC，用来构造 PC 相对地址。
            //   段：取指、译码、执行、写回。不读寄存器，不访存。
            OP_AUIPC: begin imm = imm_u; alu_a_pc   = 1'b1; reg_we = 1'b1; end

            // jal  Jump and Link。J 型：imm[20|10:1|11|19:12] | rd | opcode
            //   rd = PC+4（wb_sel=2），下一 PC = PC + imm_j。imm_j 最低位恒 0，范围约 ±1 MB。
            //   ALU 算 PC+imm_j；PC+4 由独立加法路径提供，不能把目标地址写回 rd。
            //   段：取指、译码、执行、写回。不读源寄存器，不访存。
            OP_JAL: begin
                imm = imm_j; alu_a_pc = 1'b1; alu_b_imm = 1'b1; // alu_op 默认 ADD
                is_jal = 1'b1; reg_we = 1'b1; wb_sel = 2'd2;
            end

            // jalr  Jump and Link Register。I 型：imm[11:0] | rs1 | funct3 | rd | opcode
            //   例：jalr ra, 0(t0) 是间接调用；jalr x0, 0(ra) 是函数返回（ret）。
            //   rd = PC+4。下一 PC = (rs1 + imm_i) 的最低位清 0，目标由 ALU 的加法给出。
            //   funct3 必须是 000，否则 illegal。
            //   段：取指、译码、执行、写回。不访存。
            OP_JALR:  begin
                is_jalr = 1'b1; reg_we = 1'b1; wb_sel = 2'd2; uses_rs1 = 1'b1;
                illegal = (funct3 != 3'b000);
            end

            // 条件分支，都是 B 型：imm[12|10:5] | rs2 | rs1 | funct3 | imm[4:1|11] | opcode
            //   都不写 rd。比较 rs1 与 rs2，成立则下一 PC = PC+imm_b，否则 PC+4。
            //   000 beq   Branch if Equal
            //   001 bne   Branch if Not Equal
            //   100 blt   Branch if Less Than            （有符号）
            //   101 bge   Branch if Greater than or Equal（有符号）
            //   110 bltu  Branch if Less Than Unsigned
            //   111 bgeu  Branch if Greater than or Equal Unsigned
            //   010、011 没有这条指令。ALU 用 PC 和 imm_b 算目标，比较器同时比较 rs1 / rs2。
            //   因此 ALU 的 B 口选立即数，但 uses_rs1 / uses_rs2 仍都为 1，不能漏掉比较依赖。
            //   段：取指、译码、执行。不访存，不写回。
            OP_BRANCH: begin
                imm = imm_b; alu_a_pc = 1'b1; alu_b_imm = 1'b1; // alu_op 默认 ADD
                is_branch = 1'b1;
                uses_rs1 = 1'b1; uses_rs2 = 1'b1;
                illegal = (funct3 == 3'b010) || (funct3 == 3'b011);
            end

            // load，都是 I 型：imm[11:0] | rs1 | funct3 | rd | opcode
            //   地址 = rs1 + imm_i（默认就是加法、B 口为立即数），读出的数写入 rd。
            //   000 lb   Load Byte                 符号扩展
            //   001 lh   Load Halfword             符号扩展
            //   010 lw   Load Word
            //   100 lbu  Load Byte Unsigned        零扩展
            //   101 lhu  Load Halfword Unsigned    零扩展
            //   011 / 110 / 111 非法。写回来源是访存数据（wb_sel=1），不是 ALU。
            //   段：取指、译码、执行、访存、写回。五段都走，是最长的一条。
            OP_LOAD: begin
                mem_re = 1'b1; reg_we = 1'b1; wb_sel = 2'd1; uses_rs1 = 1'b1;
                illegal = (funct3 == 3'b011) || (funct3[2:1] == 2'b11);
            end

            // store，都是 S 型：imm[11:5] | rs2 | rs1 | funct3 | imm[4:0] | opcode
            //   地址 = rs1 + imm_s，把 rs2 写入存储器，不写 rd。
            //   000 sb  Store Byte       低 8 位
            //   001 sh  Store Halfword   低 16 位
            //   010 sw  Store Word       整字
            //   funct3[2]=1 或 011 非法。字节落在哪几个通道由地址低 2 位和 wstrb 决定。
            //   段：取指、译码、执行、访存。没有写回。
            OP_STORE: begin
                imm = imm_s; mem_we = 1'b1; uses_rs1 = 1'b1; uses_rs2 = 1'b1;
                illegal = (funct3[2] == 1'b1) || (funct3 == 3'b011);
            end

            // 立即数运算，都是 I 型：imm[11:0] | rs1 | funct3 | rd | opcode
            //   rd = rs1 op imm_i。移位量只用 imm[4:0]。
            //   000 addi   Add Immediate
            //   010 slti   Set Less Than Immediate            有符号小于则 rd=1
            //   011 sltiu  Set Less Than Immediate Unsigned   立即数先符号扩展，再无符号比
            //   100 xori   XOR Immediate
            //   110 ori    OR Immediate
            //   111 andi   AND Immediate
            //   001 slli   Shift Left Logical Immediate       funct7 必须全 0
            //   101 srli   Shift Right Logical Immediate      funct7 全 0，高位补 0
            //       srai   Shift Right Arithmetic Immediate   funct7=0100000，高位补符号
            //   alu_op 最高位只有 srai 才取 instr[30]。其它 I 型的这一位是立即数 bit 10，
            //   若一律当成“减法”，addi 一个负数会被做成 sub。
            //   段：取指、译码、执行、写回。不访存。
            OP_IMM: begin
                reg_we = 1'b1; uses_rs1 = 1'b1;
                alu_op = {(funct3 == 3'b101) & instr[30], funct3};
                if (funct3 == 3'b001) illegal = (funct7 != 7'b0000000);
                if (funct3 == 3'b101) illegal = (funct7 != 7'b0000000) && (funct7 != 7'b0100000);
            end

            // 寄存器运算，都是 R 型：funct7 | rs2 | rs1 | funct3 | rd | opcode
            //   rd = rs1 op rs2。B 口改选 rs2。
            //   funct7=0000000：
            //     000 add  Add                         001 sll  Shift Left Logical
            //     010 slt  Set Less Than               011 sltu Set Less Than Unsigned
            //     100 xor  Exclusive OR                101 srl  Shift Right Logical
            //     110 or   OR                          111 and  AND
            //   funct7=0100000：000 sub  Subtract，101 sra  Shift Right Arithmetic，其它非法。
            //   alu_op = {instr[30], funct3}，1000 就是 sub，1101 就是 sra。
            //   段：取指、译码、执行、写回。不访存。
            OP_REG: begin
                reg_we = 1'b1; alu_b_imm = 1'b0; uses_rs1 = 1'b1; uses_rs2 = 1'b1;
                alu_op = {instr[30], funct3};
                illegal = !((funct7 == 7'b0000000) ||
                            (funct7 == 7'b0100000 && (funct3 == 3'b000 || funct3 == 3'b101)));
            end

            // fence  Fence。I 型，但 imm[11:0] 被拆成 fm | pred | succ，不是普通立即数：
            //   fm | pred | succ | rs1 | funct3 | rd | opcode
            //   单核、没有 cache 要维护，保持上面的默认值，等于空操作，下一 PC = PC+4。
            //   段：取指、译码。不写寄存器，不访存。
            OP_FENCE:  ;

            // ecall   Environment Call       编码 0x00000073
            // ebreak  Environment Breakpoint  编码 0x00100073
            //   二者都是 I 型 SYSTEM：imm[11:0] | rs1 | funct3 | rd | opcode，字段除 imm 外为 0。
            //   本条仍正常提交，然后核停机。其它 SYSTEM（CSR 读写等）本章没有实现，
            //   illegal=1，本拍不写寄存器、不改 PC。段：取指、译码。
            OP_SYSTEM: begin
                is_system = 1'b1;
                illegal = (instr != 32'h00000073) && (instr != 32'h00100073);
            end

            // 不认识的 opcode。核 trap，本拍不写寄存器、不写存储器。
            default:   illegal = 1'b1;
        endcase
    end
endmodule
