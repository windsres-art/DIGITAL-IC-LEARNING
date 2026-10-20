`default_nettype none
// Kogge-Stone 风格的全前缀网络，逐级合并距离为 1、2、4... 的区间。
module adder_prefix #(parameter W=8) (
    input wire [W-1:0] a,b,
    input wire cin,
    output wire [W-1:0] sum,
    output wire cout
);
    localparam LEVELS=(W<=1)?0:$clog2(W);
    wire [W-1:0] p[0:LEVELS];
    wire [W-1:0] g[0:LEVELS];
    wire [W:0] c;
    assign p[0]=a^b;
    assign g[0]=a&b;
    assign c[0]=cin;
    genvar s,i;
    generate
        for(s=0;s<LEVELS;s=s+1) begin : g_level
            for(i=0;i<W;i=i+1) begin : g_node
                if(i>=(1<<s)) begin : g_merge
                    assign g[s+1][i]=g[s][i] | (p[s][i]&g[s][i-(1<<s)]);
                    assign p[s+1][i]=p[s][i]&p[s][i-(1<<s)];
                end else begin : g_pass
                    assign g[s+1][i]=g[s][i];
                    assign p[s+1][i]=p[s][i];
                end
            end
        end
        for(i=0;i<W;i=i+1) begin : g_output
            assign c[i+1]=g[LEVELS][i] | (p[LEVELS][i]&cin);
        end
    endgenerate
    assign sum=p[0]^c[W-1:0];
    assign cout=c[W];
endmodule
`default_nettype wire
