`default_nettype none
// 无符号 AND 部分积 + Wallace 风格行压缩 + 最终 CPA。
module mul_wallace #(parameter W=8) (
    input wire [W-1:0] a,b,
    output wire [2*W-1:0] product
);
    wire [2*W*W-1:0] rows;
    genvar i;
    generate for(i=0;i<W;i=i+1) begin : g_partial
        assign rows[i*(2*W) +: 2*W]=
            ({{W{1'b0}},a}&{(2*W){b[i]}})<<i;
    end endgenerate
    csa_reduce #(.PW(2*W),.ROWS(W)) tree(.rows(rows),.total(product));
endmodule
`default_nettype wire
