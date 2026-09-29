// =============================================================================
// 简单双口 RAM（simple dual-port）：一个写口 + 一个读口，同一时钟，同步读
//   同时读写同一地址（冲突 / collision）时读口输出什么：
//     BYPASS = 0：旧值（存储阵列的自然行为，写在时钟沿之后才生效）
//     BYPASS = 1：新值，用一个比较器 + MUX 把写数据直接旁路到读口
//   同步 FIFO 的存储体就是这种 RAM（第 1 节）；异步 FIFO 把读写口放在两个时钟上
// =============================================================================
module sdpram #(
    parameter DW     = 8,
    parameter AW     = 4,
    parameter BYPASS = 0
)(
    input               clk,
    input               we,
    input      [AW-1:0] waddr,
    input      [DW-1:0] wdata,
    input               re,
    input      [AW-1:0] raddr,
    output reg [DW-1:0] rdata
);
    reg [DW-1:0] mem [0:(1<<AW)-1];

    always @(posedge clk)
        if (we) mem[waddr] <= wdata;

    always @(posedge clk) begin
        if (re) begin
            if (BYPASS != 0 && we && waddr == raddr) rdata <= wdata;
            else                                     rdata <= mem[raddr];
        end
    end
endmodule
