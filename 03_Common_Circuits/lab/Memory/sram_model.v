// =============================================================================
// SRAM 宏的行为模型（仿真用，代替代工厂 / 编译器生成的 .v 模型）
//   模仿常见单口 SRAM 宏的接口习惯：
//     CEB  片选，低有效；WEB 写使能，低有效；BWEB 位写屏蔽，低有效（0 的位才写）
//     Q    只在读操作时更新，1 拍延迟；写操作和不选中时保持
//   具体引脚名、写时 Q 的行为、上电内容以所用宏的 datasheet 为准；
//   真实模型通常还带时序检查（setup/hold）和功耗 / 测试引脚
// =============================================================================
module sram_model #(
    parameter DW = 32,
    parameter AW = 6
)(
    input               CLK,
    input               CEB,
    input               WEB,
    input      [DW-1:0] BWEB,
    input      [AW-1:0] A,
    input      [DW-1:0] D,
    output reg [DW-1:0] Q
);
    reg [DW-1:0] mem [0:(1<<AW)-1];

    always @(posedge CLK) begin
        if (!CEB) begin
            if (!WEB) mem[A] <= (mem[A] & BWEB) | (D & ~BWEB);
            else      Q      <= mem[A];
        end
    end
endmodule
