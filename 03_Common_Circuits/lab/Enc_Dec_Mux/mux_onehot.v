// =============================================================================
// 独热选择 MUX（AND-OR 结构）
//   dout = |(din[i] & {W{sel[i]}})：每路先与自己的选择位相与，再全部相或
//   只有一级与门 + 一个 N 输入或树，不需要先把 sel 译码，常用在仲裁器 gnt 之后
//   前提：sel 独热。sel 全 0 输出 0；多热时输出多路相或（错误数据，但不是 X）
// =============================================================================
module mux_onehot #(
    parameter N = 8,
    parameter W = 8
)(
    input      [N*W-1:0] din,
    input      [N-1:0]   sel,
    output reg [W-1:0]   dout
);
    integer i;
    always @(*) begin
        dout = {W{1'b0}};
        for (i = 0; i < N; i = i + 1)
            dout = dout | (din[i*W +: W] & {W{sel[i]}});
    end
endmodule
