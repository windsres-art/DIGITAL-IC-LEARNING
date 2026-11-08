// =============================================================================
// 小数分频（累加器法），输出单周期使能脉冲 tick
//   分频比 K = M / D（M > D）：每个输入周期累加 D，累加值 >= M 时减 M 并出一个 tick。
//   长期平均每 M/D 个周期一个 tick；单个间隔只能是 floor(K) 或 ceil(K) 个周期，
//   累加器把两种间隔均匀地穿插开（例：K = 8.7 → 每 10 个 tick 里 3 个 8、7 个 9）。
//   代价：tick 的瞬时间隔有 1 个输入周期的抖动。
//   tick 当时钟使能用（整个设计仍在 clk 一个时钟域），不要拿它当时钟。
// =============================================================================
module clk_div_frac #(
    parameter M = 87,
    parameter D = 10                    // K = M / D，要求 M > D > 0
)(
    input      clk,
    input      rst_n,
    output reg tick
);
    localparam AW = $clog2(M + D);

    reg  [AW-1:0] acc;                  // 始终 < M
    wire [AW-1:0] sum = acc + D;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc  <= 0;
            tick <= 1'b0;
        end else if (sum >= M) begin
            acc  <= sum - M;
            tick <= 1'b1;
        end else begin
            acc  <= sum;
            tick <= 1'b0;
        end
    end

endmodule
