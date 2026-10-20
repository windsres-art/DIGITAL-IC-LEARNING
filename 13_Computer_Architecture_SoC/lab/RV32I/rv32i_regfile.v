// =============================================================================
// 寄存器堆：x0–x31，每个 32 位，两读一写。x0 读出来永远是 0，写它被丢掉
//   读是组合的，本拍译码出的 rs1/rs2 马上能拿到操作数（单周期的“读寄存器”就在这一拍）。
//   写在时钟上升沿，也就是本条指令结束的那个沿。
//   BYPASS = 1（写穿透）：同一拍既写又读同一个寄存器时，读口直接给出正在写入的新值。
//     五级流水线里 WB 写回和 ID 读寄存器会撞在同一拍，没有它就要多一条前递或多停一拍。
//     教科书说的“前半拍写、后半拍读”就是这件事。单周期核把 BYPASS 设成 0：
//     同一条指令先读后写，读的是旧值，新值要到下一拍才能被下一条指令读到。
//   存储体不带复位。规范不要求 x1–x31 上电为 0，也方便以后换成寄存器堆宏。
// =============================================================================
module rv32i_regfile #(
    parameter BYPASS = 1
)(
    input         clk,
    input         we,             // 1 = 本拍沿把 wdata 写入 waddr。waddr=x0 时仍然忽略
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
