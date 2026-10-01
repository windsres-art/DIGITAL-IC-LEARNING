// =============================================================================
// 系统总线 → APB 桥（APB 协议见第 12 章）
//   系统总线一侧：sel 为 1 的请求保持到 ready；APB 一侧：
//     IDLE ──sel──► SETUP（PSEL=1, PENABLE=0）──► ACCESS（PENABLE=1）──PREADY──► 完成
//   完成那一拍给系统总线 ready（PRDATA / PSLVERR 同拍返回），然后回到 IDLE。
//   所以每次 APB 访问至少 2 拍；从机拉低 PREADY 可以再插等待周期。
//   PSTRB 是 APB4 的字节写使能。
// =============================================================================
module apb_bridge (
    input             clk,
    input             rst_n,
    input             sel,
    input             we,
    input      [31:0] addr,
    input      [31:0] wdata,
    input      [3:0]  wstrb,
    output     [31:0] rdata,
    output            ready,
    output            err,
    // APB 主口
    output reg        psel,
    output reg        penable,
    output reg        pwrite,
    output reg [31:0] paddr,
    output reg [31:0] pwdata,
    output reg [3:0]  pstrb,
    input      [31:0] prdata,
    input             pready,
    input             pslverr
);
    wire done = psel & penable & pready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            psel <= 1'b0; penable <= 1'b0; pwrite <= 1'b0;
            paddr <= 32'd0; pwdata <= 32'd0; pstrb <= 4'd0;
        end else if (done) begin
            psel <= 1'b0; penable <= 1'b0;
        end else if (psel) begin
            penable <= 1'b1;                    // SETUP → ACCESS；ACCESS 里等 PREADY
        end else if (sel) begin
            psel   <= 1'b1;                     // IDLE → SETUP：锁存地址和数据
            pwrite <= we;
            paddr  <= addr;
            pwdata <= wdata;
            pstrb  <= we ? wstrb : 4'd0;
        end
    end

    assign ready = done;
    assign err   = done & pslverr;
    assign rdata = prdata;
endmodule
