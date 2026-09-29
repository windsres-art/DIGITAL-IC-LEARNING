// =============================================================================
// 四相握手（4-phase / return-to-zero）多 bit 数据跨域
//
//   src: 锁存数据, req=1 ──► dst: 看到 req=1，采数据, ack=1
//   src: 看到 ack=1, req=0 ──► dst: 看到 req=0, ack=0
//   src: 看到 ack=0 → 空闲，可以发下一个
//
// 为什么数据总线不用同步器：数据在 req 拉高前就已锁存，并且一直保持到 ack 回来；
//   dst 看到同步后的 req 时，数据已经稳定了至少 2 个 dst 周期 → 直接采样是安全的。
//   只有 req、ack 两根单 bit 控制线过同步器。
// 代价：每次传输要往返两次（req↑ack↑、req↓ack↓），吞吐低。
//
// 这个版本目的端没有反压：dst_valid 来了必须当拍收下。
// 需要反压时，把"ack 拉高"改成等目的端真正收下数据之后再拉高即可。
// =============================================================================
`timescale 1ns / 1ps

module handshake_sync #(
    parameter W = 16
)(
    // 源时钟域
    input              clk_src,
    input              rst_src_n,
    input              src_valid,
    input      [W-1:0] src_data,
    output             src_ready,
    // 目的时钟域
    input              clk_dst,
    input              rst_dst_n,
    output reg         dst_valid,
    output reg [W-1:0] dst_data
);
    // ---------------- 源域 ----------------
    reg         req;
    reg [W-1:0] data_hold;          // 跨域期间保持不变的数据
    reg [1:0]   ack_sync;           // ack → 源域

    wire ack_s = ack_sync[1];
    assign src_ready = !req && !ack_s;     // 上一轮彻底结束（ack 也回到 0）才空闲

    always @(posedge clk_src or negedge rst_src_n) begin
        if (!rst_src_n) begin
            req       <= 1'b0;
            data_hold <= {W{1'b0}};
        end else if (src_valid && src_ready) begin
            req       <= 1'b1;
            data_hold <= src_data;
        end else if (req && ack_s) begin
            req       <= 1'b0;
        end
    end

    // ---------------- 目的域 ----------------
    reg [1:0] req_sync;             // req → 目的域
    reg       req_d;                // 边沿检测
    wire      req_s = req_sync[1];
    reg       ack;

    always @(posedge clk_dst or negedge rst_dst_n) begin
        if (!rst_dst_n) begin
            req_sync  <= 2'b00;
            req_d     <= 1'b0;
            ack       <= 1'b0;
            dst_valid <= 1'b0;
            dst_data  <= {W{1'b0}};
        end else begin
            req_sync  <= {req_sync[0], req};
            req_d     <= req_s;
            ack       <= req_s;                 // ack 跟随同步后的 req
            dst_valid <= req_s && !req_d;       // req 上升沿：数据有效一拍
            if (req_s && !req_d)
                dst_data <= data_hold;          // 跨域采样多 bit 数据（此时它已稳定）
        end
    end

    always @(posedge clk_src or negedge rst_src_n) begin
        if (!rst_src_n) ack_sync <= 2'b00;
        else            ack_sync <= {ack_sync[0], ack};
    end
endmodule
