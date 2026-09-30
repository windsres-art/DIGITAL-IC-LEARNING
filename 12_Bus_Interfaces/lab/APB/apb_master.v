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
    // 命令口
    input                 cmd_valid,
    output                cmd_ready,
    input                 cmd_write,
    input      [AW-1:0]   cmd_addr,
    input      [DW-1:0]   cmd_wdata,
    input      [DW/8-1:0] cmd_wstrb,
    // 响应口
    output reg            rsp_valid,
    output reg [DW-1:0]   rsp_rdata,
    output reg            rsp_err,
    // APB
    output reg [AW-1:0]   paddr,
    output reg            psel,
    output reg            penable,
    output reg            pwrite,
    output reg [DW-1:0]   pwdata,
    output reg [DW/8-1:0] pstrb,
    input                 pready,
    input      [DW-1:0]   prdata,
    input                 pslverr
);
    wire done = psel & penable & pready;        // 本拍 ACCESS 完成

    // 总线空闲，或者当前传输这拍就结束，都能接新命令
    assign cmd_ready = ~psel | done;
    wire   cmd_fire  = cmd_valid & cmd_ready;

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
