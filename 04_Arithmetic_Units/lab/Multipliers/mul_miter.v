module mul_miter #(parameter W=4) (
    input wire [W-1:0] a,b,
    output wire ok
);
    wire [2*W-1:0] pu,ps;
    wire signed [W-1:0] sa=a,sb=b;
    wire [2*W-1:0] ru={{W{1'b0}},a}*{{W{1'b0}},b};
    wire signed [2*W-1:0] rs=sa*sb;
    mul_wallace #(.W(W)) u(.a(a),.b(b),.product(pu));
    mul_booth #(.W(W)) s(.a(sa),.b(sb),.product(ps));
    assign ok=(pu==ru)&&(ps==rs);
endmodule
