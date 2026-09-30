// =============================================================================
// APB 主机（桥）：把 valid/ready 命令接口转换成 APB4 读写时序
//   状态直接用 {psel, penable} 表示：
//     IDLE   psel=0 penable=0
//     SETUP  psel=1 penable=0   固定 1 拍
//     ACCESS psel=1 penable=1   停留到 pready=1
//   ACCESS 完成的那一拍如果还有命令，直接进下一个 SETUP（psel 不拉低），
//   所以背靠背传输每笔 2 + 等待拍数。
//   响应 rsp_* 是单拍脉冲，不支持反压（上层必须每拍都能收）。
// =============================================================================
module apb_master #(
    parameter AW = 12,
    parameter DW = 32
)(
    input                 clk,
    input                 rst_n,
    // 命令口：上层发一笔读或写。cmd_valid && cmd_ready 的时钟沿锁存
    input                 cmd_valid,          // 上层有一笔命令
    output                cmd_ready,          // 本拍能收下：空闲，或当前传输这拍结束
    input                 cmd_write,          // 1 = 写，0 = 读
    input      [AW-1:0]   cmd_addr,           // 字节地址。从机按字对齐，低 2 位不用
    input      [DW-1:0]   cmd_wdata,          // 写数据。读命令时忽略
    input      [DW/8-1:0] cmd_wstrb,          // 写字节使能，bit 0 对应最低字节
    // 响应口：单拍脉冲，没有 ready。上层必须每拍都能收
    output reg            rsp_valid,          // 上一拍 ACCESS 完成，只维持这一拍
    output reg [DW-1:0]   rsp_rdata,          // 读回数据。写完成时为 0
    output reg            rsp_err,            // 完成拍采到的 PSLVERR
    // APB4。{psel, penable} 就是状态：00 IDLE，10 SETUP，11 ACCESS
    output reg [AW-1:0]   paddr,              // 地址。从收下命令到传输结束保持不变
    output reg            psel,               // 1 = 选中从机
    output reg            penable,            // 0 = SETUP，1 = ACCESS
    output reg            pwrite,             // 1 = 写，0 = 读
    output reg [DW-1:0]   pwdata,             // 写数据
    output reg [DW/8-1:0] pstrb,              // 写字节使能。读传输时规范要求为 0
    input                 pready,             // 从机。ACCESS 中为 0 表示再等一拍
    input      [DW-1:0]   prdata,             // 从机读数据，完成拍采样
    input                 pslverr             // 从机错误标志，只在完成拍有效
);
    wire done = psel & penable & pready;        // 本拍是 ACCESS 的最后一拍

    // ~psel：停在 IDLE，可以接命令
    // done：完成拍就能接下一条，下一拍直接进 SETUP，psel 不拉低（背靠背）
    assign cmd_ready = ~psel | done;
    wire   cmd_fire  = cmd_valid & cmd_ready;    // 本拍沿上收下一条命令

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            psel    <= 1'b0;
            penable <= 1'b0;
        end else if (cmd_fire) begin            // IDLE/ACCESS 完成 → SETUP
            psel    <= 1'b1;
            penable <= 1'b0;
        end else if (psel & ~penable) begin     // SETUP → ACCESS
            penable <= 1'b1;
        end else if (done) begin                // ACCESS 完成且没有新命令 → IDLE
            psel    <= 1'b0;
            penable <= 1'b0;
        end
    end

    // 地址和控制只在接收命令时更新：SETUP 和整个 ACCESS（含等待）期间保持不变
    always @(posedge clk) begin
        if (cmd_fire) begin
            paddr  <= cmd_addr;
            pwrite <= cmd_write;
            pwdata <= cmd_wdata;
            pstrb  <= cmd_write ? cmd_wstrb : {(DW/8){1'b0}};   // APB4：读传输 PSTRB 必须为 0
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rsp_valid <= 1'b0;
            rsp_rdata <= {DW{1'b0}};
            rsp_err   <= 1'b0;
        end else begin
            rsp_valid <= done;
            if (done) begin
                rsp_rdata <= pwrite ? {DW{1'b0}} : prdata;
                rsp_err   <= pslverr;
            end
        end
    end
endmodule
