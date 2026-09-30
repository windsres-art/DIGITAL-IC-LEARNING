// =============================================================================
// 波特率发生器：每 DIV 个 clk 输出一拍 tick，tick 频率 = 16 × 波特率（16 倍过采样）
//   例：clk = 50 MHz、115200 bps → DIV = 50e6 / (115200 × 16) = 27.13 → 取 27，误差 +0.47%
//   整数分频的误差随波特率升高而变大，需要更精确时改用累加器小数分频
//   （../../../03_Common_Circuits/README.md 第 5 节）
// =============================================================================
module uart_baud #(
    parameter DIV = 27
)(
    input      clk,
    input      rst_n,
    output reg tick
);
    localparam CW = (DIV > 1) ? $clog2(DIV) : 1;
    localparam [CW-1:0] LAST = DIV - 1;

    reg [CW-1:0] cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt  <= {CW{1'b0}};
            tick <= 1'b0;
        end else begin
            tick <= (cnt == LAST);
            cnt  <= (cnt == LAST) ? {CW{1'b0}} : cnt + 1'b1;
        end
    end
endmodule
