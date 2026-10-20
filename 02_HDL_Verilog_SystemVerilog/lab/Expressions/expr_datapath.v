`default_nettype none
// 参数约束 W >= 2。显式扩展后运算，让进位与符号意图不依赖上下文。
module expr_datapath #(
    parameter W = 8
) (
    input wire [W-1:0] a, b,
    input wire signed [W-1:0] sa, sb,
    output wire [W:0] sum,
    output wire [W-1:0] sum_wrap,
    output wire signed [W:0] signed_sum,
    output wire signed [W-1:0] shifted,
    output wire signed_lt,
    output wire overflow
);
    assign sum = {1'b0, a} + {1'b0, b};
    assign sum_wrap = sum[W-1:0];
    // 拼接本身无符号，先显式转为 signed，再参与运算。
    assign signed_sum = $signed({sa[W-1], sa}) + $signed({sb[W-1], sb});
    assign shifted = sa >>> 1;
    assign signed_lt = sa < sb;
    // 同号相加而截断后的符号改变，才是补码有符号溢出。
    assign overflow = (sa[W-1] == sb[W-1]) &&
                      (signed_sum[W-1] != sa[W-1]);
endmodule
`default_nettype wire
