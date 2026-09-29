// =============================================================================
// 单口 RAM（single-port）：一套地址，每拍要么读要么写，同步读（地址打一拍后出数据）
//   MODE 决定"写的同时 dout 输出什么"（FPGA Block RAM 的三种写模式）：
//     0 READ_FIRST  ：输出该地址的旧值
//     1 WRITE_FIRST ：输出刚写入的新值（写穿，write-through）
//     2 NO_CHANGE   ：dout 保持上一次读出的值不变
//   存储体和 dout 都不复位：真实 SRAM 没有整体复位，带复位只能用触发器实现
//   ASIC 里大容量 RAM 用 SRAM 宏（见 sram_model.v / sram_wrap.v），这种写法适合
//   FPGA 推断 Block RAM，或小容量时综合成触发器阵列
// =============================================================================
module spram #(
    parameter DW   = 8,
    parameter AW   = 4,
    parameter MODE = 0
)(
    input               clk,
    input               en,
    input               we,
    input      [AW-1:0] addr,
    input      [DW-1:0] din,
    output reg [DW-1:0] dout
);
    reg [DW-1:0] mem [0:(1<<AW)-1];

    always @(posedge clk) begin
        if (en) begin
            if (we) mem[addr] <= din;
            if (!we)            dout <= mem[addr];
            else if (MODE == 0) dout <= mem[addr];      // 非阻塞：读到的是写之前的值
            else if (MODE == 1) dout <= din;
        end
    end
endmodule
