// =============================================================================
// 访存对齐（纯组合）。load / store 的“访存段”
//
//   数据存储器一个格子是 32 位，下标是字地址。字节地址的低 2 位不进下标，
//   核把它们单独送到 addr_lo。本模块只回答两件事：
//     写：rs2 里的字节 / 半字放到这个字的哪几个字节通道，wstrb 的哪些位为 1
//     读：从这个字的哪几个字节通道取出数据，再扩成 32 位写入 rd
//
//   小端：一个字的 bit[7:0] 是地址最低的那个字节，wstrb[0] 对应它。
//   例：地址 0x1003 落在字 0x1000 的最高字节，addr_lo = 2'b11。
//
//   本模块不看这拍是不是 load 或 store，两种结果都算出来。
//   核里 mem_we=0 时会把 wstrb 清成 0，所以运算指令不会真的写存储器。
//   非对齐（半字落在奇地址，或字的低 2 位不是 0）只把 misalign 拉高，由核 trap。
// =============================================================================
module rv32i_lsu (
    input      [1:0]  addr_lo,    // 字节地址 [1:0]。00 最低字节，11 最高字节
    input      [2:0]  funct3,     // [1:0]：00 字节，01 半字，10 字。bit2=1 表示 lbu/lhu 零扩展
    input      [31:0] st_data,    // store 要写的 rs2。sb 只用低 8 位，sh 只用低 16 位
    input      [31:0] ld_word,    // 存储器按字地址返回的整个 32 位
    output reg [3:0]  wstrb,      // 字节写使能。bit0 写 ld_word[7:0] 那一字节。核再和 mem_we 相与
    output reg [31:0] wdata,      // 已经复制到对应通道上的写数据。wstrb 为 0 的字节不会进存储器
    output reg [31:0] ld_data,    // 从 ld_word 取出并扩展后的 32 位，准备写入 rd
    output reg        misalign    // 1 = 这个宽度不该出现在这个地址上
);
    // 字节读：addr_lo 选四个通道里的一个。相当于把字右移 addr_lo*8，只留低 8 位
    //   addr_lo=00 → [7:0]，01 → [15:8]，10 → [23:16]，11 → [31:24]
    reg [7:0] ld_b;
    always @* begin
        case (addr_lo)
            2'd0:    ld_b = ld_word[7:0];
            2'd1:    ld_b = ld_word[15:8];
            2'd2:    ld_b = ld_word[23:16];
            default: ld_b = ld_word[31:24];
        endcase
    end

    // 半字只有两个合法位置。addr_lo[1]=0 取低半字 [15:0]（地址 x0、x1），
    // addr_lo[1]=1 取高半字 [31:16]（地址 x2、x3）。x1 / x3 虽能取出数，但是非对齐
    wire [15:0] ld_h = addr_lo[1] ? ld_word[31:16] : ld_word[15:0];

    always @* begin
        case (funct3[1:0])
            // sb / lb / lbu。字节在四个位置都对齐，misalign 恒为 0
            // 写：把 rs2[7:0] 复制四份，wstrb 只打开 addr_lo 指的那一字节。
            //     地址 0x1001 → wstrb=0010，只有 [15:8] 被写成 st_data[7:0]
            // 读：lbu（funct3[2]=1）高 24 位补 0；lb 用该字节的最高位做符号扩展
            2'b00: begin
                wstrb    = 4'b0001 << addr_lo;
                wdata    = {4{st_data[7:0]}};
                ld_data  = funct3[2] ? {24'b0, ld_b} : {{24{ld_b[7]}}, ld_b};
                misalign = 1'b0;
            end
            // sh / lh / lhu。半字必须对齐到偶数地址
            // 写：rs2[15:0] 复制成两份。addr_lo[1]=0 写低半（wstrb=0011），=1 写高半（1100）
            // 读：lhu 高 16 位补 0；lh 用半字最高位做符号扩展
            // misalign = addr_lo[0]：地址是 x1 或 x3 时，半字跨了两个通道的中缝，报 trap
            2'b01: begin
                wstrb    = addr_lo[1] ? 4'b1100 : 4'b0011;
                wdata    = {2{st_data[15:0]}};
                ld_data  = funct3[2] ? {16'b0, ld_h} : {{16{ld_h[15]}}, ld_h};
                misalign = addr_lo[0];
            end
            // sw / lw。四个字节一起读写，地址低 2 位必须是 00
            // 写数据就是 rs2 整字，不再复制。读数据就是存储器返回的整字，不再扩展
            // addr_lo 不是 00 则 misalign=1（字跨到了下一个字）
            default: begin
                wstrb    = 4'b1111;
                wdata    = st_data;
                ld_data  = ld_word;
                misalign = (addr_lo != 2'b00);
            end
        endcase
    end
endmodule
