// =============================================================================
// 加权轮询仲裁器（Weighted Round Robin），信用（credit）计数法
//   每个请求者有 credit，初值为权重 W[i]；每次被授权减 1
//   只在"有请求且还有信用"的请求者之间做轮询（交错授权，不是连续授权 W 次）
//   所有正在请求的都用完信用时，全体重新装载权重（本拍直接用 req 仲裁）
//   → 所有人一直请求时，每一轮 sum(W) 次授权里 i 恰好得到 W[i] 次
//   WEIGHTS：每个权重 WW 位打包，{W[N-1], ..., W[0]}，权重 >= 1
// =============================================================================
module arb_wrr #(
    parameter             N       = 4,
    parameter             WW      = 4,
    parameter [N*WW-1:0]  WEIGHTS = {4'd1, 4'd2, 4'd3, 4'd4}   // W3..W0
)(
    input              clk,
    input              rst_n,
    input      [N-1:0] req,
    output     [N-1:0] gnt
);
    reg  [WW-1:0]  credit [0:N-1];
    wire [N-1:0]   has_credit;
    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : g_hc
            assign has_credit[g] = (credit[g] != {WW{1'b0}});
        end
    endgenerate

    wire [N-1:0]   eligible = req & has_credit;
    wire           reload   = (|req) && !(|eligible);
    wire [N-1:0]   cand     = reload ? req : eligible;

    // 在 cand 上做轮询（与 arb_rr.v 相同的双倍宽度写法）
    reg  [N-1:0]   last;
    wire [N-1:0]   base = {last[N-2:0], last[N-1]};
    wire [2*N-1:0] dreq = {cand, cand};
    wire [2*N-1:0] dgnt = dreq & ~(dreq - {{N{1'b0}}, base});
    assign gnt = dgnt[N-1:0] | dgnt[2*N-1:N];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last <= {1'b1, {(N-1){1'b0}}};
            for (i = 0; i < N; i = i + 1) credit[i] <= WEIGHTS[i*WW +: WW];
        end else if (|req) begin
            last <= gnt;
            for (i = 0; i < N; i = i + 1) begin
                if (reload) credit[i] <= WEIGHTS[i*WW +: WW] - {{(WW-1){1'b0}}, gnt[i]};
                else        credit[i] <= credit[i]          - {{(WW-1){1'b0}}, gnt[i]};
            end
        end
    end

endmodule
