// =============================================================================
// 偶数分频，50% 占空比
//   计数 0 .. N/2-1，每数满 N/2 个输入周期翻转一次输出 → 周期 N 个输入周期
//   输出直接由寄存器给出，没有毛刺；SDC 里在这个寄存器输出上
//   create_generated_clock -divide_by N
// =============================================================================
module clk_div_even #(
    parameter N = 4                     // 偶数，>= 2
)(
    input      clk,
    input      rst_n,
    output reg clk_out
);
    localparam HALF = N / 2;
    localparam CW   = (HALF > 1) ? $clog2(HALF) : 1;
    localparam integer  LAST_I = HALF - 1;
    localparam [CW-1:0] LAST   = LAST_I[CW-1:0];

    reg [CW-1:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt     <= {CW{1'b0}};
            clk_out <= 1'b0;
        end else if (cnt == LAST) begin
            cnt     <= {CW{1'b0}};
            clk_out <= ~clk_out;
        end else begin
            cnt     <= cnt + 1'b1;
        end
    end

endmodule
