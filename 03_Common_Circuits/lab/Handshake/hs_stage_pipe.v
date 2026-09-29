// =============================================================================
// valid/ready 打一拍不断流（forward register slice / pipeline register）
//   in_ready = ~out_valid | out_ready：本级空，或者本级的数据这一拍会被取走，
//   就能同时接收新数据 → 连续传输时每拍一个，吞吐 100%
//   valid 和 data 被寄存（切断了前向的组合路径），但 ready 是组合的：
//   out_ready 经过一个或门直接到 in_ready。多级串联时 ready 从最后一级一路组合
//   传回第一级，级数多了就成了关键路径——要切断它得用 skid buffer（第 13 节）
// =============================================================================
module hs_stage_pipe #(
    parameter DW = 8
)(
    input               clk,
    input               rst_n,
    input               in_valid,
    output              in_ready,
    input      [DW-1:0] in_data,
    output reg          out_valid,
    input               out_ready,
    output reg [DW-1:0] out_data
);
    assign in_ready = ~out_valid | out_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
        end else if (in_ready) begin
            out_valid <= in_valid;      // 能收的拍：有新数据就装，没有就变空
        end
    end

    // 数据通路不需要复位，只在真正接收时更新（省功耗、省复位布线）
    always @(posedge clk) begin
        if (in_valid && in_ready) out_data <= in_data;
    end

endmodule
