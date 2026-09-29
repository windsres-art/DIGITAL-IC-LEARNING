// =============================================================================
// N 级寄存器级串联，只用于 Yosys 统计最长组合路径（ltp），不参与仿真
//   KIND = 0：hs_stage_pipe（第 8 节，ready 组合穿透）
//   KIND = 1：skid_buffer（ready 被寄存）
// =============================================================================
module ready_chain #(
    parameter KIND = 0,
    parameter N    = 8,
    parameter DW   = 8
)(
    input           clk,
    input           rst_n,
    input           in_valid,
    output          in_ready,
    input  [DW-1:0] in_data,
    output          out_valid,
    input           out_ready,
    output [DW-1:0] out_data
);
    wire [N:0]    v, r;
    wire [DW-1:0] d [0:N];
    assign v[0]      = in_valid;
    assign d[0]      = in_data;
    assign r[N]      = out_ready;
    assign in_ready  = r[0];
    assign out_valid = v[N];
    assign out_data  = d[N];

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : g_st
            if (KIND == 0) begin : g_p
                hs_stage_pipe #(.DW(DW)) u (.clk(clk), .rst_n(rst_n),
                    .in_valid(v[g]), .in_ready(r[g]), .in_data(d[g]),
                    .out_valid(v[g+1]), .out_ready(r[g+1]), .out_data(d[g+1]));
            end else begin : g_s
                skid_buffer #(.DW(DW)) u (.clk(clk), .rst_n(rst_n),
                    .in_valid(v[g]), .in_ready(r[g]), .in_data(d[g]),
                    .out_valid(v[g+1]), .out_ready(r[g+1]), .out_data(d[g+1]));
            end
        end
    endgenerate

endmodule
