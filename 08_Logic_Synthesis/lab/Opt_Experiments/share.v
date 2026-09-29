// =============================================================================
// 资源共享（resource sharing）实验
// -----------------------------------------------------------------------------
// share_mul_2：两个乘法的结果二选一 —— 字面上是 2 个乘法器 + 1 个 MUX
// share_mul_1：先选操作数再乘      —— 1 个乘法器 + 2 个 MUX
// 两者功能完全相同。乘法器比 MUX 大得多，所以后者面积小；
// 代价是 sel → MUX → 乘法器 这条路径变长（MUX 从乘法器后面挪到了前面）。
// 综合工具能否自动把前者变成后者，就是“资源共享”优化。
// =============================================================================
module share_mul_2 #(
    parameter W = 8
)(
    input            sel,
    input  [W-1:0]   a, b, c, d,
    output [2*W-1:0] y
);
    assign y = sel ? a * b : c * d;
endmodule

module share_mul_1 #(
    parameter W = 8
)(
    input            sel,
    input  [W-1:0]   a, b, c, d,
    output [2*W-1:0] y
);
    wire [W-1:0] x0 = sel ? a : c;
    wire [W-1:0] x1 = sel ? b : d;
    assign y = x0 * x1;
endmodule
