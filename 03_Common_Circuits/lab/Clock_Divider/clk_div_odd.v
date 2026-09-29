// =============================================================================
// 奇数分频，50% 占空比
//   只用上升沿，输出高低电平只能是整数个输入周期：N=3 时只能 2:1 或 1:2。
//   做法：
//     clk_p  上升沿寄存器，高 (N+1)/2 个周期、低 (N-1)/2 个周期
//     clk_n  下降沿寄存器采 clk_p，即 clk_p 晚半个周期
//     clk_out = clk_p & clk_n：上升晚半拍、下降不变 → 高 N/2 个周期，正好 50%
//   两个输入不会同时反向变化（相差半个周期），所以与门输出没有毛刺。
//   但与门在时钟路径上：ASIC 里要用库里的时钟单元并 dont_touch，SDC 用
//   create_generated_clock 的 -edges 描述（写法以工具文档为准）。
// =============================================================================
module clk_div_odd #(
    parameter N = 3                     // 奇数，>= 3
)(
    input  clk,
    input  rst_n,
    output clk_out,
    output clk_p_out                    // 只用上升沿的结果，占空比不是 50%，用于对比
);
    localparam CW = $clog2(N);
    localparam integer  LAST_I = N - 1;
    localparam integer  HI_I   = (N + 1) / 2;
    localparam [CW-1:0] LAST   = LAST_I[CW-1:0];
    localparam [CW-1:0] HI     = HI_I[CW-1:0];

    reg  [CW-1:0] cnt;
    reg           clk_p, clk_n;
    wire [CW-1:0] cnt_nxt = (cnt == LAST) ? {CW{1'b0}} : cnt + 1'b1;

    // clk_p 与 cnt 对齐：cnt 在 0 .. HI-1 时为高
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt   <= LAST;              // 复位后第一个沿进入 cnt=0，clk_p 拉高
            clk_p <= 1'b0;
        end else begin
            cnt   <= cnt_nxt;
            clk_p <= (cnt_nxt < HI);
        end
    end

    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) clk_n <= 1'b0;
        else        clk_n <= clk_p;
    end

    assign clk_out   = clk_p & clk_n;
    assign clk_p_out = clk_p;

endmodule
