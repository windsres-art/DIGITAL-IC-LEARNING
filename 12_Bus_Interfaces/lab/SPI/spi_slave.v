// =============================================================================
// SPI 从机（系统时钟过采样实现）：8 bit、MSB 先发，模式运行时配置
//   SCLK / CS_n / MOSI 都是外部异步信号：先两级同步，再用打一拍做边沿检测。
//   三者经过相同的同步延迟，所以 MOSI 相对 SCLK 的建立/保持关系保持不变。
//   代价：从 SCLK 移位沿到 MISO 更新有 3 个 clk 左右的延迟，从 CS 下降到第一位装好也有同样延迟，
//   所以系统时钟必须比 SCLK 快足够多（本实验实测 SCLK 半周期 ≥ 4 个 clk）。
//   另一种做法是直接用 SCLK 当时钟（见 README 第 5.5 节）。
//   tx_data 在 CS 下降沿被锁存；收满 8 位时 rx_valid 单拍有效。
// =============================================================================
module spi_slave (
    input            clk,
    input            rst_n,
    input            cpol,
    input            cpha,
    input            sclk,
    input            cs_n,
    input            mosi,
    output           miso,
    output           miso_oe,       // 片选有效时才驱动 MISO，多从机共用 MISO 线
    input      [7:0] tx_data,
    output reg [7:0] rx_data,
    output reg       rx_valid
);
    reg [2:0] sclk_r, cs_r;
    reg [1:0] mosi_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_r <= 3'b000; cs_r <= 3'b111; mosi_r <= 2'b00;
        end else begin
            sclk_r <= {sclk_r[1:0], sclk};
            cs_r   <= {cs_r[1:0], cs_n};
            mosi_r <= {mosi_r[0], mosi};
        end
    end

    wire cs_act  = ~cs_r[1];
    wire rise    =  sclk_r[1] & ~sclk_r[2];
    wire fall    = ~sclk_r[1] &  sclk_r[2];
    wire cs_fall = ~cs_r[1] & cs_r[2];
    wire leading  = cpol ? fall : rise;
    wire trailing = cpol ? rise : fall;
    wire samp_e   = cpha ? trailing : leading;
    wire shift_e  = cpha ? leading  : trailing;

    reg [7:0] sh_tx;
    reg [6:0] sh_rx;                // 第 8 位直接拼进 rx_data
    reg [3:0] nsamp;

    assign miso    = sh_tx[7];
    assign miso_oe = cs_act;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sh_tx <= 8'h0; sh_rx <= 7'h0; nsamp <= 4'd0;
            rx_data <= 8'h0; rx_valid <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            if (cs_fall) begin
                sh_tx <= tx_data;
                nsamp <= 4'd0;
            end else if (cs_act) begin
                if (samp_e) begin
                    sh_rx <= {sh_rx[5:0], mosi_r[1]};
                    nsamp <= nsamp + 1'b1;
                    if (nsamp == 4'd7) begin
                        rx_data  <= {sh_rx, mosi_r[1]};
                        rx_valid <= 1'b1;
                    end
                end
                // 与主机相同的规则：CPHA=0 最后一个后沿不移位，CPHA=1 第一个前沿不移位
                if (shift_e && nsamp != 4'd0 && nsamp != 4'd8)
                    sh_tx <= {sh_tx[6:0], 1'b0};
            end
        end
    end
endmodule
