`default_nettype none
// CSA 后接一次进位传播，才得到普通二进制结果；总和保留 W+2 位。
module adder_three #(parameter W=8) (
    input wire [W-1:0] a,b,d,
    output wire [W+1:0] total
);
    wire [W-1:0] saved_sum;
    wire [W:0] saved_carry;
    csa3 #(.W(W)) compress(.a(a),.b(b),.d(d),
        .saved_sum(saved_sum),.saved_carry(saved_carry));
    adder_prefix #(.W(W+1)) finish(
        .a({1'b0,saved_sum}),.b(saved_carry),.cin(1'b0),
        .sum(total[W:0]),.cout(total[W+1]));
endmodule
`default_nettype wire
