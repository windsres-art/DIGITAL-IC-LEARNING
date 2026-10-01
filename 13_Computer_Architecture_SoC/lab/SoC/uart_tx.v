// =============================================================================
// UART 发送器（8N1），APB 从机
//   寄存器：
//     0x0 TXDATA  写：低 8 位进发送 FIFO。FIFO 满时 PREADY 拉低，直到有空位（总线反压，
//                 软件不需要先查状态）
//     0x4 STATUS  bit0 = 正在发送或 FIFO 非空，bit1 = FIFO 满
//     0x8 DIV     每个比特多少个时钟（复位值 DIV_RST）
//     0xC IE      bit0 = "全部发完"中断使能
//   帧格式：空闲为 1；起始位 0，8 个数据位（低位先发），停止位 1
//   irq = IE & 全部发完（电平），接 PLIC
//   未定义的地址：PSLVERR
// =============================================================================
module uart_tx #(
    parameter DIV_RST = 16,
    parameter FD      = 4                       // FIFO 深度（2 的幂）
)(
    input             clk,
    input             rst_n,
    input             psel,
    input             penable,
    input             pwrite,
    input      [31:0] paddr,
    input      [31:0] pwdata,
    input      [3:0]  pstrb,
    output reg [31:0] prdata,
    output            pready,
    output            pslverr,
    output reg        txd,
    output            irq
);
    localparam FW = $clog2(FD);

    reg [7:0]  fifo [0:FD-1];
    reg [FW:0] cnt;
    reg [FW-1:0] rp, wp;
    reg [15:0] div, bit_cnt;
    reg [3:0]  nbit;                            // 0 = 空闲，1 = 起始位，2–9 = 数据位，10 = 停止位
    reg [7:0]  sh;
    reg        ie;

    wire [3:0] a      = paddr[3:0];
    wire       known  = (a == 4'h0) | (a == 4'h4) | (a == 4'h8) | (a == 4'hC);
    wire       full   = (cnt == FD[FW:0]);
    wire       access = psel & penable;
    // 写 TXDATA 而 FIFO 满：插等待周期
    assign pready  = !(access && pwrite && a == 4'h0 && full);
    assign pslverr = access && !known;
    wire       push   = access && pready && pwrite && a == 4'h0 && pstrb[0];
    wire       busy   = (nbit != 4'd0) | (cnt != {(FW+1){1'b0}});
    wire       pop    = (nbit == 4'd0) && (cnt != {(FW+1){1'b0}});
    assign irq = ie & ~busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= {(FW+1){1'b0}}; rp <= {FW{1'b0}}; wp <= {FW{1'b0}};
            div <= DIV_RST[15:0]; bit_cnt <= 16'd0; nbit <= 4'd0; sh <= 8'd0; ie <= 1'b0;
            txd <= 1'b1;
        end else begin
            if (push) begin fifo[wp] <= pwdata[7:0]; wp <= wp + 1'b1; end
            cnt <= cnt + {{FW{1'b0}}, push} - {{FW{1'b0}}, pop};
            if (access && pwrite && a == 4'h8) div <= pwdata[15:0];
            if (access && pwrite && a == 4'hC) ie  <= pwdata[0];

            if (pop) begin
                sh <= fifo[rp]; rp <= rp + 1'b1;
                nbit <= 4'd1; bit_cnt <= 16'd0; txd <= 1'b0;          // 起始位
            end else if (nbit != 4'd0) begin
                if (bit_cnt == div - 16'd1) begin
                    bit_cnt <= 16'd0;
                    if (nbit == 4'd10) begin
                        nbit <= 4'd0;                                  // 停止位发完
                    end else begin
                        nbit <= nbit + 4'd1;
                        txd  <= (nbit == 4'd9) ? 1'b1 : sh[0];         // 第 9 拍之后是停止位
                        sh   <= {1'b0, sh[7:1]};
                    end
                end else begin
                    bit_cnt <= bit_cnt + 16'd1;
                end
            end
        end
    end

    always @* begin
        case (a)
            4'h4:    prdata = {30'd0, full, busy};
            4'h8:    prdata = {16'd0, div};
            4'hC:    prdata = {31'd0, ie};
            default: prdata = 32'd0;
        endcase
    end

    wire unused_ok = &{1'b0, paddr[31:4], pwdata[31:16], pstrb[3:1]};
endmodule
