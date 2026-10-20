`default_nettype none
module param_mux #(
    parameter W = 8, N = 3, PIPE = 0
) (
    input wire clk, rst_n,
    input wire [N*W-1:0] din,
    input wire [(N<=1 ? 1 : $clog2(N))-1:0] sel,
    output wire [W-1:0] dout,
    output wire [N-1:0] parity
);
    wire [N*W-1:0] lanes;
    localparam SW = (N<=1) ? 1 : $clog2(N);
    genvar g;
    generate
        // 非法配置在展开时失败，不能让错误参数悄悄生成奇怪范围。
        if (W<1 || N<1 || (PIPE!=0 && PIPE!=1)) begin : g_invalid
            PARAMETER_ERROR_W_N_PIPE invalid_configuration();
        end
        for (g=0; g<N; g=g+1) begin : g_lane
            if (PIPE) begin : g_reg
                reg [W-1:0] q;
                always @(posedge clk or negedge rst_n)
                    if (!rst_n) q <= {W{1'b0}};
                    else q <= din[g*W +: W];
                assign lanes[g*W +: W] = q;
            end else begin : g_bypass
                assign lanes[g*W +: W] = din[g*W +: W];
            end
            assign parity[g] = ^lanes[g*W +: W];
        end
    endgenerate
    reg [W-1:0] selected;
    integer i;
    always @* begin
        selected = {W{1'b0}};
        for (i=0; i<N; i=i+1)
            if (sel == i[SW-1:0]) selected = lanes[i*W +: W];
    end
    assign dout = selected;
endmodule
`default_nettype wire
