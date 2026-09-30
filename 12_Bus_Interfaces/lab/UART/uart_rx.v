// =============================================================================
// UART 接收器：16 倍过采样
//   - rxd 是异步输入，先两级同步（../../../06_CDC/README.md 第 2 节），复位值为 1（空闲电平）
//   - 空闲时某个 tick 采到 0 → 认为起始位开始，此刻记作位内第 0 个 tick
//   - 每一位在第 7、8、9 个 tick 采三次，多数表决（抗单点毛刺），即在位中心判决
//   - 起始位表决为 1 → 假起始（毛刺），回到空闲
//   - 停止位在中心判决后立刻回到空闲，给下一帧起始位留出余量
//   - 只检查第一个停止位（接收方收 1 位停止位就够了，多出的停止位只是空闲）
//   输出：valid 单拍脉冲，data / parity_err / frame_err 保持到下一帧
// =============================================================================
module uart_rx #(
    parameter PARITY = 0
)(
    input            clk,
    input            rst_n,
    input            tick,
    input            rxd,
    output reg [7:0] data,
    output reg       valid,
    output reg       parity_err,
    output reg       frame_err
);
    localparam LASTBIT = 9 + ((PARITY != 0) ? 1 : 0);  // 停止位的序号（0 = 起始位）

    reg rx_m, rx_s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx_m <= 1'b1; rx_s <= 1'b1; end
        else        begin rx_m <= rxd;  rx_s <= rx_m; end
    end

    reg       busy;
    reg [3:0] ovs, bitn;
    reg [1:0] smp;                  // 第 7、8 个 tick 的采样
    reg [7:0] sh;
    reg       par_bit;

    // 第 9 个 tick 时与前两次采样做多数表决
    wire maj = (smp[1] & smp[0]) | (smp[1] & rx_s) | (smp[0] & rx_s);
    wire par_ok = (PARITY == 1) ? (^{sh, par_bit} == 1'b1) :
                  (PARITY == 2) ? (^{sh, par_bit} == 1'b0) : 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0; ovs <= 4'd0; bitn <= 4'd0; smp <= 2'b11;
            sh <= 8'h0; par_bit <= 1'b0;
            data <= 8'h0; valid <= 1'b0; parity_err <= 1'b0; frame_err <= 1'b0;
        end else begin
            valid <= 1'b0;
            if (tick) begin
                if (!busy) begin
                    if (!rx_s) begin            // 起始位下降沿（精度 1 个 tick）
                        busy <= 1'b1;
                        ovs  <= 4'd1;
                        bitn <= 4'd0;
                    end
                end else begin
                    if (ovs == 4'd7 || ovs == 4'd8) smp <= {smp[0], rx_s};
                    if (ovs == 4'd9) begin
                        if (bitn == 4'd0) begin
                            if (maj) busy <= 1'b0;                  // 假起始
                        end else if (bitn <= 4'd8) begin
                            sh <= {maj, sh[7:1]};                   // LSB 先到
                        end else if (bitn != LASTBIT) begin
                            par_bit <= maj;
                        end else begin                              // 停止位
                            busy       <= 1'b0;
                            valid      <= 1'b1;
                            data       <= sh;
                            frame_err  <= ~maj;
                            parity_err <= ~par_ok;
                        end
                    end
                    if (ovs == 4'd15) begin
                        ovs  <= 4'd0;
                        bitn <= bitn + 1'b1;
                    end else begin
                        ovs <= ovs + 1'b1;
                    end
                end
            end
        end
    end
endmodule
