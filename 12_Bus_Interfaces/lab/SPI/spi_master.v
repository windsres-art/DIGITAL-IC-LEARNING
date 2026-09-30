// =============================================================================
// SPI 主机：8 bit、MSB 先发，模式（CPOL/CPHA）和分频在运行时配置
//   div：SCLK 半周期 = div 个 clk（div ≥ 1）
//   一次 start 传一个字节：CS 拉低 → 等半周期 → 16 个 SCLK 沿 → 等半周期 → CS 拉高 → 至少空闲半周期
//   前沿（leading）：SCLK 离开空闲电平的沿；后沿（trailing）：回到空闲电平的沿
//     CPHA=0：前沿采样、后沿移位，第一位在 CS 拉低时就要放好
//     CPHA=1：前沿移位、后沿采样
// =============================================================================
module spi_master (
    input            clk,
    input            rst_n,
    input            cpol,
    input            cpha,
    input      [7:0] div,
    input            start,
    input      [7:0] tx,
    output           busy,
    output reg       done,          // 单拍脉冲，rx 有效
    output reg [7:0] rx,
    output reg       sclk,
    output reg       cs_n,
    output           mosi,
    input            miso
);
    localparam IDLE = 2'd0, SETUP = 2'd1, XFER = 2'd2, HOLD = 2'd3;

    reg [1:0] st;
    reg [7:0] cnt;
    reg [4:0] nedge;                // 已产生的 SCLK 沿数 0..16
    reg [3:0] nsamp;                // 已采样位数 0..8
    reg       gap;                  // CS 拉高后的最小空闲
    reg [7:0] sh_tx, sh_rx;

    assign busy = (st != IDLE) | gap;
    assign mosi = sh_tx[7];

    wire half    = (cnt == 8'd0);
    wire leading = ~nedge[0];       // 偶数号沿是前沿
    wire samp_e  = cpha ? ~leading :  leading;
    wire shift_e = cpha ?  leading : ~leading;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= IDLE; cnt <= 8'd0; nedge <= 5'd0; nsamp <= 4'd0; gap <= 1'b0;
            sclk <= 1'b0; cs_n <= 1'b1; sh_tx <= 8'h0; sh_rx <= 8'h0;
            done <= 1'b0; rx <= 8'h0;
        end else begin
            done <= 1'b0;
            cnt  <= half ? div - 8'd1 : cnt - 8'd1;
            case (st)
                IDLE: begin
                    sclk <= cpol;                       // CS 无效时 SCLK 停在空闲电平
                    if (gap) begin
                        if (half) gap <= 1'b0;
                    end else if (start) begin
                        cs_n  <= 1'b0;
                        sh_tx <= tx;                    // MSB 立即出现在 MOSI 上（CPHA=0 需要）
                        nedge <= 5'd0;
                        nsamp <= 4'd0;
                        cnt   <= div - 8'd1;
                        st    <= SETUP;
                    end
                end
                SETUP: if (half) st <= XFER;
                XFER: if (half) begin
                    sclk  <= ~sclk;
                    nedge <= nedge + 1'b1;
                    if (samp_e) begin
                        sh_rx <= {sh_rx[6:0], miso};
                        nsamp <= nsamp + 1'b1;
                    end
                    // 移位沿：CPHA=0 时第 8 次采样后的后沿不再移位；CPHA=1 时第一个前沿不移位
                    if (shift_e && nsamp != 4'd0 && nsamp != 4'd8)
                        sh_tx <= {sh_tx[6:0], 1'b0};
                    if (nedge == 5'd15) st <= HOLD;
                end
                HOLD: if (half) begin
                    cs_n <= 1'b1;
                    done <= 1'b1;
                    rx   <= sh_rx;
                    gap  <= 1'b1;
                    st   <= IDLE;
                end
                default: st <= IDLE;
            endcase
        end
    end
endmodule
