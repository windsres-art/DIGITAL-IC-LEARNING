// =============================================================================
// 单通道 DMA：内存 → 内存按字搬运，支持描述符链（scatter-gather）
//   寄存器（req 为 1 的那一拍完成访问，整字）：
//     0x00 CTRL    bit0 START（写 1 启动，忙时忽略）  bit1 IE（完成 / 出错时中断）  bit2 SG（描述符模式）
//     0x04 STATUS  bit0 BUSY（只读）  bit1 DONE（写 1 清）  bit2 ERR（写 1 清）
//     0x08 SRC     0x0C DST     0x10 LEN（字节，4 的倍数，0 合法）
//     0x14 DESC    SG 模式下第一个描述符的地址
//     0x18 COUNT   本次启动以来搬了多少个字（只读）
//     0x1C ERRADDR 出错的总线地址（只读）
//   描述符（内存中 4 个字，16 B 对齐不是必须的，但要字对齐）：
//     +0 src  +4 dst  +8 len  +12 next（0 = 最后一个）
//   主口：与核的数据口同一种握手——请求保持到 ready，err 与 ready 同拍有效
//   出错（总线 err、地址或长度不是 4 的倍数）：停止、置 ERR、记下地址，已经搬完的字保留
//   irq = IE & (DONE | ERR)，电平；软件写 1 清 DONE / ERR 后撤销
// =============================================================================
module dma (
    input             clk,
    input             rst_n,
    // 寄存器口
    input             req,
    input             we,
    input      [4:0]  addr,
    input      [31:0] wdata,
    output reg [31:0] rdata,
    // 主口
    output reg [31:0] m_addr,
    output            m_re,
    output     [3:0]  m_wstrb,
    output reg [31:0] m_wdata,
    input      [31:0] m_rdata,
    input             m_ready,
    input             m_err,
    output            irq
);
    localparam [2:0] S_IDLE = 3'd0, S_DESC = 3'd1, S_CHECK = 3'd2, S_RD = 3'd3, S_WR = 3'd4,
                     S_NEXT = 3'd5;

    reg [2:0]  state;
    reg        ie, sg, done, err;
    reg [31:0] src, dst, len, desc, next, count, err_addr;
    reg [1:0]  dk;                              // 正在读描述符的第几个字

    wire busy  = (state != S_IDLE);
    wire start = req && we && addr == 5'h00 && wdata[0] && !busy;

    assign m_re    = (state == S_DESC) || (state == S_RD);
    assign m_wstrb = (state == S_WR) ? 4'hF : 4'h0;
    assign irq     = ie & (done | err);

    always @* begin
        case (state)
            S_DESC:  m_addr = desc + {28'd0, dk, 2'b00};
            S_WR:    m_addr = dst;
            default: m_addr = src;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            ie <= 1'b0; sg <= 1'b0; done <= 1'b0; err <= 1'b0;
            src <= 32'd0; dst <= 32'd0; len <= 32'd0; desc <= 32'd0; next <= 32'd0;
            count <= 32'd0; err_addr <= 32'd0; dk <= 2'd0; m_wdata <= 32'd0;
        end else begin
            // 寄存器写（忙时不允许改搬运参数）
            if (req && we) begin
                case (addr)
                    5'h00: begin ie <= wdata[1]; if (!busy) sg <= wdata[2]; end
                    5'h04: begin if (wdata[1]) done <= 1'b0; if (wdata[2]) err <= 1'b0; end
                    5'h08: if (!busy) src  <= wdata;
                    5'h0C: if (!busy) dst  <= wdata;
                    5'h10: if (!busy) len  <= wdata;
                    5'h14: if (!busy) desc <= wdata;
                    default: ;
                endcase
            end

            case (state)
                S_IDLE: if (start) begin
                    done  <= 1'b0;
                    err   <= 1'b0;
                    count <= 32'd0;
                    next  <= 32'd0;
                    dk    <= 2'd0;
                    if (wdata[2]) begin
                        if (desc[1:0] != 2'b00) begin err <= 1'b1; err_addr <= desc; end
                        else state <= S_DESC;
                    end else begin
                        state <= S_CHECK;
                    end
                end
                S_DESC: if (m_ready) begin
                    if (m_err) begin
                        err <= 1'b1; err_addr <= m_addr; state <= S_IDLE;
                    end else begin
                        case (dk)
                            2'd0: src  <= m_rdata;
                            2'd1: dst  <= m_rdata;
                            2'd2: len  <= m_rdata;
                            default: next <= m_rdata;
                        endcase
                        dk <= dk + 2'd1;
                        if (dk == 2'd3) state <= S_CHECK;
                    end
                end
                S_CHECK: begin
                    if ((src[1:0] | dst[1:0] | len[1:0]) != 2'b00) begin
                        err <= 1'b1;
                        err_addr <= (src[1:0] != 2'b00) ? src : (dst[1:0] != 2'b00) ? dst : len;
                        state <= S_IDLE;
                    end else if (len == 32'd0) begin
                        state <= S_NEXT;
                    end else begin
                        state <= S_RD;
                    end
                end
                S_RD: if (m_ready) begin
                    if (m_err) begin err <= 1'b1; err_addr <= m_addr; state <= S_IDLE; end
                    else begin m_wdata <= m_rdata; state <= S_WR; end
                end
                S_WR: if (m_ready) begin
                    if (m_err) begin
                        err <= 1'b1; err_addr <= m_addr; state <= S_IDLE;
                    end else begin
                        src   <= src + 32'd4;
                        dst   <= dst + 32'd4;
                        len   <= len - 32'd4;
                        count <= count + 32'd1;
                        state <= (len == 32'd4) ? S_NEXT : S_RD;
                    end
                end
                S_NEXT: begin
                    if (sg && next != 32'd0) begin
                        desc <= next;
                        dk   <= 2'd0;
                        if (next[1:0] != 2'b00) begin err <= 1'b1; err_addr <= next; state <= S_IDLE; end
                        else state <= S_DESC;
                    end else begin
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    always @* begin
        case (addr)
            5'h00: rdata = {29'd0, sg, ie, 1'b0};
            5'h04: rdata = {29'd0, err, done, busy};
            5'h08: rdata = src;
            5'h0C: rdata = dst;
            5'h10: rdata = len;
            5'h14: rdata = desc;
            5'h18: rdata = count;
            5'h1C: rdata = err_addr;
            default: rdata = 32'd0;
        endcase
    end
endmodule
