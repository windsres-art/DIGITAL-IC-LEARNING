// =============================================================================
// 寄存器堆（register file）：2 读 1 写，读是组合的（给地址当拍出数据）
//   RISC-V 风格：x0 恒为 0，写 x0 被忽略，读 x0 直接给 0
//   BYPASS = 1：同一拍写 rd 又读 rd 时，读口直接拿写数据（写穿）。
//     五级流水线里 WB 和 ID 同拍访问同一寄存器，要么这样旁路，要么"前半拍写后半拍读"
//   寄存器不复位（RISC-V 规定复位后通用寄存器值未定义），省面积
//   和 SRAM 的区别：多读口、组合读、全部由触发器（或专用寄存器堆宏）组成
// =============================================================================
module regfile #(
    parameter DW     = 32,
    parameter NR     = 32,
    parameter AW     = $clog2(NR),
    parameter BYPASS = 0
)(
    input           clk,
    input           we,
    input  [AW-1:0] waddr,
    input  [DW-1:0] wdata,
    input  [AW-1:0] raddr1,
    output [DW-1:0] rdata1,
    input  [AW-1:0] raddr2,
    output [DW-1:0] rdata2
);
    reg [DW-1:0] rf [0:NR-1];

    always @(posedge clk)
        if (we && waddr != {AW{1'b0}}) rf[waddr] <= wdata;

    // 不要把读口写成 assign rdata1 = rd(raddr1) 这种函数调用：连续赋值只对函数的
    // 实参敏感，函数体里读的 rf / we / wdata 变了不会重新求值，仿真出旧值
    wire byp1 = (BYPASS != 0) && we && (waddr == raddr1);
    wire byp2 = (BYPASS != 0) && we && (waddr == raddr2);

    assign rdata1 = (raddr1 == {AW{1'b0}}) ? {DW{1'b0}} : byp1 ? wdata : rf[raddr1];
    assign rdata2 = (raddr2 == {AW{1'b0}}) ? {DW{1'b0}} : byp2 ? wdata : rf[raddr2];
endmodule
