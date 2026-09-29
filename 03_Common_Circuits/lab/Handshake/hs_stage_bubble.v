// =============================================================================
// valid/ready 打一拍：最简单但会断流的写法
//   只在寄存器空的时候接收：in_ready = ~out_valid
//   连续传输时，本级被取走的那一拍 in_ready 仍为 0（它看的是本拍的 out_valid），
//   下一拍才能接收新数据 → 每两拍传一个，吞吐 50%
//   优点：in_ready 是寄存器输出，没有组合路径穿过本级
// =============================================================================
module hs_stage_bubble #(
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
    assign in_ready = ~out_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_data  <= {DW{1'b0}};
        end else if (in_valid && in_ready) begin
            out_valid <= 1'b1;
            out_data  <= in_data;
        end else if (out_ready) begin
            out_valid <= 1'b0;
        end
    end

endmodule
