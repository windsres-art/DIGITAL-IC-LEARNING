// =============================================================================
// 寄存器堆：32 × 32 bit，两读一写，x0 恒为 0
//   - 读是组合的；写在时钟上升沿。
//   - BYPASS = 1（写穿透）：同一拍写和读同一个寄存器时，读口直接给出正在写的新值。
//     五级流水线里 WB 写回和 ID 读寄存器在同一拍，没有它就要多一条前递通路或多停一拍。
//     教科书用"前半拍写、后半拍读"描述同一件事，RTL 里用这个旁路实现，不需要双沿时钟。
//   - 存储体不带复位：规范不要求 x1–x31 有复位值，也便于映射成寄存器堆宏。
// =============================================================================
module rv32i_regfile #(
    parameter BYPASS = 1
)(
    input         clk,
    input         we,
    input  [4:0]  waddr,
    input  [31:0] wdata,
    input  [4:0]  raddr1,
    output [31:0] rdata1,
    input  [4:0]  raddr2,
    output [31:0] rdata2
);
    reg [31:0] rf [0:31];

    always @(posedge clk) begin
        if (we && waddr != 5'd0) rf[waddr] <= wdata;
    end

    wire hit1 = (BYPASS != 0) && we && (waddr == raddr1);
    wire hit2 = (BYPASS != 0) && we && (waddr == raddr2);

    assign rdata1 = (raddr1 == 5'd0) ? 32'd0 : hit1 ? wdata : rf[raddr1];
    assign rdata2 = (raddr2 == 5'd0) ? 32'd0 : hit2 ? wdata : rf[raddr2];
endmodule
