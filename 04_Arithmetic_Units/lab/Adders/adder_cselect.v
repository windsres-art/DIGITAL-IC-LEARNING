`default_nettype none
// 第一组用实际 cin；其余组预先算 cin=0/1，两份结果用真实 carry 选择。
module adder_cselect #(parameter W=8, B=4) (
    input wire [W-1:0] a,b,
    input wire cin,
    output wire [W-1:0] sum,
    output wire cout
);
    localparam NB=(W+B-1)/B;
    wire [NB:0] c;
    assign c[0]=cin;
    genvar k;
    generate for(k=0;k<NB;k=k+1) begin : g_block
        localparam BASE=k*B;
        localparam K=((W-BASE)<B)?(W-BASE):B;
        if(k==0) begin : g_first
            adder_rca #(.W(K)) first(
                .a(a[BASE +: K]),.b(b[BASE +: K]),.cin(c[k]),
                .sum(sum[BASE +: K]),.cout(c[k+1]));
        end else begin : g_speculate
            wire [K:0] r0,r1;
            adder_rca #(.W(K)) zero(
                .a(a[BASE +: K]),.b(b[BASE +: K]),.cin(1'b0),
                .sum(r0[K-1:0]),.cout(r0[K]));
            adder_rca #(.W(K)) one(
                .a(a[BASE +: K]),.b(b[BASE +: K]),.cin(1'b1),
                .sum(r1[K-1:0]),.cout(r1[K]));
            assign {c[k+1],sum[BASE +: K]}=c[k]?r1:r0;
        end
    end endgenerate
    assign cout=c[NB];
endmodule
`default_nettype wire
