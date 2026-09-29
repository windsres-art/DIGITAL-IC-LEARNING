// =============================================================================
// MCP（Multi-Cycle Path）同步：数据 + 使能脉冲，两相（toggle）握手带 ack 反馈
//   Cummings 称为 "MCP formulation"：
//   - 多 bit 数据不同步，只保证它在目的端采样时已经稳定了多个周期（所以叫多周期路径）
//   - 一个"加载使能"用 toggle 型脉冲同步器跨过去，目的端据此采样数据
//   - 目的端把 ack 也用 toggle 送回源端，源端据此知道可以更新下一笔数据
//
// 与四相握手相比：每笔只需往返一次（req 翻转 → ack 翻转），吞吐约高一倍；
// 代价是控制逻辑用 toggle + 边沿检测，稍难读。
//
// STA 约束：data_hold → dst_data 这组路径要告诉工具它是异步跨域
//   （set_max_delay -datapath_only 或 false path），不要让工具按同步单周期路径去修。
// =============================================================================
`timescale 1ns / 1ps

module mcp_sync #(
    parameter W = 16
)(
    input              clk_src,
    input              rst_src_n,
    input              src_valid,
    input      [W-1:0] src_data,
    output             src_ready,

    input              clk_dst,
    input              rst_dst_n,
    output reg         dst_valid,
    output reg [W-1:0] dst_data
);
    // ---------------- 源域 ----------------
    reg         req_tog;
    reg [W-1:0] data_hold;
    reg [1:0]   ack_sync;

    // req_tog 与同步回来的 ack_tog 相等 → 上一笔已被目的端收下
    assign src_ready = (req_tog == ack_sync[1]);

    always @(posedge clk_src or negedge rst_src_n) begin
        if (!rst_src_n) begin
            req_tog   <= 1'b0;
            data_hold <= {W{1'b0}};
        end else if (src_valid && src_ready) begin
            req_tog   <= ~req_tog;
            data_hold <= src_data;
        end
    end

    // ---------------- 目的域 ----------------
    reg [2:0] req_sync;             // [0][1] 同步，[2] 边沿检测
    reg       ack_tog;
    wire      load = req_sync[2] ^ req_sync[1];

    always @(posedge clk_dst or negedge rst_dst_n) begin
        if (!rst_dst_n) begin
            req_sync  <= 3'b000;
            ack_tog   <= 1'b0;
            dst_valid <= 1'b0;
            dst_data  <= {W{1'b0}};
        end else begin
            req_sync  <= {req_sync[1:0], req_tog};
            dst_valid <= load;
            if (load) begin
                dst_data <= data_hold;
                ack_tog  <= ~ack_tog;
            end
        end
    end

    always @(posedge clk_src or negedge rst_src_n) begin
        if (!rst_src_n) ack_sync <= 2'b00;
        else            ack_sync <= {ack_sync[0], ack_tog};
    end
endmodule
