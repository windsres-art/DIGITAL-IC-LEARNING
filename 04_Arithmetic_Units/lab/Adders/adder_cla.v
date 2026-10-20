`default_nettype none
// 分组 CLA：组内完全展开进位方程，组与组之间仍行波。W>=1，B>=1。
module adder_cla #(parameter W=8, B=4) (
    input wire [W-1:0] a,b,
    input wire cin,
    output wire [W-1:0] sum,
    output wire cout
);
    localparam NB=(W+B-1)/B;
    wire [W-1:0] p,g;
    wire [W:0] c;
    assign p=a^b;
    assign g=a&b;
    assign c[0]=cin;
    genvar block_no,i,j;
    generate for(block_no=0;block_no<NB;block_no=block_no+1) begin : g_block
        localparam BASE=block_no*B;
        localparam K=((W-BASE)<B)?(W-BASE):B;
        for(i=0;i<K;i=i+1) begin : g_carry
            wire [i:0] terms;
            for(j=0;j<=i;j=j+1) begin : g_term
                if(j==i) begin : g_last
                    assign terms[j]=g[BASE+j];
                end else begin : g_lower
                    assign terms[j]=g[BASE+j] & (&p[BASE+i:BASE+j+1]);
                end
            end
            // 只引用本组入口 carry，不写成逐位 c[i] 递推。
            assign c[BASE+i+1]=(|terms) | ((&p[BASE+i:BASE])&c[BASE]);
        end
    end endgenerate
    assign sum=p^c[W-1:0];
    assign cout=c[W];
endmodule
`default_nettype wire
