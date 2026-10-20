`default_nettype none
// 三个 W 位无符号数压成两行；carry 已包含权重左移，不要再移第二次。
module csa3 #(parameter W=8) (
    input wire [W-1:0] a,b,d,
    output wire [W-1:0] saved_sum,
    output wire [W:0] saved_carry
);
    assign saved_sum=a^b^d;
    assign saved_carry={(a&b)|(a&d)|(b&d),1'b0};
endmodule
`default_nettype wire
