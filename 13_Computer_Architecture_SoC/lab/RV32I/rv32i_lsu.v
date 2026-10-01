// =============================================================================
// 访存对齐（纯组合）：字节 / 半字在 32 bit 数据总线上的摆放与提取
//   存储：数据复制到所有字节通道，由字节使能 wstrb 选择写哪几个字节（和 AXI 的 WSTRB 一样）
//   读取：总线返回整个字，按地址低 2 位右移，再按 lb/lh 符号扩展、lbu/lhu 零扩展
//   不支持非对齐访问：misalign 置位，由核报 trap（规范允许非对齐访问实现为异常）
// =============================================================================
module rv32i_lsu (
    input      [1:0]  addr_lo,
    input      [2:0]  funct3,       // 000 b，001 h，010 w；bit2 = 无符号（lbu / lhu）
    input      [31:0] st_data,      // rs2
    input      [31:0] ld_word,      // 存储器返回的整个字
    output reg [3:0]  wstrb,        // 存储时的字节使能（核里再与 mem_we 相与）
    output reg [31:0] wdata,
    output reg [31:0] ld_data,
    output reg        misalign
);
    // 按地址低位选出字节 / 半字（即"右移 addr_lo × 8"，只保留用得到的位）
    reg [7:0] ld_b;
    always @* begin
        case (addr_lo)
            2'd0:    ld_b = ld_word[7:0];
            2'd1:    ld_b = ld_word[15:8];
            2'd2:    ld_b = ld_word[23:16];
            default: ld_b = ld_word[31:24];
        endcase
    end
    wire [15:0] ld_h = addr_lo[1] ? ld_word[31:16] : ld_word[15:0];

    always @* begin
        case (funct3[1:0])
            2'b00: begin
                wstrb    = 4'b0001 << addr_lo;
                wdata    = {4{st_data[7:0]}};
                ld_data  = funct3[2] ? {24'b0, ld_b} : {{24{ld_b[7]}}, ld_b};
                misalign = 1'b0;
            end
            2'b01: begin
                wstrb    = addr_lo[1] ? 4'b1100 : 4'b0011;
                wdata    = {2{st_data[15:0]}};
                ld_data  = funct3[2] ? {16'b0, ld_h} : {{16{ld_h[15]}}, ld_h};
                misalign = addr_lo[0];
            end
            default: begin
                wstrb    = 4'b1111;
                wdata    = st_data;
                ld_data  = ld_word;
                misalign = (addr_lo != 2'b00);
            end
        endcase
    end
endmodule
