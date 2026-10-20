`default_nettype none
// 行波进位：每一位等待前一位的 carry。参数契约 W >= 1。
module adder_rca #(parameter W=8) (
    input wire [W-1:0] a,b,
    input wire cin,
    output wire [W-1:0] sum,
    output wire cout
);
    wire [W:0] c;
    wire [W-1:0] p,g;
    assign p=a^b;
    assign g=a&b;
    assign c[0]=cin;
    genvar i;
    generate for(i=0;i<W;i=i+1) begin : g_bit
        assign c[i+1]=g[i] | (p[i]&c[i]);
        assign sum[i]=p[i]^c[i];
    end endgenerate
    assign cout=c[W];
endmodule
`default_nettype wire
